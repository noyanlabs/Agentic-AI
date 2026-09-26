// Renders Markdown AND LaTeX math together:  *important eqn* $F\,=\,m \times a$   and   $$ E = mc^2 $$
// All third-party API use for this feature is isolated in this one file. If a package version changes its API, fix it here only.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme.dart';

// $$ ... $$  (may span lines) -> block math
class BlockMathSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\s*\$\$');

  @override
  md.Node parse(md.BlockParser parser) {
    final buffer = <String>[];
    final first = parser.current.content.trim();
    // single-line form: $$ x $$
    final single = RegExp(r'^\$\$(.+)\$\$$').firstMatch(first);
    if (single != null) {
      parser.advance();
      return md.Element('math_block', [md.Text(single.group(1)!.trim())]);
    }
    var line = first.substring(2);
    while (true) {
      final closeAt = line.indexOf(r'$$');
      if (closeAt >= 0) {
        buffer.add(line.substring(0, closeAt));
        parser.advance();
        break;
      }
      buffer.add(line);
      parser.advance();
      if (parser.isDone) break;
      line = parser.current.content;
    }
    return md.Element('math_block', [md.Text(buffer.join('\n').trim())]);
  }
}

// $ ... $ inside a line -> inline math. Runs BEFORE emphasis so underscores and asterisks inside math are left alone.
class InlineMathSyntax extends md.InlineSyntax {
  InlineMathSyntax() : super(r'(?<![\\$])\$(?!\s)((?:\\.|[^$\\\n])+?)(?<!\s)\$(?!\d)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('math_inline', [md.Text(match.group(1)!)]));
    return true;
  }
}

class MathInlineBuilder extends MarkdownElementBuilder {
  final Color color;
  MathInlineBuilder(this.color);

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final tex = element.textContent;
    return Math.tex(tex, mathStyle: MathStyle.text, textStyle: (preferredStyle ?? const TextStyle()).copyWith(color: color),
        onErrorFallback: (err) => Text('\$$tex\$', style: TextStyle(color: warnRed, fontFamily: monoFont, fontSize: (preferredStyle?.fontSize ?? 14) - 1)));
  }
}

class MathBlockBuilder extends MarkdownElementBuilder {
  final Color color;
  MathBlockBuilder(this.color);

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final tex = element.textContent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Math.tex(tex, mathStyle: MathStyle.display, textStyle: TextStyle(color: color, fontSize: (preferredStyle?.fontSize ?? 15) + 2),
            onErrorFallback: (err) => Text('\$\$ $tex \$\$', style: TextStyle(color: warnRed, fontFamily: monoFont))),
      ),
    );
  }
}

class MarkdownMath extends StatelessWidget {
  final String data;
  final bool selectable;
  const MarkdownMath(this.data, {super.key, this.selectable = true});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final base = TextStyle(color: p.text, fontSize: 15, height: 1.55);
    final sheet = MarkdownStyleSheet(
      p: base, a: base.copyWith(decoration: TextDecoration.underline),
      h1: base.copyWith(fontSize: 24, fontWeight: FontWeight.w700), h2: base.copyWith(fontSize: 20, fontWeight: FontWeight.w700), h3: base.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
      strong: base.copyWith(fontWeight: FontWeight.w700), em: base.copyWith(fontStyle: FontStyle.italic),
      code: TextStyle(fontFamily: monoFont, fontSize: 13, color: p.text, backgroundColor: p.surfaceAlt),
      codeblockDecoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(10), border: Border.all(color: p.border)),
      codeblockPadding: const EdgeInsets.all(14),
      blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: p.textDim, width: 3))), blockquotePadding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
      tableBorder: TableBorder.all(color: p.border), tableHead: base.copyWith(fontWeight: FontWeight.w700), tableCellsPadding: const EdgeInsets.all(8),
      horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: p.border))),
      listBullet: base, blockSpacing: 10,
    );
    return MarkdownBody(
      data: data, selectable: selectable, styleSheet: sheet, softLineBreak: true, fitContent: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: [BlockMathSyntax()],
      inlineSyntaxes: [InlineMathSyntax()],
      builders: {'math_inline': MathInlineBuilder(p.text), 'math_block': MathBlockBuilder(p.text)},
      onTapLink: (text, href, title) {
        if (href != null) Clipboard.setData(ClipboardData(text: href));
      },
    );
  }
}
