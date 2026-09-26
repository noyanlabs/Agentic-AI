// Gives the feel of streaming for an answer that arrived in one piece. Short text is instant, long text is capped at about 1.4 seconds.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'markdown_math.dart';

const double maxRevealSeconds = 1.4;

class TypewriterMarkdown extends StatefulWidget {
  final String text;
  final bool animate;
  final VoidCallback? onTick;          // lets the chat list keep itself scrolled to the bottom while text grows
  final VoidCallback? onFinished;
  const TypewriterMarkdown(this.text, {super.key, this.animate = true, this.onTick, this.onFinished});

  @override
  State<TypewriterMarkdown> createState() => _TypewriterMarkdownState();
}

class _TypewriterMarkdownState extends State<TypewriterMarkdown> {
  Timer? _timer;
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    if (!widget.animate || widget.text.isEmpty) {
      _shown = widget.text.length;
      return;
    }
    final total = widget.text.length;
    final seconds = min(maxRevealSeconds, 0.15 + total / 900);
    const frameMs = 33;
    final frames = max(1, (seconds * 1000 / frameMs).round());
    final step = max(2, (total / frames).ceil());
    _timer = Timer.periodic(const Duration(milliseconds: frameMs), (t) {
      if (!mounted) return t.cancel();
      setState(() => _shown = min(total, _shown + step));
      widget.onTick?.call();
      if (_shown >= total) {
        t.cancel();
        widget.onFinished?.call();
      }
    });
  }

  // Cutting text in the middle of a $...$ or ``` block would flash broken formatting, so the visible slice is repaired first.
  String _safeSlice(String s, int n) {
    var part = s.substring(0, n);
    if (n >= s.length) return part;
    final dollars = RegExp(r'(?<!\\)\$').allMatches(part).length;
    if (dollars.isOdd) {
      final cut = part.lastIndexOf(RegExp(r'(?<!\\)\$'));
      part = part.substring(0, cut);
    }
    if (RegExp(r'```').allMatches(part).length.isOdd) part = '$part\n```';
    return part;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = _shown >= widget.text.length;
    return MarkdownMath(done ? widget.text : '${_safeSlice(widget.text, _shown)} ▌', selectable: done);
  }
}
