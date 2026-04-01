import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test('setTyping sends start and auto stop', () async {
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
        rooms: const [ChatRoom(jid: 'room@conference.xmpp.test')],
      ),
      xmppClientFactory: ({required settings, required user, required log}) =>
          fakeXmpp,
    );

    await controller.initialize();
    await controller.setTyping('room@conference.xmpp.test', true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(fakeXmpp.typingCalls.length, greaterThanOrEqualTo(2));
    expect(fakeXmpp.typingCalls.first.$2, true);
    expect(fakeXmpp.typingCalls.last.$2, false);
  });
}
