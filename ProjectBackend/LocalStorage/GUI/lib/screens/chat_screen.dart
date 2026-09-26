// The main chat screen. Receives backend events live and renders the conversation.
// Every kind of entry (user, task, result, final answer, permissions, errors) is shown here.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' show ChangeNotifierProvider, Consumer;

import '../models/models.dart';
import '../services/backend.dart';
import '../services/chat_controller.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/typewriter.dart';
import 'history_drawer.dart';

class ChatScreen extends StatefulWidget {
  final Backend backend;
  final VoidCallback onToggleBrightness;
  final Brightness brightness;
  const ChatScreen({super.key, required this.backend, required this.onToggleBrightness, required this.brightness});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _ctrl;
  late final StreamSubscription _sub;
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctrl = ChatController(widget.backend);
    _sub = widget.backend.events.listen(_ctrl.apply);
  }

  @override
  void dispose() {
    _sub.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _ctrl.busy) return;
    _input.clear();
    _ctrl.send(text);
    _scrollToBottom();
    _focus.requestFocus();
  }

  void _openHistory(Map<String, dynamic> data) {
    _ctrl.loadHistory(data);
    _scrollToBottom();
  }

  void _newChat() {
    _ctrl.reset();
    _input.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _ctrl,
      child: Consumer<ChatController>(
        builder: (context, ctrl, _) {
          final p = paletteOf(context);
          return Scaffold(
            drawer: HistoryDrawer(
              backend: widget.backend,
              activeSessionId: ctrl.sessionId,
              onOpen: _openHistory,
              onNewChat: () { Navigator.pop(context); _newChat(); },
            ),
            body: Column(children: [
              // ── Top bar ──────────────────────────────────────────────────────
              _TopBar(
                ctrl: ctrl,
                brightness: widget.brightness,
                onToggleBrightness: widget.onToggleBrightness,
                onNewChat: _newChat,
              ),
              Divider(height: 1, color: p.border),

              // ── Conversation ─────────────────────────────────────────────────
              Expanded(
                child: ctrl.entries.isEmpty
                    ? _EmptyState(busy: ctrl.busy)
                    : _ConversationList(ctrl: ctrl, scroll: _scroll, onTick: _scrollToBottom),
              ),

              // ── Countdown nudge bar ──────────────────────────────────────────
              if (ctrl.countdownActive)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: CountdownBar(
                    seconds: ctrl.countdownSeconds,
                    onSend: (t) { ctrl.sendNudge(t); _scrollToBottom(); },
                    onExpired: ctrl.expireCountdown,
                  ),
                ),

              Divider(height: 1, color: p.border),

              // ── Input area ───────────────────────────────────────────────────
              _InputBar(
                controller: _input,
                focus: _focus,
                busy: ctrl.busy,
                autopilot: ctrl.autopilot,
                onSend: _send,
                onStop: ctrl.stop,
                onToggleAutopilot: ctrl.toggleAutopilot,
              ),
            ]),
          );
        },
      ),
    );
  }
}

// ─────────────────────────── Top bar ────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final ChatController ctrl;
  final Brightness brightness;
  final VoidCallback onToggleBrightness;
  final VoidCallback onNewChat;
  const _TopBar({required this.ctrl, required this.brightness, required this.onToggleBrightness, required this.onNewChat});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      height: 52,
      color: p.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Builder(builder: (ctx) => IconButton(icon: const Icon(Icons.menu, size: 20), tooltip: 'Chat history', onPressed: () => Scaffold.of(ctx).openDrawer())),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            ctrl.sessionName,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: p.text),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (ctrl.busy)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: p.textDim)),
              const SizedBox(width: 8),
              Text(ctrl.thinking ? 'Thinking (step ${ctrl.thinkingStep})…' : 'Working…', style: TextStyle(fontSize: 12, color: p.textDim)),
            ]),
          ),
        // Network audit badge
        if (ctrl.audit.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: NetworkBadge(audit: ctrl.audit, onTap: () => showNetworkProof(context, ctrl.audit)),
          ),
        IconButton(icon: Icon(brightness == Brightness.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20), tooltip: 'Toggle theme', onPressed: onToggleBrightness),
        IconButton(icon: const Icon(Icons.add_comment_outlined, size: 20), tooltip: 'New chat', onPressed: onNewChat),
      ]),
    );
  }
}

// ─────────────────────────── Conversation list ──────────────────────────────

class _ConversationList extends StatelessWidget {
  final ChatController ctrl;
  final ScrollController scroll;
  final VoidCallback onTick;
  const _ConversationList({required this.ctrl, required this.scroll, required this.onTick});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final entries = ctrl.entries;
    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        switch (e.kind) {
          case EntryKind.user:
            return _UserBubble(text: e.text);

          case EntryKind.task:
            final result = ctrl.resultFor(e);
            return TaskCard(task: e, result: result);

          case EntryKind.result:
            // Results are paired with their task card above; skip standalone rendering.
            return const SizedBox.shrink();

          case EntryKind.final_:
            return _FinalAnswer(entry: e, onTick: onTick);

          case EntryKind.ask:
            return AskCard(entry: e, onAnswer: (a) => ctrl.answerAsk(e, a));

          case EntryKind.nudge:
            return _InfoChip(icon: Icons.edit_outlined, text: 'You nudged: ${e.text}', color: p.textDim);

          case EntryKind.error:
            return _InfoChip(icon: Icons.error_outline, text: e.text, color: warnRed);

          case EntryKind.info:
            return _InfoChip(icon: Icons.info_outline, text: e.text, color: p.textDim);

          case EntryKind.network:
            final a = e.audit!;
            final sent = (a['sent'] ?? false) as bool;
            final blocked = ((a['note'] ?? '') as String).contains('BLOCKED');
            final c = sent ? cautionAmber : (blocked ? warnRed : okGreen);
            return _InfoChip(icon: Icons.public, text: '${sent ? "Sent" : (blocked ? "Blocked" : "Denied")} network request to ${a['url']}', color: c);
        }
      },
    );
  }
}

// ─────────────────────────── Entry widgets ───────────────────────────────────

class _UserBubble extends StatelessWidget {
  final String text;
  const _UserBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14, left: 60),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: p.inverse, borderRadius: BorderRadius.circular(18)),
        child: SelectableText(text, style: TextStyle(color: p.onInverse, fontSize: 14.5, height: 1.4)),
      ),
    );
  }
}

class _FinalAnswer extends StatelessWidget {
  final Entry entry;
  final VoidCallback onTick;
  const _FinalAnswer({required this.entry, required this.onTick});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16, right: 20),
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: okGreen.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.check_circle_outline, size: 14, color: okGreen),
              const SizedBox(width: 5),
              Text('AgenticAI', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: okGreen)),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: p.border)),
        ]),
        const SizedBox(height: 10),
        TypewriterMarkdown(
          entry.text,
          animate: !entry.revealed,
          onTick: onTick,
          onFinished: () => entry.revealed = true,
        ),
        const SizedBox(height: 16),
      ]),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _InfoChip({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 7),
        Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13))),
      ]),
    );
  }
}

// ─────────────────────────── Empty state ─────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final bool busy;
  const _EmptyState({required this.busy});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Center(
      child: busy
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(strokeWidth: 2),
              const SizedBox(height: 16),
              Text('Connecting…', style: TextStyle(color: p.textDim, fontSize: 14)),
            ])
          : Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.smart_toy_outlined, size: 52, color: p.border),
              const SizedBox(height: 16),
              Text('AgenticAI', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: p.text)),
              const SizedBox(height: 6),
              Text('Type a message below to get started.', style: TextStyle(fontSize: 14, color: p.textDim)),
            ]),
    );
  }
}

// ─────────────────────────── Input bar ───────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final bool autopilot;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final void Function(bool) onToggleAutopilot;
  const _InputBar({required this.controller, required this.focus, required this.busy, required this.autopilot, required this.onSend, required this.onStop, required this.onToggleAutopilot});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      color: p.surface,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              enabled: !busy,
              maxLines: 6,
              minLines: 1,
              textInputAction: TextInputAction.newline,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: busy ? 'Agent is working…' : 'Message AgenticAI',
                isDense: false,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            IconButton.filled(
              onPressed: onStop,
              tooltip: 'Stop',
              style: IconButton.styleFrom(backgroundColor: warnRed, foregroundColor: Colors.white),
              icon: const Icon(Icons.stop_rounded, size: 22),
            )
          else
            IconButton.filled(
              onPressed: onSend,
              tooltip: 'Send',
              icon: const Icon(Icons.arrow_upward_rounded, size: 22),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.bolt_outlined, size: 14),
          const SizedBox(width: 6),
          Text('Autopilot', style: TextStyle(fontSize: 12.5, color: p.textDim)),
          const SizedBox(width: 6),
          Switch(
            value: autopilot,
            onChanged: onToggleAutopilot,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          const Spacer(),
          Text('AgenticAI runs locally — your files never leave your device.', style: TextStyle(fontSize: 11, color: p.textDim)),
        ]),
      ]),
    );
  }
}
