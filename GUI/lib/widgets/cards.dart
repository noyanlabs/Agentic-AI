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

// Friendly one-line labels so the timeline reads like prose, not a function-call log.
const Map<String, String> actionLabels = {
  'list_dir': 'Listing folder', 'read_file': 'Reading file', 'read_document': 'Reading document', 'write_file': 'Writing file',
  'append_file': 'Appending to file', 'delete_path': 'Deleting', 'move_path': 'Moving', 'make_dir': 'Creating folder',
  'search_files': 'Searching files', 'read_metadata': 'Reading metadata', 'write_metadata': 'Writing metadata', 'run_python': 'Running Python',
  'run_shell': 'Running command', 'pip_install': 'Installing package', 'network_request': 'Requesting URL', 'analyze_image': 'Analyzing image',
  'analyze_video': 'Analyzing video', 'query_sql': 'Querying database', 'ask_user': 'Asking you', 'final_answer': 'Finishing up',
};

// A single step in the agent's connected-dot timeline: a filled dot, a rail line joining it to its
// neighbours, a one-line collapsed summary, and — on tap — the full input/output expanded in place.
// `isFirst` / `isLast` control whether the rail line is drawn above/below the dot, so a run of
// consecutive steps reads as one continuous thread rather than N disconnected cards.
class TaskCard extends StatefulWidget {
  final Entry task;
  final Entry? result;
  final bool isFirst;
  final bool isLast;
  const TaskCard({super.key, required this.task, this.result, this.isFirst = true, this.isLast = true});

  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final task = widget.task;
    final result = widget.result;
    final accent = accentFor(task.action);
    final detail = (task.params['path'] ?? task.params['query'] ?? task.params['command'] ?? task.params['url'] ?? task.params['question'] ?? task.params['pattern'] ?? '').toString();
    final code = (task.params['code'] ?? (task.action == 'run_shell' ? task.params['command'] : null))?.toString();
    final out = result?.text ?? '';
    final failed = out.startsWith('ERROR') || out.startsWith('DENIED') || out.startsWith('BLOCKED');
    final running = result == null;
    final dotColor = failed ? warnRed : (running ? (accent ?? p.textDim) : (accent ?? okGreen));
    final label = actionLabels[task.action] ?? task.action;
    final hasDetail = (code != null && code.isNotEmpty) || out.isNotEmpty;

    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ── Rail: line above, dot, line below ──────────────────────────────
        SizedBox(
          width: 28,
          child: Column(children: [
            Expanded(
              flex: widget.isFirst ? 0 : 1,
              child: widget.isFirst ? const SizedBox(width: 2) : Container(width: 2, color: p.border),
            ),
            _Dot(color: dotColor, running: running),
            Expanded(
              child: Container(width: 2, color: widget.isLast && !_open ? Colors.transparent : p.border),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        // ── Step body ────────────────────────────────────────────────────
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: widget.isLast ? 4 : 2, top: widget.isFirst ? 2 : 0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: hasDetail ? () => setState(() => _open = !_open) : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: _open ? p.surfaceAlt : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(actionIcons[task.action] ?? Icons.circle_outlined, size: 14, color: dotColor),
                      const SizedBox(width: 7),
                      Expanded(
                        child: RichText(
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(children: [
                            TextSpan(text: label, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: p.text)),
                            if (detail.isNotEmpty) TextSpan(text: '  ·  $detail', style: TextStyle(fontSize: 12, color: p.textDim, fontFamily: monoFont)),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (running)
                        SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.textDim))
                      else ...[
                        Text('${result!.seconds.toStringAsFixed(result!.seconds < 10 ? 1 : 0)}s', style: TextStyle(color: p.textDim, fontSize: 11)),
                        const SizedBox(width: 6),
                        Icon(failed ? Icons.error_outline : Icons.check_circle_outline, size: 15, color: failed ? warnRed : okGreen),
                      ],
                      if (hasDetail) ...[
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          duration: const Duration(milliseconds: 160),
                          turns: _open ? 0.25 : 0,
                          child: Icon(Icons.chevron_right, size: 16, color: p.textDim),
                        ),
                      ],
                    ]),
                    if (task.text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, left: 21),
                        child: Text(task.text, maxLines: _open ? null : 1, overflow: _open ? null : TextOverflow.ellipsis, style: TextStyle(color: p.textDim, fontSize: 12.5, fontStyle: FontStyle.italic)),
                      ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: !_open
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.only(left: 21, top: 6),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                if (code != null && code.isNotEmpty) _mono(context, code, 'input'),
                                if (out.isNotEmpty) _mono(context, out.length > 6000 ? '${out.substring(0, 6000)}\n… (${out.length - 6000} more characters)' : out, 'output', failed ? warnRed : null),
                              ]),
                            ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _mono(BuildContext context, String text, String label, [Color? tint]) {
    final p = paletteOf(context);
    return Container(
      width: double.infinity, margin: const EdgeInsets.only(top: 6), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: p.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: tint ?? p.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(), style: TextStyle(color: p.textDim, fontSize: 9.5, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SelectableText(text, style: const TextStyle(fontFamily: monoFont, fontSize: 12.5, height: 1.45)),
      ]),
    );
  }
}

// The filled timeline dot. Pulses gently while the step is running.
class _Dot extends StatefulWidget {
  final Color color;
  final bool running;
  const _Dot({required this.color, required this.running});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.running) {
      return Container(
        width: 9, height: 9,
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
      );
    }
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Container(
        width: 9, height: 9,
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color,
          boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.35 + _anim.value * 0.35), blurRadius: 5 + _anim.value * 3, spreadRadius: 0.5 + _anim.value)],
        ),
      ),
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
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, entrance, child) => Opacity(opacity: entrance, child: Transform.translate(offset: Offset(0, (1 - entrance) * 8), child: child)),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: infoBlue.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: infoBlue.withValues(alpha: 0.35)),
          boxShadow: [BoxShadow(color: infoBlue.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, 6))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AnimatedBuilder(
            animation: _anim,
            builder: (context, _) {
              final left = (widget.seconds * (1 - _anim.value)).ceil();
              return Row(children: [
                _RingTimer(progress: 1 - _anim.value, paused: _paused, seconds: left),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _paused ? 'Paused — send when you\'re ready' : 'Continuing in ${left}s · type to step in',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.text),
                  ),
                ),
              ]);
            },
          ),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: p.border)),
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  maxLines: 4,
                  minLines: 1,
                  onSubmitted: (_) => _send(),
                  style: TextStyle(fontSize: 14, color: p.text),
                  decoration: InputDecoration(
                    hintText: 'Correct or guide the agent…',
                    hintStyle: TextStyle(color: p.textDim, fontSize: 13.5),
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Material(
              color: infoBlue,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _send,
                child: const SizedBox(width: 44, height: 44, child: Icon(Icons.arrow_upward_rounded, size: 20, color: Colors.white)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// Small circular countdown ring, replacing the old linear progress bar. Reads at a glance and doesn't
// compete visually with the text next to it.
class _RingTimer extends StatelessWidget {
  final double progress; // 0 -> 1
  final bool paused;
  final int seconds;
  const _RingTimer({required this.progress, required this.paused, required this.seconds});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return SizedBox(
      width: 26, height: 26,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(
          width: 26, height: 26,
          child: CircularProgressIndicator(
            value: paused ? null : progress,
            strokeWidth: 2.4,
            backgroundColor: p.border,
            valueColor: AlwaysStoppedAnimation(infoBlue),
          ),
        ),
        paused
            ? Icon(Icons.pause, size: 11, color: infoBlue)
            : Text('$seconds', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: infoBlue)),
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