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
          id: '1712000000000001',
          xmppId: before.last.xmppId,
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

  test('roomJID forces single-room selection flow', () async {
    final store = InMemoryStore()
      ..user = const ChatUser(
        id: 'u1',
        username: 'tester',
        token: 'token',
        refreshToken: 'refresh',
        xmppUsername: 'tester',
        xmppPassword: 'pass',
      );

    final controller = ChatComponentController(
      config: const ChatComponentConfig(
        roomJID: 'forced@conference.xmpp.test',
        xmppSettings: XmppSettings(
          xmppServerUrl: 'wss://xmpp.test/ws',
          host: 'xmpp.test',
          conference: 'conference.xmpp.test',
        ),
      ),
      store: store,
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(rooms: const []),
      xmppClientFactory: FakeXmppClient.new,
    );

    await controller.initialize();
    expect(
      controller.state.value.selectedRoomJid,
      'forced@conference.xmpp.test',
    );
    expect(
      controller.state.value.rooms.any(
        (e) => e.jid == 'forced@conference.xmpp.test',
      ),
      true,
    );
  });

  test('onMessageSent callback fires once after ack', () async {
    final store = InMemoryStore()
      ..user = const ChatUser(
        id: 'u1',
        username: 'tester',
        token: 'token',
        refreshToken: 'refresh',
        xmppUsername: 'tester',
        xmppPassword: 'pass',
      );

    var callbackCount = 0;
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
      config: ChatComponentConfig(
        xmppSettings: const XmppSettings(
          xmppServerUrl: 'wss://xmpp.test/ws',
          host: 'xmpp.test',
          conference: 'conference.xmpp.test',
        ),
        eventHandlers: ChatEventHandlers(
          onMessageSent: (event) async {
            callbackCount += 1;
          },
        ),
      ),
      store: store,
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(
        rooms: const [ChatRoom(jid: 'room@conference.xmpp.test')],
      ),
      xmppClientFactory: ({required settings, required user, required log}) =>
          fakeXmpp,
    );

    await controller.initialize();
    await controller.sendText('room@conference.xmpp.test', 'hello');
    final localPending = controller
        .state.value.messagesByRoom['room@conference.xmpp.test']!.last;

    fakeXmpp.emitIncoming(
      ChatMessage(
        id: '1712000000000002',
        xmppId: localPending.xmppId,
        roomJid: 'room@conference.xmpp.test',
        text: 'hello',
        user: const ChatUser(username: 'tester'),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    fakeXmpp.emitIncoming(
      ChatMessage(
        id: '1712000000000002',
        xmppId: localPending.xmppId,
        roomJid: 'room@conference.xmpp.test',
        text: 'hello',
        user: const ChatUser(username: 'tester'),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(callbackCount, 1);
  });
}
