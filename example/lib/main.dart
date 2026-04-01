import 'dart:async';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter/material.dart';

const kEthoraChatAppId = '646cc8dc96d4a4dc8f7b2f2d';
const kEthoraApiUrl = 'https://api.ethoradev.com';
const kEthoraApiToken =
    'JWT eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJkYXRhIjp7ImlzVXNlckRhdGFFbmNyeXB0ZWQiOmZhbHNlLCJwYXJlbnRBcHBJZCI6bnVsbCwiaXNBbGxvd2VkTmV3QXBwQ3JlYXRlIjp0cnVlLCJpc0Jhc2VBcHAiOnRydWUsIl9pZCI6IjY0NmNjOGRjOTZkNGE0ZGM4ZjdiMmYyZCIsImRpc3BsYXlOYW1lIjoiRXRob3JhIiwiZG9tYWluTmFtZSI6ImV0aG9yYSIsImNyZWF0b3JJZCI6IjY0NmNjOGQzOTZkNGE0ZGM4ZjdiMmYyNSIsInVzZXJzQ2FuRnJlZSI6dHJ1ZSwiZGVmYXVsdEFjY2Vzc0Fzc2V0c09wZW4iOnRydWUsImRlZmF1bHRBY2Nlc3NQcm9maWxlT3BlbiI6dHJ1ZSwiYnVuZGxlSWQiOiJjb20uZXRob3JhIiwicHJpbWFyeUNvbG9yIjoiIzAwM0U5QyIsInNlY29uZGFyeUNvbG9yIjoiIzI3NzVFQSIsImNvaW5TeW1ib2wiOiJFVE8iLCJjb2luTmFtZSI6IkV0aG9yYSBDb2luIiwiUkVBQ1RfQVBQX0ZJUkVCQVNFX0FQSV9LRVkiOiJBSXphU3lEUWRrdnZ4S0t4NC1XcmpMUW9ZZjA4R0ZBUmdpX3FPNGciLCJSRUFDVF9BUFBfRklSRUJBU0VfQVVUSF9ET01BSU4iOiJldGhvcmEtNjY4ZTkuZmlyZWJhc2VhcHAuY29tIiwiUkVBQ1RfQVBQX0ZJUkVCQVNFX1BST0pFQ1RfSUQiOiJldGhvcmEtNjY4ZTkiLCJSRUFDVF9BUFBfRklSRUJBU0VfU1RPUkFHRV9CVUNLRVQiOiJldGhvcmEtNjY4ZTkuYXBwc3BvdC5jb20iLCJSRUFDVF9BUFBfRklSRUJBU0VfTUVTU0FHSU5HX1NFTkRFUl9JRCI6Ijk3MjkzMzQ3MDA1NCIsIlJFQUNUX0FQUF9GSVJFQkFTRV9BUFBfSUQiOiIxOjk3MjkzMzQ3MDA1NDp3ZWI6ZDQ2ODJlNzZlZjAyZmQ5YjljZGFhNyIsIlJFQUNUX0FQUF9GSVJFQkFTRV9NRUFTVVJNRU5UX0lEIjoiRy1XSE03WFJaNEM4IiwiUkVBQ1RfQVBQX1NUUklQRV9QVUJMSVNIQUJMRV9LRVkiOiIiLCJSRUFDVF9BUFBfU1RSSVBFX1NFQ1JFVF9LRVkiOiIiLCJjcmVhdGVkQXQiOiIyMDIzLTA1LTIzVDE0OjA4OjI4LjEzNloiLCJ1cGRhdGVkQXQiOiIyMDIzLTA1LTIzVDE0OjA4OjI4LjEzNloiLCJfX3YiOjB9LCJpYXQiOjE2ODQ4NTA5MjV9.-IqNVMsf8GyS9Z-_yuNW7hpSmejajjAy-W0J8TadRIM';
const kXmppWs = 'wss://xmpp-dev.preshent.com/ws';
const kXmppConference = 'conference.xmpp-dev.preshent.com';
const kXmppHost = 'xmpp-dev.preshent.com';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  late final ChatComponentController _controller;
  final List<ChatLogEvent> _logs = <ChatLogEvent>[];
  StreamSubscription<ChatLogEvent>? _logSubscription;

  @override
  void initState() {
    super.initState();
    _controller = ChatComponentController(
      config: const ChatComponentConfig(
        appId: kEthoraChatAppId,
        baseUrl: kEthoraApiUrl,
        customAppToken: kEthoraApiToken,
        defaultLogin: true,
        disableRooms: false,
        refreshTokens: RefreshTokensConfig(enabled: true),
        xmppSettings: XmppSettings(
          xmppServerUrl: kXmppWs,
          host: kXmppHost,
          conference: kXmppConference,
        ),
      ),
    );
    _logSubscription = _controller.logs.listen((event) {
      if (!mounted) return;
      setState(() {
        _logs.insert(0, event);
        if (_logs.length > 400) {
          _logs.removeRange(400, _logs.length);
        }
      });
    });
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _controller.dispose();
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
            title: const Text('Ethora Flutter Example'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Home'),
                Tab(text: 'Chat'),
                Tab(text: 'Logs'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              _HomeTab(controller: _controller),
              ChatComponent(
                  controller: _controller, config: _controller.config),
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
            const Text('Environment',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const SelectableText('API URL: $kEthoraApiUrl'),
            const SelectableText('APP ID: $kEthoraChatAppId'),
            const SelectableText('XMPP WS: $kXmppWs'),
            const SizedBox(height: 16),
            Text('Connection: ${state.connectionState.name}'),
            Text('Initialized: ${state.isInitialized}'),
            Text('User: ${state.user?.displayName ?? 'none'}'),
            Text('Rooms: ${state.rooms.length}'),
            if ((state.errorMessage ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Error: ${state.errorMessage}',
                  style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
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
                  child: const Text('Disconnect / Clear Session'),
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
        final item = logs[index];
        return ListTile(
          dense: true,
          title: Text('[${item.category.name}] ${item.message}'),
          subtitle: Text(
            '${item.timestamp.toIso8601String()} • ${item.level.name}',
            style: const TextStyle(fontSize: 12),
          ),
        );
      },
    );
  }
}
