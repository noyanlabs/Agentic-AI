// Talks to server.py: REST for history, WebSocket for the live agent. Mirrors the protocol tested on the Python side.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/models.dart';

class Backend {
  final Uri origin;                       // where the page was served from (same host and port as the server)
  String? token;
  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();

  Backend(this.origin);

  Stream<Map<String, dynamic>> get events => _events.stream;
  bool get connected => _channel != null;

  String get _http => '${origin.scheme}://${origin.host}:${origin.port}';
  String get _ws => '${origin.scheme == 'https' ? 'wss' : 'ws'}://${origin.host}:${origin.port}/ws?token=$token';
  Map<String, String> get _headers => {'x-agent-token': token ?? ''};

  // Asks the server for the per-launch token. Only same-origin pages can read it.
  Future<void> fetchToken() async {
    final r = await http.get(Uri.parse('$_http/gui-config.json')).timeout(const Duration(seconds: 5));
    if (r.statusCode != 200) throw Exception('server refused the token request (${r.statusCode})');
    token = (jsonDecode(r.body) as Map<String, dynamic>)['token'] as String;
  }

  Future<Map<String, dynamic>> health() async {
    final r = await http.get(Uri.parse('$_http/health')).timeout(const Duration(seconds: 3));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<SessionInfo>> sessions() async {
    final r = await http.get(Uri.parse('$_http/api/sessions'), headers: _headers);
    if (r.statusCode != 200) throw Exception('could not load chats (${r.statusCode})');
    return (jsonDecode(r.body) as List).map((e) => SessionInfo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Map<String, dynamic>> sessionDetail(String id) async {
    final r = await http.get(Uri.parse('$_http/api/sessions/$id'), headers: _headers);
    if (r.statusCode != 200) throw Exception('could not load chat (${r.statusCode})');
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> deleteSession(String id) async {
    await http.delete(Uri.parse('$_http/api/sessions/$id'), headers: _headers);
  }

  void connect() {
    _channel?.sink.close();
    final ch = WebSocketChannel.connect(Uri.parse(_ws));
    _channel = ch;
    ch.stream.listen(
      (raw) {
        try {
          _events.add(jsonDecode(raw as String) as Map<String, dynamic>);
        } catch (_) {}
      },
      onError: (e) {
        _events.add({'type': 'error', 'text': 'Connection problem: $e'});
        _channel = null;
      },
      onDone: () {
        if (_channel == ch) {
          _channel = null;
          _events.add({'type': 'disconnected'});
        }
      },
    );
  }

  void _send(Map<String, dynamic> m) {
    if (_channel == null) connect();
    _channel!.sink.add(jsonEncode(m));
  }

  void sendMessage(String text, String? sessionId, bool autopilot) => _send({'type': 'send', 'text': text, 'session_id': sessionId, 'autopilot': autopilot});
  void reply(String sessionId, String requestId, String answer) => _send({'type': 'reply', 'session_id': sessionId, 'request_id': requestId, 'answer': answer});
  void nudge(String sessionId, String text) => _send({'type': 'nudge', 'session_id': sessionId, 'text': text});
  void cancel(String sessionId) => _send({'type': 'cancel', 'session_id': sessionId});
  void setAutopilot(String sessionId, bool enabled) => _send({'type': 'autopilot', 'session_id': sessionId, 'enabled': enabled});
  void attach(String sessionId) => _send({'type': 'attach', 'session_id': sessionId});

  void dispose() {
    _channel?.sink.close();
    _events.close();
  }
}
