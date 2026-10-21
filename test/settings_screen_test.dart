import 'dart:convert';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const XmppSettings _xmpp = XmppSettings(
  xmppServerUrl: 'wss://xmpp.test/ws',
  host: 'xmpp.test',
  conference: 'conference.xmpp.test',
);

Future<(ChatComponentController, List<String>)> _controller(
  ChatComponentConfig config,
) async {
  final calls = <String>[];
  final store = InMemoryStore()
    ..token = 'access-1'
    ..refreshToken = 'refresh-1'
    ..user = const ChatUser(
      id: 'u1',
      appId: 'app-1',
      firstName: 'Ada',
      lastName: 'Lovelace',
      email: 'ada@example.test',
      username: 'ada',
      token: 'access-1',
      refreshToken: 'refresh-1',
      xmppUsername: 'ada',
      xmppPassword: 'pw',
      appLanguage: 'en-CA',
    );
  final api = ApiClient(
    config: const ChatComponentConfig(baseUrl: 'https://api.example.test/v1'),
    readAccessToken: store.getToken,
    readRefreshToken: store.getRefreshToken,
    writeTokens: (_, __) async {},
    clearSession: store.clearSession,
    log: (_) {},
    httpClient: MockClient((request) async {
      calls.add('${request.method} ${request.url.path} ${request.body}');
      if (request.url.path == '/v1/users/exportData') {
        return http.Response(jsonEncode(<String, Object?>{'name': 'Ada'}), 200);
      }
      return http.Response('{}', 200);
    }),
  );
  final controller = ChatComponentController(
    config: config,
    store: store,
    apiClient: api,
    authService: FakeAuthService(),
    roomsService: FakeRoomsService(),
    xmppClientFactory: FakeXmppClient.new,
  );
  await controller.initialize();
  return (controller, calls);
}

Widget _host(
  ChatComponentController controller,
  ChatComponentConfig config,
) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            TextButton(
              onPressed: () => showChatSettings(
                context,
                controller: controller,
                config: config,
              ),
              child: const Text('open'),
            ),
            TextButton(
              onPressed: () => confirmAndLogout(
                context,
                controller: controller,
                config: config,
              ),
              child: const Text('logout-header'),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    // Push keeps its small state in shared preferences.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('shows only what the config enables', (tester) async {
    const config = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
    );
    final (controller, _) = await _controller(config);
    await tester.pumpWidget(_host(controller, config));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(find.text('ada@example.test'), findsOneWidget);
    expect(find.text('Interface language'), findsNothing);
    expect(find.text('Change password'), findsNothing);
    expect(find.text('Download your data'), findsOneWidget);
    expect(find.text('Delete your account'), findsOneWidget);
    expect(find.text('Log Out'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('language pickers write one field per request', (tester) async {
    const config = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
      settings: ChatSettingsConfig(
        languages: ChatLanguagesConfig(enabled: true),
      ),
    );
    final (controller, calls) = await _controller(config);
    await tester.pumpWidget(_host(controller, config));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Interface language'), findsOneWidget);
    expect(find.text('Translate messages into'), findsOneWidget);

    await tester.tap(find.text('English').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Français').last);
    await tester.pumpAndSettle();

    expect(calls, contains('PUT /v1/users {"appLanguage":"fr-CA"}'));
    expect(controller.state.value.user!.appLanguage, 'fr-CA');
    // The screen re-localises at once.
    expect(find.text('Paramètres'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('change password validates, sends and reports the server reason',
      (tester) async {
    const config = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
      settings: ChatSettingsConfig(changePassword: true),
    );
    final (controller, calls) = await _controller(config);
    await tester.pumpWidget(_host(controller, config));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change password').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'old-secret');
    await tester.enterText(find.byType(TextField).last, 'abc');
    await tester.tap(find.text('Change password').last);
    await tester.pumpAndSettle();
    expect(find.text('Password must be at least 6 characters long'),
        findsOneWidget);
    expect(calls.where((c) => c.contains('password')), isEmpty);

    await tester.enterText(find.byType(TextField).last, 'new-secret');
    await tester.tap(find.text('Change password').last);
    await tester.pumpAndSettle();
    expect(
      calls,
      contains(
        'PUT /v2/users/me/password '
        '{"currentPassword":"old-secret","newPassword":"new-secret"}',
      ),
    );
    expect(find.text('Password changed.'), findsWidgets);
    controller.dispose();
  });

  testWidgets('export goes to the host callback when one is set',
      (tester) async {
    List<int>? received;
    String? name;
    final config = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
      settings: ChatSettingsConfig(
        onExportData: (bytes, fileName) async {
          received = bytes;
          name = fileName;
        },
      ),
    );
    final (controller, _) = await _controller(config);
    await tester.pumpWidget(_host(controller, config));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download your data'));
    await tester.pumpAndSettle();
    expect(utf8.decode(received!), '{"name":"Ada"}');
    expect(name, 'ethora-data-export.json');
    controller.dispose();
  });

  testWidgets('without a callback the export opens in a copyable dialog',
      (tester) async {
    const config = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
    );
    final (controller, _) = await _controller(config);
    await tester.pumpWidget(_host(controller, config));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download your data'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"name": "Ada"'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('delete account asks first, then deletes and signs out',
      (tester) async {
    const config = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
    );
    final (controller, calls) = await _controller(config);
    await tester.pumpWidget(_host(controller, config));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete your account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.startsWith('DELETE /v1/users ')), isEmpty);

    await tester.tap(find.text('Delete your account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.startsWith('DELETE /v1/users ')), hasLength(1));
    expect(controller.state.value.requiresLogin, isTrue);
    // Settings closed itself: only the host page is left.
    expect(find.text('Settings'), findsNothing);
    controller.dispose();
  });

  testWidgets('logout confirms by default and honours confirm: false',
      (tester) async {
    const config = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
    );
    final (controller, _) = await _controller(config);
    await tester.pumpWidget(_host(controller, config));

    await tester.tap(find.text('logout-header'));
    await tester.pumpAndSettle();
    expect(find.text('Log out?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.state.value.requiresLogin, isFalse);

    await tester.tap(find.text('logout-header'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log Out'));
    await tester.pumpAndSettle();
    expect(controller.state.value.requiresLogin, isTrue);
    controller.dispose();

    const noConfirm = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
      logout: ChatLogoutConfig(confirm: false),
    );
    final (second, _) = await _controller(noConfirm);
    await tester.pumpWidget(_host(second, noConfirm));
    await tester.tap(find.text('logout-header'));
    await tester.pumpAndSettle();
    expect(second.state.value.requiresLogin, isTrue);
    second.dispose();
  });

  testWidgets(
      'the push switch shows only when push is configured and '
      'releases the device when turned off', (tester) async {
    const plain = ChatComponentConfig(disableRooms: true, xmppSettings: _xmpp);
    final (first, _) = await _controller(plain);
    await tester.pumpWidget(_host(first, plain));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Push notifications'), findsNothing);
    first.dispose();
    await tester.pumpWidget(const SizedBox.shrink());

    const config = ChatComponentConfig(
      appId: 'app-1',
      disableRooms: true,
      xmppSettings: _xmpp,
      pushNotifications: PushNotificationsConfig(),
    );
    final (controller, calls) = await _controller(config);
    await controller.registerPushToken('fcm-token');
    calls.clear();
    await tester.pumpWidget(_host(controller, config));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Push notifications'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(controller.pushEnabledByUser, isFalse);
    expect(calls.any((c) => c.startsWith('DELETE /v1/push/subscription/app-1')),
        isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(controller.pushEnabledByUser, isTrue);
    expect(calls.any((c) => c.startsWith('POST /v1/push/subscription/app-1')),
        isTrue);
    controller.dispose();
  });

  testWidgets('logout disabled hides the button and ignores the helper',
      (tester) async {
    const config = ChatComponentConfig(
      disableRooms: true,
      xmppSettings: _xmpp,
      logout: ChatLogoutConfig(enabled: false),
    );
    final (controller, _) = await _controller(config);
    await tester.pumpWidget(_host(controller, config));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Log Out'), findsNothing);
    controller.dispose();
  });
}
