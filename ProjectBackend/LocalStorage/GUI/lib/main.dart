// Entry point. Boots the Flutter app, fetches the server token, then shows the chat screen.
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show FlutterErrorDetails;

import 'screens/chat_screen.dart';
import 'services/backend.dart';
import 'theme.dart';

void main() {
  // BLACK-SCREEN FIX: previously, an uncaught error thrown ABOVE MaterialApp (i.e. anywhere before the widget
  // tree that owns the red error screen exists) had nothing to catch it. Flutter web's default behaviour for
  // an error during the very first frame, outside of a build() Flutter already instruments, is to log to the
  // browser console and paint nothing - which looks exactly like a black screen with zero on-page indication.
  // runZonedGuarded + FlutterError.onError below make sure ANY such error is caught and shown as a real,
  // visible error screen instead of silently failing to paint.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };
  runApp(const AgenticApp());
}

class AgenticApp extends StatefulWidget {
  const AgenticApp({super.key});

  @override
  State<AgenticApp> createState() => _AgenticAppState();
}

class _AgenticAppState extends State<AgenticApp> {
  // BLACK-SCREEN FIX: this used to be a field initializer -
  //   Brightness _brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
  // Field initializers for a StatefulWidget's State run during createState(), i.e. BEFORE build() and before
  // MaterialApp exists anywhere in the tree. On some web engine startup timings (a fresh CanvasKit/skwasm
  // load in particular), the platformDispatcher isn't fully attached yet and this throws. Because it throws
  // above MaterialApp, there is no error UI to catch it - it's a silent black screen. Moving the same read
  // into initState (still synchronous, still no visible delay) with a try/catch and a safe default removes
  // that failure mode entirely; worst case, the app just opens in light mode instead of matching the OS.
  late Brightness _brightness;

  @override
  void initState() {
    super.initState();
    try {
      _brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    } catch (_) {
      _brightness = Brightness.light;
    }
  }

  void _toggleBrightness() => setState(() => _brightness = _brightness == Brightness.dark ? Brightness.light : Brightness.dark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgenticAI',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: _brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: _Root(onToggleBrightness: _toggleBrightness, brightness: _brightness),
    );
  }
}

class _Root extends StatefulWidget {
  final VoidCallback onToggleBrightness;
  final Brightness brightness;
  const _Root({required this.onToggleBrightness, required this.brightness});

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  late final Backend _backend;
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final origin = Uri.base;
    _backend = Backend(origin);
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _backend.fetchToken();
      // connect() opens the WebSocket synchronously (WebSocketChannel.connect can throw immediately if the
      // origin/port it derives is malformed - e.g. some web hosting setups where Uri.base.port doesn't match
      // the server's actual port). That throw was already inside this try/catch so it was never actually the
      // black-screen cause, but keeping it explicit here (rather than relying on it happening to be caught)
      // makes that guarantee obvious rather than incidental.
      _backend.connect();
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _backend.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 48, color: warnRed),
            const SizedBox(height: 16),
            Text('Could not connect to the backend', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: paletteOf(context).textDim)),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: () { setState(() => _error = null); _boot(); }, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ]),
        ),
      );
    }
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ChatScreen(backend: _backend, onToggleBrightness: widget.onToggleBrightness, brightness: widget.brightness);
  }
}