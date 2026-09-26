// Building blocks of the conversation: task cards, permission cards, the 8-second countdown, and the network proof.
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme.dart';

const Map<String, IconData> actionIcons = {
  'list_dir': Icons.folder_open, 'read_file': Icons.description_outlined, 'read_document': Icons.article_outlined, 'write_file': Icons.edit_outlined,
  'append_file': Icons.edit_outlined, 'delete_path': Icons.delete_outline, 'move_path': Icons.drive_file_move_outline, 'make_dir': Icons.create_new_folder_outlined,
  'search_files': Icons.search, 'read_metadata': Icons.data_object, 'write_metadata': Icons.data_object, 'run_python': Icons.play_arrow_outlined,
  'run_shell': Icons.terminal, 'pip_install': Icons.download_outlined, 'network_request': Icons.public, 'analyze_image': Icons.image_outlined,
  'analyze_video': Icons.movie_outlined, 'query_sql': Icons.table_chart_outlined, 'ask_user': Icons.help_outline, 'final_answer': Icons.check,
};

Color? accentFor(String action) {
  if (action == 'delete_path' || action == 'move_path') return warnRed;
  if (action == 'network_request' || action == 'pip_install') return infoBlue;
  if (action == 'analyze_image' || action == 'analyze_video') return visionPurple;
  return null;
}

class TaskCard extends StatelessWidget {
  final Entry task;
  final Entry? result;
  const TaskCard({super.key, required this.task, this.result});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final accent = accentFor(task.action);
    final detail = (task.params['path'] ?? task.params['query'] ?? task.params['command'] ?? task.params['url'] ?? task.params['question'] ?? task.params['pattern'] ?? '').toString();
    final code = (task.params['code'] ?? (task.action == 'run_shell' ? task.params['command'] : null))?.toString();
    final out = result?.text ?? '';
    final failed = out.startsWith('ERROR') || out.startsWith('DENIED') || out.startsWith('BLOCKED');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: accent ?? p.border)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true, tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2), childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: Icon(actionIcons[task.action] ?? Icons.circle_outlined, size: 20, color: accent ?? p.text),
          title: Row(children: [
            Text(task.action, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, fontFamily: monoFont)),
            const SizedBox(width: 10),
            Expanded(child: Text(detail, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.textDim, fontSize: 12.5, fontFamily: monoFont))),
          ]),
          subtitle: task.text.isEmpty ? null : Padding(padding: const EdgeInsets.only(top: 3), child: Text(task.text, style: TextStyle(color: p.text, fontSize: 13, fontStyle: FontStyle.italic))),
          trailing: result == null
              ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: p.textDim))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${result!.seconds}s', style: TextStyle(color: p.textDim, fontSize: 11.5)),
                  const SizedBox(width: 8),
                  Icon(failed ? Icons.error_outline : Icons.check_circle_outline, size: 18, color: failed ? warnRed : okGreen),
                ]),
          children: [
            if (code != null && code.isNotEmpty) _mono(context, code, 'input'),
            if (out.isNotEmpty) _mono(context, out.length > 6000 ? '${out.substring(0, 6000)}\n… (${out.length - 6000} more characters)' : out, 'output', failed ? warnRed : null),
          ],
        ),
      ),
    );
  }

  Widget _mono(BuildContext context, String text, String label, [Color? tint]) {
    final p = paletteOf(context);
    return Container(
      width: double.infinity, margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(8), border: tint == null ? null : Border.all(color: tint)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(), style: TextStyle(color: p.textDim, fontSize: 10, letterSpacing: 1)),
        const SizedBox(height: 6),
        SelectableText(text, style: const TextStyle(fontFamily: monoFont, fontSize: 12.5, height: 1.45)),
      ]),
    );
  }
}

// Permission / network / question card. Stays in the conversation after it is answered, so the history shows what was allowed.
class AskCard extends StatefulWidget {
  final Entry entry;
  final void Function(String answer) onAnswer;
  const AskCard({super.key, required this.entry, required this.onAnswer});

  @override
  State<AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<AskCard> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final ask = widget.entry.ask!;
    final kind = ask['kind'] as String;
    final color = kind == 'network' ? infoBlue : (kind == 'question' ? visionPurple : cautionAmber);
    final title = kind == 'network' ? 'INTERNET ACCESS REQUEST' : (kind == 'question' ? 'THE AGENT ASKS YOU' : 'PERMISSION NEEDED');
    final icon = kind == 'network' ? Icons.public : (kind == 'question' ? Icons.help_outline : Icons.shield_outlined);
    final done = widget.entry.resolved;
    return Container(
      margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: color, width: done ? 1 : 1.6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, color: color, size: 18), const SizedBox(width: 8), Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 1))]),
        const SizedBox(height: 10),
        Text(ask['question'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        if ((ask['detail'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 6), Text(ask['detail'] as String, style: TextStyle(color: p.textDim, fontSize: 13))],
        const SizedBox(height: 14),
        if (done)
          Row(children: [Icon(Icons.check, size: 16, color: p.textDim), const SizedBox(width: 6), Text('You answered: ${widget.entry.answer}', style: TextStyle(color: p.textDim, fontSize: 13))])
        else if (kind == 'question')
          Row(children: [
            Expanded(child: TextField(controller: _controller, autofocus: true, onSubmitted: (v) => widget.onAnswer(v), decoration: const InputDecoration(hintText: 'Your answer…', isDense: true))),
            const SizedBox(width: 10),
            FilledButton(onPressed: () => widget.onAnswer(_controller.text), child: const Text('Send')),
          ])
        else
          Row(children: [
            FilledButton(onPressed: () => widget.onAnswer('yes'), style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white), child: const Text('Allow')),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: () => widget.onAnswer('no'), child: const Text('Deny')),
          ]),
      ]),
    );
  }
}

// The 8-second window. Typing anything pauses the timer; sending delivers the message to the agent. Otherwise the agent just continues.
class CountdownBar extends StatefulWidget {
  final int seconds;
  final void Function(String text) onSend;
  final VoidCallback onExpired;
  const CountdownBar({super.key, required this.seconds, required this.onSend, required this.onExpired});

  @override
  State<CountdownBar> createState() => _CountdownBarState();
}

class _CountdownBarState extends State<CountdownBar> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: Duration(seconds: widget.seconds));
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed && !_paused) widget.onExpired();
    });
    _anim.forward();
    _controller.addListener(() {
      final typing = _controller.text.isNotEmpty;
      if (typing && !_paused) {
        _paused = true;
        _anim.stop();
        setState(() {});
      } else if (!typing && _paused) {
        _paused = false;
        _anim.forward();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final t = _controller.text.trim();
    if (t.isEmpty) return;
    widget.onSend(t);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: infoBlue.withValues(alpha: 0.7))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final left = (widget.seconds * (1 - _anim.value)).ceil();
            return Row(children: [
              Icon(Icons.timer_outlined, size: 16, color: infoBlue),
              const SizedBox(width: 8),
              Text(_paused ? 'Timer paused — send your message when ready' : 'Continuing in ${left}s — type to add a message to the agent', style: TextStyle(fontSize: 13, color: p.textDim)),
            ]);
          },
        ),
        const SizedBox(height: 8),
        AnimatedBuilder(
          animation: _anim,
          builder: (context, _) => ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: 1 - _anim.value, minHeight: 4, color: infoBlue, backgroundColor: p.surfaceAlt)),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _controller, focusNode: _focus, autofocus: true, onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'Correct or guide the agent…', isDense: true))),
          const SizedBox(width: 10),
          FilledButton(onPressed: _send, child: const Text('Send')),
        ]),
      ]),
    );
  }
}

class NetworkBadge extends StatelessWidget {
  final List<NetworkAudit> audit;
  final VoidCallback onTap;
  const NetworkBadge({super.key, required this.audit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final sent = audit.where((a) => a.sent).length;
    final blocked = audit.where((a) => a.blocked).length;
    final color = audit.isEmpty ? okGreen : (sent > 0 ? cautionAmber : okGreen);
    final label = audit.isEmpty ? 'Network: no internet activity' : 'Network: ${audit.length} attempted · $sent sent · $blocked blocked';
    return InkWell(
      borderRadius: BorderRadius.circular(20), onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: color.withValues(alpha: 0.7)), color: color.withValues(alpha: 0.08)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, size: 9, color: color), const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 12, color: p.text)),
        ]),
      ),
    );
  }
}

Future<void> showNetworkProof(BuildContext context, List<NetworkAudit> audit) {
  final p = paletteOf(context);
  return showDialog(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.verified_user_outlined), const SizedBox(width: 10),
              const Text('Network audit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(), IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 6),
            Text('Every internet attempt is logged here, including refused ones. Outbound data is checked against your workspace files before anything is sent.', style: TextStyle(color: p.textDim, fontSize: 13)),
            const SizedBox(height: 14),
            Expanded(
              child: audit.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.shield_outlined, size: 40, color: okGreen), const SizedBox(height: 10), const Text('No network activity in this chat.', style: TextStyle(fontWeight: FontWeight.w600))]))
                  : ListView.separated(
                      itemCount: audit.length, separatorBuilder: (_, __) => Divider(color: p.border),
                      itemBuilder: (_, i) {
                        final a = audit[i];
                        final outcome = a.sent ? 'SENT' : (a.blocked ? 'BLOCKED' : 'DENIED');
                        final c = a.sent ? cautionAmber : (a.blocked ? warnRed : okGreen);
                        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(border: Border.all(color: c), borderRadius: BorderRadius.circular(6)), child: Text(outcome, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700))), const SizedBox(width: 10), Expanded(child: Text('${a.method}  ${a.url}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: monoFont, fontSize: 12.5)))]),
                          const SizedBox(height: 4),
                          Text('${a.time.replaceFirst('T', ' ')} · ${a.bytes} bytes · SHA-256 ${a.sha256.length > 16 ? a.sha256.substring(0, 16) : a.sha256}… · leak scan: ${a.clean ? 'clean' : 'LEAK DETECTED'}', style: TextStyle(color: p.textDim, fontSize: 12)),
                          if (a.note.isNotEmpty) Text(a.note, style: TextStyle(color: p.textDim, fontSize: 12)),
                        ]);
                      }),
            ),
            const SizedBox(height: 10),
            Text('The leak scan is a best-effort comparison, not a mathematical guarantee.', style: TextStyle(color: p.textDim, fontSize: 11.5, fontStyle: FontStyle.italic)),
          ]),
        ),
      ),
    ),
  );
}
