import 'dart:async';
import 'dart:convert';

import 'package:ethora_sdk_flutter/src/push/push_storage.dart';
import 'package:ethora_sdk_flutter/src/push/push_subscription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  late MemoryPushStorage storage;
  late PushSubscriptionService service;
  late List<String> sent;

  XmlElement ok() => XmlElement(XmlName('iq'));

  setUp(() {
    storage = MemoryPushStorage();
    sent = <String>[];
    service = PushSubscriptionService(
      storage: storage,
      timeout: const Duration(milliseconds: 50),
    );
  });

  test('the subscribe IQ is the MucSub messages node', () {
    final xml = XmlDocument.parse(buildMucSubscribeStanza(
      id: 'newSubscription:abc-1',
      roomJid: 'room@conference.example.test',
      nick: 'alice',
    )).rootElement;
    expect(xml.getAttribute('to'), 'room@conference.example.test');
    expect(xml.getAttribute('type'), 'set');
    expect(xml.getAttribute('id'), 'newSubscription:abc-1');
    final subscribe = xml.getElement('subscribe')!;
    expect(subscribe.getAttribute('xmlns'), 'urn:xmpp:mucsub:0');
    expect(subscribe.getAttribute('nick'), 'alice');
    expect(
      subscribe.getElement('event')!.getAttribute('node'),
      'urn:xmpp:mucsub:nodes:messages',
    );
  });

  test('subscribing remembers the room and does not repeat', () async {
    Future<XmlElement> send(String id, String stanza,
        {Duration? timeout}) async {
      sent.add(stanza);
      return ok();
    }

    expect(await service.subscribeToRoom(send, 'a@c.test/res', nick: 'alice'),
        isTrue);
    expect(
        await service.subscribeToRoom(send, 'a@c.test', nick: 'alice'), isTrue);
    expect(sent, hasLength(1));
    expect(service.isRoomSubscribed('a@c.test'), isTrue);
    expect(
      jsonDecode(storage.values[kSubscribedRoomsKey]!),
      <String>['a@c.test'],
    );

    // A new service (app restart) reads the remembered rooms.
    final again = PushSubscriptionService(storage: storage);
    await again.subscribeToRoom(send, 'a@c.test', nick: 'alice');
    expect(sent, hasLength(1));
  });

  test('an IQ error or a timeout is false and not remembered', () async {
    Future<XmlElement> fail(String id, String stanza, {Duration? timeout}) =>
        Future<XmlElement>.error(StateError('iq_error:$id'));
    expect(await service.subscribeToRoom(fail, 'a@c.test', nick: 'n'), isFalse);

    Future<XmlElement> hang(String id, String stanza, {Duration? timeout}) =>
        Completer<XmlElement>().future.timeout(
              timeout ?? const Duration(seconds: 5),
            );
    expect(await service.subscribeToRoom(hang, 'b@c.test', nick: 'n'), isFalse);
    expect(service.subscribedRooms, isEmpty);
  });

  test('a jid without a domain is skipped', () async {
    Future<XmlElement> send(String id, String stanza,
        {Duration? timeout}) async {
      sent.add(stanza);
      return ok();
    }

    expect(await service.subscribeToRoom(send, 'nodomain', nick: 'n'), isFalse);
    expect(sent, isEmpty);
  });

  test('rooms go in batches of 8 and only the missing ones', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    Future<XmlElement> send(String id, String stanza,
        {Duration? timeout}) async {
      inFlight += 1;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      sent.add(stanza);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      inFlight -= 1;
      return ok();
    }

    final rooms = <String>[for (var i = 0; i < 20; i++) 'r$i@c.test'];
    await service.subscribeToRoom(send, rooms.first, nick: 'n');
    sent.clear();
    final done = await service.subscribeToRooms(send, rooms, nick: 'n');
    expect(done, 19);
    expect(sent, hasLength(19));
    expect(maxInFlight, 8);
  });

  test('reset forgets everything, memory and storage', () async {
    Future<XmlElement> send(String id, String stanza,
            {Duration? timeout}) async =>
        ok();
    await service.subscribeToRoom(send, 'a@c.test', nick: 'n');
    await service.reset();
    expect(service.isRoomSubscribed('a@c.test'), isFalse);
    expect(storage.values.containsKey(kSubscribedRoomsKey), isFalse);
  });

  test('a failed room waits out the cooldown before it is tried again',
      () async {
    var clock = DateTime(2026, 10, 21, 12);
    final cooled = PushSubscriptionService(
      storage: storage,
      now: () => clock,
    );
    var attempts = 0;
    Future<XmlElement> flaky(String id, String stanza, {Duration? timeout}) {
      attempts += 1;
      return attempts == 1
          ? Future<XmlElement>.error(StateError('iq_error'))
          : Future<XmlElement>.value(ok());
    }

    expect(await cooled.subscribeToRoom(flaky, 'a@c.test', nick: 'n'), isFalse);
    clock = clock.add(const Duration(seconds: 30));
    expect(await cooled.subscribeToRoom(flaky, 'a@c.test', nick: 'n'), isFalse);
    expect(attempts, 1);
    clock = clock.add(const Duration(seconds: 31));
    expect(await cooled.subscribeToRoom(flaky, 'a@c.test', nick: 'n'), isTrue);
    expect(attempts, 2);
  });
}
