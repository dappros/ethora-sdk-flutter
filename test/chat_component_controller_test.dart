import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test(
    'initialize requires login when defaultLogin is true and no session',
    () async {
      final controller = ChatComponentController(
        config: const ChatComponentConfig(defaultLogin: true),
        store: InMemoryStore(),
        roomsService: FakeRoomsService(),
        authService: FakeAuthService(),
        xmppClientFactory: FakeXmppClient.new,
      );

      await controller.initialize();
      expect(controller.state.value.requiresLogin, true);
      expect(controller.state.value.isInitialized, false);
    },
  );

  test(
    'sendText creates pending message and clears after incoming echo',
    () async {
      final store = InMemoryStore()
        ..user = const ChatUser(
          id: 'u1',
          username: 'tester',
          token: 'token',
          refreshToken: 'refresh',
          xmppUsername: 'tester',
          xmppPassword: 'pass',
        );

      final fakeXmpp = FakeXmppClient(
        settings: const XmppSettings(
          xmppServerUrl: 'wss://xmpp.test/ws',
          host: 'xmpp.test',
          conference: 'conference.xmpp.test',
        ),
        user: store.user!,
        log: (_) {},
      );

      final controller = ChatComponentController(
        config: const ChatComponentConfig(
          disableRooms: true,
          xmppSettings: XmppSettings(
            xmppServerUrl: 'wss://xmpp.test/ws',
            host: 'xmpp.test',
            conference: 'conference.xmpp.test',
          ),
        ),
        store: store,
        authService: FakeAuthService(),
        roomsService: FakeRoomsService(
          rooms: const [
            ChatRoom(jid: 'room@conference.xmpp.test', title: 'Room'),
          ],
        ),
        xmppClientFactory: ({required settings, required user, required log}) =>
            fakeXmpp,
      );

      await controller.initialize();
      await controller.sendText('room@conference.xmpp.test', 'hello');
      final before =
          controller.state.value.messagesByRoom['room@conference.xmpp.test']!;
      expect(before.last.pending, true);

      fakeXmpp.emitIncoming(
        ChatMessage(
          id: 'server-id',
          roomJid: 'room@conference.xmpp.test',
          text: 'hello',
          user: const ChatUser(username: 'tester'),
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final after =
          controller.state.value.messagesByRoom['room@conference.xmpp.test']!;
      expect(after.last.pending, false);
    },
  );
}
