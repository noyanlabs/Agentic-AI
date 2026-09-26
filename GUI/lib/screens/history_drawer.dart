// The history side-drawer: lists past sessions and lets you open or delete them.
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/backend.dart';
import '../theme.dart';

class HistoryDrawer extends StatefulWidget {
  final Backend backend;
  final String? activeSessionId;
  final void Function(Map<String, dynamic> data) onOpen;
  final VoidCallback onNewChat;
  const HistoryDrawer({super.key, required this.backend, this.activeSessionId, required this.onOpen, required this.onNewChat});

  @override
  State<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<HistoryDrawer> {
  List<SessionInfo>? _sessions;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.backend.sessions();
      if (mounted) setState(() { _sessions = list; _err = null; });
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  Future<void> _open(SessionInfo s) async {
    try {
      final data = await widget.backend.sessionDetail(s.id);
      widget.onOpen(data);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load session: $e')));
      }
    }
  }

  Future<void> _delete(SessionInfo s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text('"${s.name}" will be removed from history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.backend.deleteSession(s.id);
      _load();
    }
  }

  String _relTime(String iso) {
    try {
      final t = DateTime.parse(iso);
      final diff = DateTime.now().difference(t);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inHours < 1) return '${diff.inMinutes}m ago';
      if (diff.inDays < 1) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${t.day}/${t.month}/${t.year}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Drawer(
      backgroundColor: p.surface,
      width: 300,
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(children: [
              Text('Chats', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: p.text)),
              const Spacer(),
              IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
              IconButton(tooltip: 'New chat', icon: const Icon(Icons.add, size: 20), onPressed: widget.onNewChat),
            ]),
          ),
          Divider(color: p.border, height: 1),
          Expanded(child: _body(p)),
        ]),
      ),
    );
  }

  Widget _body(Palette p) {
    if (_err != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_err!, textAlign: TextAlign.center, style: TextStyle(color: p.textDim, fontSize: 13)),
          const SizedBox(height: 12),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ]),
      ));
    }
    if (_sessions == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (_sessions!.isEmpty) {
      return Center(child: Text('No saved chats yet.', style: TextStyle(color: p.textDim, fontSize: 13)));
    }
    return ListView.builder(
      itemCount: _sessions!.length,
      itemBuilder: (_, i) {
        final s = _sessions![i];
        final isActive = s.id == widget.activeSessionId;
        return ListTile(
          selected: isActive,
          selectedTileColor: p.surfaceAlt,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: isActive ? FontWeight.w600 : FontWeight.normal, color: p.text)),
          subtitle: Text('${_relTime(s.updated)} · ${s.messages} msg', style: TextStyle(fontSize: 11.5, color: p.textDim)),
          trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 17), tooltip: 'Delete', onPressed: () => _delete(s)),
          onTap: () { Navigator.pop(context); _open(s); },
        );
      },
    );
  }
}
