// Turns the stream of backend events into a list of conversation entries. No widgets in here, so it works for live events AND for history replay.
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'backend.dart';

class ChatController extends ChangeNotifier {
  final Backend backend;
  ChatController(this.backend);

  String? sessionId;
  String sessionName = 'New chat';
  bool autopilot = false;
  bool busy = false;
  bool thinking = false;
  int thinkingStep = 0;
  bool countdownActive = false;
  int countdownSeconds = 8;
  bool serverLost = false;
  final List<Entry> entries = [];
  final List<NetworkAudit> audit = [];
  final Map<int, Entry> _resultsByTask = {};

  void reset() {
    sessionId = null;
    sessionName = 'New chat';
    entries.clear();
    audit.clear();
    _resultsByTask.clear();
    busy = thinking = countdownActive = false;
    notifyListeners();
  }

  // Loads an old conversation. Nothing is animated and nothing is pending.
  void loadHistory(Map<String, dynamic> data) {
    reset();
    sessionId = data['id'] as String;
    sessionName = data['name'] as String;
    autopilot = (data['autopilot'] ?? false) as bool;
    for (final a in (data['network_audit'] as List? ?? [])) {
      audit.add(NetworkAudit.fromJson(a as Map<String, dynamic>));
    }
    for (final e in (data['events'] as List? ?? [])) {
      apply(e as Map<String, dynamic>, replay: true);
    }
    notifyListeners();
  }

  void apply(Map<String, dynamic> e, {bool replay = false}) {
    switch (e['type']) {
      case 'session':
        // NOTE: the backend can now send a second 'session' event for the SAME id shortly after the first -
        // it renames the chat once the (async, non-blocking) title-generation call finishes. Only treat this
        // as "a turn just started" (busy = true) the first time we see this session id; a rename arriving
        // later must update the name without reopening the busy/thinking state.
        final isFirstSightingOfSession = sessionId != e['id'];
        sessionId = e['id'] as String;
        sessionName = e['name'] as String;
        autopilot = (e['autopilot'] ?? autopilot) as bool;
        if (isFirstSightingOfSession) busy = true;
        break;
      case 'user':
        entries.add(Entry(kind: EntryKind.user, text: e['text'] as String));
        busy = !replay;
        break;
      case 'thinking':
        thinking = true;
        thinkingStep = (e['step'] ?? 0) as int;
        break;
      case 'task':
        thinking = false;
        final idx = e['index'] as int;
        final entry = Entry(kind: EntryKind.task, text: (e['message'] ?? '') as String, action: e['action'] as String, params: Map<String, dynamic>.from((e['params'] ?? {}) as Map), index: idx);
        entries.add(entry);
        _resultsByTask[idx] = entry;
        break;
      case 'result':
        final idx = e['index'] as int;
        final owner = _resultsByTask[idx];
        final result = Entry(kind: EntryKind.result, text: (e['output'] ?? '') as String, action: e['action'] as String, seconds: ((e['seconds'] ?? 0) as num).toDouble(), index: idx);
        // the result is attached to its task card; it is stored in the entry list right after the task so the view can pair them
        final at = owner == null ? entries.length : entries.indexOf(owner) + 1;
        entries.insert(at.clamp(0, entries.length), result);
        _resultsByTask.remove(idx);
        break;
      case 'ask':
        entries.add(Entry(kind: EntryKind.ask, ask: Map<String, dynamic>.from(e), resolved: replay, answer: replay ? 'recorded in history' : null));
        break;
      case 'countdown':
        if (!replay) {
          countdownActive = true;
          countdownSeconds = (e['seconds'] ?? 8) as int;
        }
        break;
      case 'nudge':
        countdownActive = false;
        entries.add(Entry(kind: EntryKind.nudge, text: e['text'] as String));
        break;
      case 'network':
        final a = NetworkAudit.fromJson(Map<String, dynamic>.from(e['audit'] as Map));
        if (!replay) audit.add(a);
        entries.add(Entry(kind: EntryKind.network, audit: Map<String, dynamic>.from(e['audit'] as Map)));
        break;
      case 'final':
        thinking = false;
        countdownActive = false;
        final t = (e['text'] ?? '').toString().trim();
        final m = (e['message'] ?? '').toString().trim();
        final finalText = (t.isNotEmpty && m.isNotEmpty)
            ? (t.length >= m.length ? t : m)
            : (t.isNotEmpty ? t : m);
        entries.add(Entry(kind: EntryKind.final_, text: finalText, revealed: replay));
        break;
      case 'error':
        entries.add(Entry(kind: EntryKind.error, text: (e['text'] ?? 'error') as String));
        break;
      case 'cancelled':
        thinking = false;
        countdownActive = false;
        entries.add(Entry(kind: EntryKind.info, text: 'Stopped.'));
        break;
      case 'autopilot':
        autopilot = e['enabled'] as bool;
        break;
      case 'disconnected':
        if (busy) {
          serverLost = true;
          entries.add(Entry(kind: EntryKind.error, text: 'Lost the connection to the backend. It may still be working; reopen this chat to see what happened.'));
        }
        busy = thinking = countdownActive = false;
        break;
      case 'done':
        busy = thinking = countdownActive = false;
        break;
    }
    notifyListeners();
  }

  Entry? resultFor(Entry task) {
    final i = entries.indexOf(task);
    if (i < 0 || i + 1 >= entries.length) return null;
    final next = entries[i + 1];
    return next.kind == EntryKind.result && next.index == task.index ? next : null;
  }

  void send(String text) {
    entries.add(Entry(kind: EntryKind.user, text: text));
    busy = true;
    backend.sendMessage(text, sessionId, autopilot);
    notifyListeners();
  }

  void answerAsk(Entry entry, String answer) {
    entry.resolved = true;
    entry.answer = entry.ask!['kind'] == 'question' ? answer : (answer == 'yes' ? 'Allowed' : 'Denied');
    backend.reply(sessionId!, entry.ask!['request_id'] as String, answer);
    notifyListeners();
  }

  void sendNudge(String text) {
    countdownActive = false;
    backend.nudge(sessionId!, text);
    notifyListeners();
  }

  void expireCountdown() {
    countdownActive = false;
    notifyListeners();
  }

  void stop() {
    if (sessionId != null) backend.cancel(sessionId!);
  }

  void toggleAutopilot(bool value) {
    autopilot = value;
    if (sessionId != null) backend.setAutopilot(sessionId!, value);
    notifyListeners();
  }
}