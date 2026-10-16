import 'dart:async';

import 'package:flutter/material.dart';

import '../core/chat_component_controller.dart';
import '../core/chat_component_log.dart';
import '../core/chat_component_state.dart';
import '../models/chat_component_config.dart';
import 'chat_component_widget.dart';

class ChatComponentDemoApp extends StatefulWidget {
  const ChatComponentDemoApp({
    super.key,
    required this.controller,
    required this.config,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;

  @override
  State<ChatComponentDemoApp> createState() => _ChatComponentDemoAppState();
}

class _ChatComponentDemoAppState extends State<ChatComponentDemoApp> {
  final List<ChatLogEvent> _logs = <ChatLogEvent>[];
  StreamSubscription<ChatLogEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.controller.logs.listen((event) {
      if (!mounted) return;
      setState(() {
        _logs.insert(0, event);
        if (_logs.length > 300) {
          _logs.removeRange(300, _logs.length);
        }
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Ethora Flutter Demo'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Apps'),
                Tab(text: 'Chat'),
                Tab(text: 'Logs'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              _HomeTab(controller: widget.controller),
              ChatComponent(
                controller: widget.controller,
                config: widget.config,
              ),
              _LogsTab(logs: _logs),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.controller});

  final ChatComponentController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatComponentState>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Connection: ${state.connectionState.name}'),
            Text('Initialized: ${state.isInitialized}'),
            Text('Rooms: ${state.rooms.length}'),
            const SizedBox(height: 12),
            for (final room in state.rooms)
              ListTile(
                dense: true,
                title: Text(room.title ?? room.jid),
                subtitle: Text(room.jid),
                trailing: Text(
                  room.unreadCapped
                      ? '${room.unreadCount}+'
                      : '${room.unreadCount}',
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: controller.initialize,
                  child: const Text('Initialize'),
                ),
                ElevatedButton(
                  onPressed: controller.logout,
                  child: const Text('Logout'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _LogsTab extends StatelessWidget {
  const _LogsTab({required this.logs});

  final List<ChatLogEvent> logs;

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return const Center(child: Text('No logs yet'));
    }
    return ListView.separated(
      itemCount: logs.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final event = logs[index];
        return ListTile(
          dense: true,
          title: Text('[${event.category.name}] ${event.message}'),
          subtitle: Text(
            '${event.timestamp.toIso8601String()} • ${event.level.name}',
            style: const TextStyle(fontSize: 12),
          ),
        );
      },
    );
  }
}
