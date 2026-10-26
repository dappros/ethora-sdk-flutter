import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _room = 'room@conference.xmpp.test';
const _settings = XmppSettings(
  xmppServerUrl: 'wss://xmpp.test/ws',
  host: 'xmpp.test',
  conference: 'conference.xmpp.test',
);

Future<(ChatComponentController, FakeXmppClient, ChatComponentConfig)> _boot({
  ChatComponentConfig? config,
}) async {
  final store = InMemoryStore()
    ..user = const ChatUser(
      id: 'me',
      username: 'me',
      firstName: 'Me',
      token: 't',
      refreshToken: 'r',
      xmppUsername: 'me',
      xmppPassword: 'p',
    );
  final fake = FakeXmppClient(
    settings: _settings,
    user: store.user!,
    log: (_) {},
  );
  final cfg = config ??
      const ChatComponentConfig(
        roomJID: _room,
        xmppSettings: _settings,
      );
  final controller = ChatComponentController(
    config: cfg,
    store: store,
    authService: FakeAuthService(),
    roomsService: FakeRoomsService(
      rooms: const [ChatRoom(jid: _room, title: 'Team room')],
    ),
    xmppClientFactory: ({required settings, required user, required log}) =>
        fake,
  );
  await controller.initialize();
  return (controller, fake, cfg);
}

ChatMessage _incoming(String id, String text, {String sender = 'bob'}) {
  return ChatMessage(
    id: id,
    xmppId: 'x$id',
    roomJid: _room,
    text: text,
    user: ChatUser(
      id: sender,
      username: sender,
      xmppUsername: sender,
      firstName: sender,
    ),
    createdAtMs: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  testWidgets('single room chat renders messages, menu and composer',
      (tester) async {
    final (controller, fake, config) = await _boot();
    fake.emitIncoming(_incoming('1712000000000001', 'hello from bob'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComponent(controller: controller, config: config),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Team room'), findsWidgets);
    expect(find.text('hello from bob'), findsOneWidget);

    await tester.longPress(find.text('hello from bob'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    // quick reaction bar shows the default shortcodes as glyphs
    expect(find.text('👍'), findsOneWidget);

    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();
    expect(fake.sentReactions.single.$3, ['+1']);

    // composer sends a text
    await tester.enterText(find.byType(TextField).last, 'my answer');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.sentTexts.last['text'], 'my answer');
    controller.dispose();
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  testWidgets('dark scheme and reply thread open', (tester) async {
    final (controller, fake, base) = await _boot(
      config: const ChatComponentConfig(
        roomJID: _room,
        xmppSettings: _settings,
        colorScheme: ChatColorScheme.dark,
      ),
    );
    fake.emitIncoming(_incoming('1712000000000001', 'root message'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComponent(controller: controller, config: base),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    controller.openThread(controller.messageById(_room, '1712000000000001')!);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Thread'), findsOneWidget);
    final material = tester.widget<Material>(find.byType(Material).first);
    expect(material, isNotNull);
    controller.closeThread();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Thread'), findsNothing);
    controller.dispose();
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });
}
