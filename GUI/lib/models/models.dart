// Plain data classes shared by the services and the screens.

class SessionInfo {
  final String id, name, created, updated;
  final int messages;
  SessionInfo({required this.id, required this.name, required this.created, required this.updated, required this.messages});
  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
      id: j['id'] as String, name: j['name'] as String, created: j['created'] as String, updated: (j['updated'] ?? j['created']) as String, messages: (j['messages'] ?? 0) as int);
}

enum EntryKind { user, task, result, final_, ask, nudge, error, network, info }

// One row in the conversation view. Built from backend events (live or replayed from history).
class Entry {
  final EntryKind kind;
  final String text;                 // user text, final answer, task message, result output, error text
  final String action;               // for task/result
  final Map<String, dynamic> params; // for task
  final Map<String, dynamic>? ask;   // for ask
  final Map<String, dynamic>? audit; // for network
  final double seconds;
  bool resolved;                     // ask answered
  String? answer;
  int? index;                        // task index within a batch
  bool revealed;                     // final answer typewriter finished
  Entry({required this.kind, this.text = '', this.action = '', this.params = const {}, this.ask, this.audit, this.seconds = 0, this.resolved = false, this.answer, this.index, this.revealed = true});
}

class NetworkAudit {
  final String time, method, url, sha256, note;
  final int bytes;
  final bool sent, clean;
  NetworkAudit({required this.time, required this.method, required this.url, required this.sha256, required this.note, required this.bytes, required this.sent, required this.clean});
  factory NetworkAudit.fromJson(Map<String, dynamic> j) {
    final scan = (j['leak_scan'] as Map?) ?? const {};
    return NetworkAudit(
        time: (j['time'] ?? '') as String, method: (j['method'] ?? '') as String, url: (j['url'] ?? '') as String, sha256: (j['outbound_sha256'] ?? '') as String,
        note: (j['note'] ?? '') as String, bytes: (j['outbound_bytes'] ?? 0) as int, sent: (j['sent'] ?? false) as bool, clean: (scan['clean'] ?? true) as bool);
  }
  bool get blocked => note.contains('BLOCKED');
}
