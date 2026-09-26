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
  int _lastTurnEndTick = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = ChatController(widget.backend);
    _sub = widget.backend.events.listen(_ctrl.apply);
    _lastTurnEndTick = _ctrl.turnEndTick;
    _ctrl.addListener(_onCtrlChange);
  }

  // Flutter Web's TextField keeps its own internal notion of "I have focus" separate from the browser's
  // actual DOM focus on the hidden <input>/<textarea> element it renders through. During a turn, the
  // conversation list is being rebuilt continuously (task cards streaming in, the typewriter animating
  // the final answer character-by-character, scroll position changing) and on some engine/renderer
  // combinations the browser's real DOM focus can end up displaced from that hidden input without
  // Flutter's FocusNode ever hearing about it - so FocusNode.hasFocus still reads true, the caret still
  // blinks, but keystrokes go nowhere because the real platform text-input connection is gone. Calling
  // requestFocus() again is a no-op in that state, because as far as Flutter's own bookkeeping is
  // concerned nothing changed. The only reliable fix is to force a genuine focus CHANGE: explicitly drop
  // focus, let a frame pass so Flutter tears down the stale connection, then request it again so Flutter
  // opens a brand new one. This runs exactly once per turn, driven by ChatController.turnEndTick (a
  // simple counter bumped once when a turn's busy state goes true -> false), not by diffing widget
  // properties - so it can't misfire from unrelated rebuilds the way the previous attempt did.
  void _onCtrlChange() {
    if (_ctrl.turnEndTick != _lastTurnEndTick) {
      _lastTurnEndTick = _ctrl.turnEndTick;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _focus.unfocus();
        await Future.delayed(const Duration(milliseconds: 16));
        if (!mounted) return;
        _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onCtrlChange);
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
              // NOTE: every direct child here carries a stable Key. Without keys, an unkeyed Column
              // reconciles its children purely by POSITION. The countdown bar below is conditionally
              // present (`if (ctrl.countdownActive) ...`), so every time it appears/disappears, every
              // widget after it in this list shifts index by one. Flutter's default element-matching
              // across such a shift is not guaranteed to line up the old `_InputBar` element with the new
              // one at that slot — when it doesn't, the whole subtree (including the TextField's internal
              // EditableTextState and its live platform text-input connection) gets disposed and rebuilt
              // from scratch. The TextField LOOKS fine and shows a blinking caret, but has no active
              // input connection until something re-taps it, which nothing does automatically — this,
              // not the enabled/readOnly toggling from before, is what actually broke typing after the
              // first response. Explicit keys make each child's identity independent of its position.
              _TopBar(
                key: const ValueKey('topbar'),
                ctrl: ctrl,
                brightness: widget.brightness,
                onToggleBrightness: widget.onToggleBrightness,
                onNewChat: _newChat,
              ),
              Divider(key: const ValueKey('div1'), height: 1, color: p.border),

              // ── Conversation ─────────────────────────────────────────────────
              Expanded(
                key: const ValueKey('conversation'),
                child: ctrl.entries.isEmpty
                    ? _EmptyState(busy: ctrl.busy)
                    : _ConversationList(ctrl: ctrl, scroll: _scroll, onTick: _scrollToBottom),
              ),

              // ── Countdown nudge bar ──────────────────────────────────────────
              if (ctrl.countdownActive)
                Padding(
                  key: const ValueKey('countdown'),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: CountdownBar(
                    seconds: ctrl.countdownSeconds,
                    onSend: (t) { ctrl.sendNudge(t); _scrollToBottom(); },
                    onExpired: ctrl.expireCountdown,
                  ),
                ),

              Divider(key: const ValueKey('div2'), height: 1, color: p.border),

              // ── Input area ───────────────────────────────────────────────────
              _InputBar(
                key: const ValueKey('inputbar'),
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
  const _TopBar({super.key, required this.ctrl, required this.brightness, required this.onToggleBrightness, required this.onNewChat});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      height: 56,
      color: p.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Builder(builder: (ctx) => IconButton(icon: const Icon(Icons.menu_rounded, size: 20), tooltip: 'Chat history', onPressed: () => Scaffold.of(ctx).openDrawer())),
        const SizedBox(width: 2),
        Expanded(
          child: Text(
            ctrl.sessionName,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: p.text, letterSpacing: -0.1),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (ctrl.busy)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.textDim)),
                const SizedBox(width: 7),
                Text(ctrl.thinking ? 'Thinking · step ${ctrl.thinkingStep}' : 'Working…', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: p.textDim)),
              ]),
            ),
          ),
        // Network audit badge - always shown, including the "no internet activity" state. Hiding it entirely
        // when nothing has happened yet defeats the point: a security-relevant status the user has to wait
        // for bad news to see isn't reassuring, it's just silent. NetworkBadge already has its own copy for
        // the empty case ("Network: no internet activity") - it was simply never reachable before this.
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
            // A "run" of timeline steps is a maximal stretch of task entries with nothing but their own
            // paired result entries between them (results render as SizedBox.shrink, so they don't break
            // the visual thread). isFirst/isLast tell TaskCard whether to draw the connecting rail line
            // above/below its dot, so consecutive tool calls read as one continuous timeline.
            // Look back/forward skipping result entries (which render nothing) to find the nearest
            // actual neighbour entry, then check whether that neighbour is also a task.
            int back = i - 1;
            while (back >= 0 && entries[back].kind == EntryKind.result) {
              back--;
            }
            final prevIsTask = back >= 0 && entries[back].kind == EntryKind.task;
            int fwd = i + 1;
            while (fwd < entries.length && entries[fwd].kind == EntryKind.result) {
              fwd++;
            }
            final nextIsTask = fwd < entries.length && entries[fwd].kind == EntryKind.task;
            return TaskCard(task: e, result: result, isFirst: !prevIsTask, isLast: !nextIsTask);

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
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, (1 - t) * 6), child: child)),
        child: Container(
          margin: const EdgeInsets.only(bottom: 16, left: 60),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: p.inverse,
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(4)),
            boxShadow: [BoxShadow(color: p.inverse.withValues(alpha: 0.14), blurRadius: 12, offset: const Offset(0, 4))],
          ),
          child: SelectableText(text, style: TextStyle(color: p.onInverse, fontSize: 14.5, height: 1.45)),
        ),
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
      margin: const EdgeInsets.only(bottom: 20, right: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(color: okGreen.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: const Icon(Icons.auto_awesome, size: 12, color: okGreen),
          ),
          const SizedBox(width: 8),
          Text('AgenticAI', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: p.text, letterSpacing: 0.2)),
        ]),
        const SizedBox(height: 12),
        TypewriterMarkdown(
          entry.text,
          animate: !entry.revealed,
          onTick: onTick,
          onFinished: () => entry.revealed = true,
        ),
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
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w500))),
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
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.surfaceAlt, border: Border.all(color: p.border)),
                child: Icon(Icons.auto_awesome_rounded, size: 30, color: p.textDim),
              ),
              const SizedBox(height: 20),
              Text('AgenticAI', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: p.text, letterSpacing: -0.3)),
              const SizedBox(height: 8),
              Text('Type a message below to get started.', style: TextStyle(fontSize: 14, color: p.textDim)),
            ]),
    );
  }
}

// ─────────────────────────── Input bar ───────────────────────────────────────

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final bool autopilot;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final void Function(bool) onToggleAutopilot;
  const _InputBar({super.key, required this.controller, required this.focus, required this.busy, required this.autopilot, required this.onSend, required this.onStop, required this.onToggleAutopilot});

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.focus.removeListener(_onFocusChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final busy = widget.busy;
    return Container(
      color: p.surface,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: widget.focus.hasFocus ? p.inverse.withValues(alpha: 0.6) : p.border, width: widget.focus.hasFocus ? 1.3 : 1),
              ),
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focus,
                // Deliberately never disabled and never read-only. Flutter Web only (re)opens a live
                // platform text-input connection in response to a focus/tap gesture on a field that is
                // enabled AND not read-only at the moment of that gesture. Toggling either property based
                // on `busy` — even temporarily — was exactly what broke typing after the first response:
                // the field looked normal but had no live input connection underneath, so keystrokes went
                // nowhere until a full page reload. The agent being busy now only changes hint text and
                // disables the send *action* (see widget.onSend below); the field itself is always a
                // normal, always-focusable, always-typable TextField.
                onTap: () {
                  // Self-healing safety net: if the field already reports hasFocus == true the instant
                  // it's tapped, that's the exact signature of a stale platform input connection (Flutter
                  // thinks it's focused, so a plain requestFocus() is a no-op and the tap otherwise does
                  // nothing new). Forcing an explicit unfocus -> refocus round trip makes Flutter open a
                  // genuinely fresh connection instead of trusting the one it already believes is live.
                  if (widget.focus.hasFocus) {
                    widget.focus.unfocus();
                    WidgetsBinding.instance.addPostFrameCallback((_) => widget.focus.requestFocus());
                  }
                },
                maxLines: 6,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                onSubmitted: (_) => widget.onSend(),
                style: TextStyle(color: p.text, fontSize: 14.5, height: 1.4),
                decoration: InputDecoration(
                  hintText: busy ? 'Agent is working — you can keep typing' : 'Message AgenticAI',
                  isDense: false,
                  filled: true,
                  fillColor: p.surfaceAlt,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SendButton(busy: busy, onSend: widget.onSend, onStop: widget.onStop),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _AutopilotToggle(value: widget.autopilot, onChanged: widget.onToggleAutopilot),
          const Spacer(),
          Icon(Icons.lock_outline, size: 11, color: p.textDim),
          const SizedBox(width: 4),
          Text('Runs locally — files never leave your device', style: TextStyle(fontSize: 11, color: p.textDim)),
        ]),
      ]),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  const _SendButton({required this.busy, required this.onSend, required this.onStop});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
      child: busy
          ? Material(
              key: const ValueKey('stop'),
              color: warnRed,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onStop,
                child: const SizedBox(width: 44, height: 44, child: Icon(Icons.stop_rounded, size: 20, color: Colors.white)),
              ),
            )
          : Material(
              key: const ValueKey('send'),
              color: p.inverse,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onSend,
                child: SizedBox(width: 44, height: 44, child: Icon(Icons.arrow_upward_rounded, size: 20, color: p.onInverse)),
              ),
            ),
    );
  }
}

class _AutopilotToggle extends StatelessWidget {
  final bool value;
  final void Function(bool) onChanged;
  const _AutopilotToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: value ? cautionAmber.withValues(alpha: 0.12) : Colors.transparent,
          border: Border.all(color: value ? cautionAmber.withValues(alpha: 0.5) : p.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bolt_rounded, size: 13, color: value ? cautionAmber : p.textDim),
          const SizedBox(width: 5),
          Text('Autopilot', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: value ? cautionAmber : p.textDim)),
        ]),
      ),
    );
  }
}