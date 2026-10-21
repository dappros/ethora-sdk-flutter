import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/push/chat_push_coordinator.dart';
import 'package:ethora_sdk_flutter/src/push/push_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support_auth.dart';

void main() {
  group('payload helpers', () {
    test('call pushes are recognised by type or pushType', () {
      for (final type in <String>[
        'call',
        'incoming-call',
        'call-token',
        'call-invite',
      ]) {
        expect(isCallPush(<String, dynamic>{'type': type}), isTrue);
        expect(isCallPush(<String, dynamic>{'pushType': type.toUpperCase()}),
            isTrue);
      }
      expect(isCallPush(<String, dynamic>{'type': 'message'}), isFalse);
      expect(isCallPush(<String, dynamic>{}), isFalse);
    });

    test('the room is the first of jid, chatJid, roomJid, roomJID', () {
      expect(
          pushRoomJid(<String, dynamic>{'roomJID': 'c', 'chatJid': 'b'}), 'b');
      expect(pushRoomJid(<String, dynamic>{'jid': 'a', 'roomJid': 'c'}), 'a');
      expect(pushRoomJid(<String, dynamic>{'jid': '  '}), isNull);
      expect(pushRoomJid(<String, dynamic>{'jid': 5}), isNull);
    });

    test('room jids are made bare and given the conference domain', () {
      expect(
          normalizePushRoomJid('r@conf.test/nick', 'conf.test'), 'r@conf.test');
      expect(normalizePushRoomJid('r', 'conf.test'), 'r@conf.test');
      expect(normalizePushRoomJid('r', null), 'r');
    });

    test('a pending jid expires after five minutes', () {
      final at = DateTime(2026, 10, 21, 12);
      final raw = encodePendingJid('r@conf.test', at);
      expect(decodePendingJid(raw, at.add(const Duration(minutes: 4))),
          'r@conf.test');
      expect(decodePendingJid(raw, at.add(const Duration(minutes: 6))), isNull);
      expect(decodePendingJid(null, at), isNull);
      expect(decodePendingJid('garbage{', at), 'garbage{');
      expect(decodePendingJid('{broken', at), isNull);
      // The old plain-string format has no timestamp and is kept.
      expect(decodePendingJid('plain@conf.test', at), 'plain@conf.test');
    });
  });

  group('handlePushPayload', () {
    late ValueNotifier<ChatComponentState> state;
    late MemoryPushStorage storage;
    late List<String> selected;
    late DateTime now;
    late ChatPushCoordinator coordinator;

    setUp(() {
      state = ValueNotifier<ChatComponentState>(const ChatComponentState());
      storage = MemoryPushStorage();
      selected = <String>[];
      now = DateTime(2026, 10, 21, 12);
      final api = buildApiClient(
        store: FakeTokenStore(),
        handler: (_) async => json(200, <String, Object?>{}),
      );
      coordinator = ChatPushCoordinator(
        config: const ChatComponentConfig(
          xmppSettings:
              XmppSettings(host: 'xmpp.test', conference: 'conf.test'),
          pushNotifications: PushNotificationsConfig(),
        ),
        apiClient: api,
        state: state,
        xmpp: () => null,
        selectRoom: (jid) async => selected.add(jid),
        storage: storage,
        now: () => now,
      );
    });

    test('a loaded room opens at once', () async {
      state.value = ChatComponentState(
        rooms: const <ChatRoom>[ChatRoom(jid: 'Room1@conf.test')],
      );
      final outcome = await coordinator.handlePushPayload(
        <String, dynamic>{'jid': 'room1@conf.test/alice'},
      );
      expect(outcome, PushPayloadOutcome.room);
      expect(selected, <String>['Room1@conf.test']);
      expect(storage.values.containsKey(kPendingNotificationJidKey), isFalse);
    });

    test('an unknown room stays pending, then opens when it loads', () async {
      await coordinator.onRuntimeReady();
      final outcome = await coordinator
          .handlePushPayload(<String, dynamic>{'chatJid': 'room2'});
      expect(outcome, PushPayloadOutcome.pending);
      expect(selected, isEmpty);
      expect(storage.values.containsKey(kPendingNotificationJidKey), isTrue);

      state.value = ChatComponentState(
        rooms: const <ChatRoom>[ChatRoom(jid: 'room2@conf.test')],
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(selected, <String>['room2@conf.test']);
      expect(storage.values.containsKey(kPendingNotificationJidKey), isFalse);
      coordinator.dispose();
    });

    test('a cold-start tap is picked up from storage after the rooms load',
        () async {
      storage.values[kPendingNotificationJidKey] =
          encodePendingJid('room3@conf.test', now);
      state.value = ChatComponentState(
        rooms: const <ChatRoom>[ChatRoom(jid: 'room3@conf.test')],
      );
      await coordinator.onRuntimeReady();
      expect(selected, <String>['room3@conf.test']);
      coordinator.dispose();
    });

    test('an expired pending room is dropped', () async {
      storage.values[kPendingNotificationJidKey] = encodePendingJid(
        'room4@conf.test',
        now.subtract(const Duration(minutes: 10)),
      );
      state.value = ChatComponentState(
        rooms: const <ChatRoom>[ChatRoom(jid: 'room4@conf.test')],
      );
      await coordinator.onRuntimeReady();
      expect(selected, isEmpty);
      coordinator.dispose();
    });

    test('call pushes go to onCallPush; unhandled ones fall back to the room',
        () async {
      final seen = <Map<String, dynamic>>[];
      coordinator.onCallPush = (data) {
        seen.add(data);
        return true;
      };
      expect(
        await coordinator.handlePushPayload(<String, dynamic>{
          'type': 'call',
          'jid': 'room5@conf.test',
        }),
        PushPayloadOutcome.call,
      );
      expect(seen, hasLength(1));
      expect(selected, isEmpty);

      coordinator.onCallPush = (_) => false;
      expect(
        await coordinator.handlePushPayload(<String, dynamic>{
          'type': 'call',
          'jid': 'room5@conf.test',
        }),
        PushPayloadOutcome.pending,
      );
    });

    test('payloads without a room are unknown', () async {
      expect(await coordinator.handlePushPayload(<String, dynamic>{}),
          PushPayloadOutcome.unknown);
      expect(await coordinator.handlePushPayload(<String, dynamic>{'x': 1}),
          PushPayloadOutcome.unknown);
    });
  });
}
