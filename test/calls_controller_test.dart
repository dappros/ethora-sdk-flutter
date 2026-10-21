import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const String roomJid = 'a-b@conference.xmpp.test';

class Rig {
  Rig({VideoCallsConfig? videoCalls}) {
    final store = InMemoryStore()
      ..user = const ChatUser(
        id: 'u1',
        username: 'a',
        token: 'token',
        refreshToken: 'refresh',
        xmppUsername: 'a',
        xmppPassword: 'pass',
      );
    const settings = XmppSettings(
      xmppServerUrl: 'wss://xmpp.test/ws',
      host: 'xmpp.test',
      conference: 'conference.xmpp.test',
    );
    xmpp = FakeXmppClient(settings: settings, user: store.user!, log: (_) {});
    controller = ChatComponentController(
      config: ChatComponentConfig(
        disableRooms: true,
        xmppSettings: settings,
        videoCalls: videoCalls,
      ),
      store: store,
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(
        rooms: const [
          ChatRoom(
            jid: roomJid,
            title: 'Bob',
            type: 'private',
            usersCnt: 2,
            members: [
              ChatRoomMember(xmppUsername: 'a'),
              ChatRoomMember(xmppUsername: 'b', firstName: 'Bob'),
            ],
          ),
        ],
      ),
      xmppClientFactory: ({required settings, required user, required log}) =>
          xmpp,
    );
  }

  late final FakeXmppClient xmpp;
  late final ChatComponentController controller;

  List<ChatMessage> get messages =>
      controller.state.value.messagesByRoom[roomJid] ?? const <ChatMessage>[];
}

ChatMessage callLog({
  required String id,
  required String durationMs,
  String caller = 'a',
}) =>
    ChatMessage(
      id: id,
      roomJid: roomJid,
      text: 'call-state',
      user: const ChatUser(id: 'sys'),
      createdAtMs: 1760000000000,
      system: true,
      data: <String, String>{
        'type': 'call-state',
        'callId': 'c1',
        'durationMs': durationMs,
        'callerXmppUsername': caller,
      },
    );

void main() {
  const quiet = VideoCallsConfig(
    enabled: true,
    livekitUrl: 'wss://lk.example.com',
    nativeCallUi: false,
    ringtone: false,
  );

  test(
      'calls are wired on initialize: stanzas are intercepted and a call '
      'push rings', () async {
    final rig = Rig(videoCalls: quiet);
    await rig.controller.initialize();
    expect(rig.xmpp.messageInterceptors, hasLength(1));
    expect(rig.controller.onCallPush, isNotNull);

    final outcome = await rig.controller.handlePushPayload(<String, dynamic>{
      'type': 'call',
      'callId': 'p1',
      'room': 'a-b',
      'kind': 'video',
      'mode': 'p2p',
      'callerName': 'Bob',
      'callerXmppUsername': 'b',
    });
    expect(outcome, PushPayloadOutcome.call);
    final call = rig.controller.calls.state;
    expect(call.isRingingIncoming, isTrue);
    expect(call.callId, 'p1');
    expect(call.roomJid, roomJid);
    expect(call.roomName, 'Bob');
    rig.controller.calls.declineIncoming();
    expect(rig.controller.calls.state.isIdle, isTrue);
  });

  test('a host onCallPush hook is kept', () async {
    final rig = Rig(videoCalls: quiet);
    var seen = 0;
    rig.controller.onCallPush = (data) {
      seen++;
      return true;
    };
    await rig.controller.initialize();
    await rig.controller.handlePushPayload(<String, dynamic>{
      'type': 'call',
      'callId': 'p1',
      'room': 'a-b',
    });
    expect(seen, 1);
    expect(rig.controller.calls.state.isIdle, isTrue);
  });

  test('with calls off a call push is not a call', () async {
    final rig = Rig();
    await rig.controller.initialize();
    expect(rig.controller.calls.enabled, isFalse);
    expect(
      rig.controller.calls.handleCallPush(<String, dynamic>{
        'type': 'call',
        'callId': 'p1',
        'room': 'a-b',
        'mode': 'p2p',
      }),
      isFalse,
    );
  });

  test(
      'the local call log and the server copy collapse to one entry, the '
      'longer one wins, whichever comes first', () async {
    final rig = Rig(videoCalls: quiet);
    await rig.controller.initialize();

    // Local fallback first, server copy later with the real duration.
    rig.xmpp.onMessage!(callLog(id: 'calllog-c1', durationMs: '0'));
    expect(rig.messages.where((m) => m.data['type'] == 'call-state'),
        hasLength(1));
    rig.xmpp.onMessage!(callLog(id: 'server-1', durationMs: '12000'));
    var logs =
        rig.messages.where((m) => m.data['type'] == 'call-state').toList();
    expect(logs, hasLength(1));
    expect(logs.single.id, 'server-1');
    expect(logs.single.data['durationMs'], '12000');

    // A shorter local copy arriving after the server's changes nothing.
    rig.xmpp.onMessage!(callLog(id: 'calllog-c1', durationMs: '3000'));
    logs = rig.messages.where((m) => m.data['type'] == 'call-state').toList();
    expect(logs, hasLength(1));
    expect(logs.single.id, 'server-1');

    // The same server message re-delivered is still one entry.
    rig.xmpp.onMessage!(callLog(id: 'server-1', durationMs: '12000'));
    expect(
      rig.messages.where((m) => m.data['type'] == 'call-state'),
      hasLength(1),
    );
  });

  test('log entries of different calls stay separate', () async {
    final rig = Rig(videoCalls: quiet);
    await rig.controller.initialize();
    rig.xmpp.onMessage!(callLog(id: 'calllog-c1', durationMs: '0'));
    final other = callLog(id: 'calllog-c2', durationMs: '0');
    rig.xmpp.onMessage!(
      other.copyWith(data: <String, String>{...other.data, 'callId': 'c2'}),
    );
    expect(
      rig.messages.where((m) => m.data['type'] == 'call-state'),
      hasLength(2),
    );
  });
}
