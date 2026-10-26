import 'dart:async';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/networking/stanza_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _room = 'r@conference.xmpp.test';

class _Transport implements XmppTransport {
  final StreamController<String> _in = StreamController<String>.broadcast();
  final List<String> sent = <String>[];
  void Function(String frame)? onSend;

  @override
  Stream<String> get incoming => _in.stream;

  @override
  void send(String frame) {
    sent.add(frame);
    onSend?.call(frame);
  }

  void push(String frame) => _in.add(frame);

  @override
  Future<void> close() async {}
}

void _autoServer(_Transport t) {
  var opens = 0;
  t.onSend = (frame) {
    if (frame.startsWith('<open')) {
      opens += 1;
      scheduleMicrotask(() {
        t.push(
            '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" from="xmpp.test" version="1.0"/>');
        t.push(opens == 1
            ? '<stream:features xmlns:stream="http://etherx.jabber.org/streams"><mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><mechanism>PLAIN</mechanism></mechanisms></stream:features>'
            : '<stream:features xmlns:stream="http://etherx.jabber.org/streams"><bind xmlns="urn:ietf:params:xml:ns:xmpp-bind"/></stream:features>');
      });
    } else if (frame.startsWith('<auth')) {
      scheduleMicrotask(
          () => t.push('<success xmlns="urn:ietf:params:xml:ns:xmpp-sasl"/>'));
    } else if (frame.contains('xmpp-bind')) {
      final id = RegExp(r'id="([^"]+)"').firstMatch(frame)!.group(1);
      scheduleMicrotask(() => t.push(
            '<iq type="result" id="$id"><bind xmlns="urn:ietf:params:xml:ns:xmpp-bind"><jid>me@xmpp.test/flutter</jid></bind></iq>',
          ));
    }
  };
}

Future<XmppClient> _online(_Transport t) async {
  _autoServer(t);
  final c = XmppClient(
    settings: const XmppSettings(
      xmppServerUrl: 'wss://xmpp.test/ws',
      host: 'xmpp.test',
      conference: 'conference.xmpp.test',
    ),
    user: const ChatUser(xmppUsername: 'me', xmppPassword: 'pw'),
    log: (_) {},
    transportFactory: (_) => t,
  );
  await c.connect();
  return c;
}

String _row(String queryId, String archiveId, String body) =>
    '<message><result xmlns="urn:xmpp:mam:2" queryid="$queryId" id="$archiveId">'
    '<forwarded xmlns="urn:xmpp:forward:0"><delay xmlns="urn:xmpp:delay" stamp="2026-01-01T00:00:00Z"/>'
    '<message from="$_room/bob" id="m$archiveId" type="groupchat"><body>$body</body></message>'
    '</forwarded></result></message>';

String _fin(String id,
        {String complete = 'false', String? first, String? last}) =>
    '<iq type="result" id="$id"><fin xmlns="urn:xmpp:mam:2" complete="$complete">'
    '<set xmlns="http://jabber.org/protocol/rsm">'
    '${first == null ? '' : '<first>$first</first>'}'
    '${last == null ? '' : '<last>$last</last>'}</set></fin></iq>';

String _idOf(String frame) =>
    RegExp(r'id="([^"]+)"').firstMatch(frame)!.group(1)!;

void main() {
  test('query shapes: latest, before, after, time range', () async {
    final t = _Transport();
    final c = await _online(t);
    final queries = <String>[];
    t.onSend = (frame) {
      if (!frame.contains('urn:xmpp:mam:2')) return;
      queries.add(frame);
      final id = _idOf(frame);
      scheduleMicrotask(() => t.push(_fin(id, complete: 'true')));
    };
    await c.requestHistory(roomJid: _room, max: 30);
    await c.requestHistory(
        roomJid: _room, max: 30, beforeId: '1700000000000010');
    await c.requestHistory(
        roomJid: _room, max: 11, afterId: '1700000000000009');
    await c.requestHistory(
      roomJid: _room,
      max: 50,
      start: '2026-01-01T00:00:00.000Z',
      end: '2026-01-01T00:00:10.000Z',
    );
    await c.requestHistory(
      roomJid: _room,
      max: 50,
      afterId: '1700000000000099',
      start: '2026-01-01T00:00:00.000Z',
      end: '2026-01-01T00:00:10.000Z',
    );
    expect(queries[0], contains('<max>30</max><before/>'));
    expect(queries[1], contains('<before>1700000000000010</before>'));
    expect(
        queries[2], contains('<max>11</max><after>1700000000000009</after>'));
    expect(
        queries[3],
        contains(
            '<field var="start"><value>2026-01-01T00:00:00.000Z</value></field>'));
    expect(queries[3], contains('<field var="end">'));
    expect(queries[3], isNot(contains('<before')));
    expect(queries[3], isNot(contains('<after')));
    expect(queries[4], contains('<after>1700000000000099</after>'));
    expect(queries[4], contains('urn:xmpp:mam:2'));
  });

  test('fin first and last are read, blank ones are null', () async {
    final t = _Transport();
    final c = await _online(t);
    t.onSend = (frame) {
      if (!frame.contains('urn:xmpp:mam:2')) return;
      final id = _idOf(frame);
      scheduleMicrotask(
          () => t.push(_fin(id, first: ' 1700000000000001 ', last: '')));
    };
    final page = await c.requestHistory(roomJid: _room);
    expect(page.first, '1700000000000001');
    expect(page.last, isNull);
    expect(page.complete, false);
    expect(page.error, false);
  });

  test('a silent page keeps rows and modifiers away from the live callbacks',
      () async {
    final t = _Transport();
    final c = await _online(t);
    final live = <ChatMessage>[];
    var edits = 0, deletes = 0, reactions = 0;
    c.onMessage = live.add;
    c.onEdit = (_) => edits += 1;
    c.onDelete = (_) => deletes += 1;
    c.onReaction = (_) => reactions += 1;
    t.onSend = (frame) {
      if (!frame.contains('urn:xmpp:mam:2')) return;
      final id = _idOf(frame);
      scheduleMicrotask(() {
        t.push(_row(id, '1700000000000001', 'first'));
        t.push(_row(id, '1700000000000002', 'second'));
        t.push(
            '<message><result xmlns="urn:xmpp:mam:2" queryid="$id" id="1700000000000003"><forwarded xmlns="urn:xmpp:forward:0">'
            '<message from="$_room/bob" type="groupchat" id="edit-message-1"><body>x</body>'
            '<replace id="1700000000000001" text="edited" xmlns="urn:xmpp:message-correct:0"/></message>'
            '</forwarded></result></message>');
        t.push(_fin(id, first: '1700000000000001', last: '1700000000000003'));
      });
    };
    final page = await c.requestHistory(roomJid: _room, deliver: false);
    expect(page.messages.map((m) => m.text), ['first', 'second']);
    expect(live, isEmpty);
    expect(edits + deletes + reactions, 0);
    expect(page.first, '1700000000000001');
    expect(page.last, '1700000000000003');
    expect(page.modifiers, hasLength(1));
    final edit = page.modifiers.single as ParsedEdit;
    expect(edit.targetId, '1700000000000001');
    expect(edit.text, 'edited');
  });

  test('a delivering page hands the rows to the live callback', () async {
    final t = _Transport();
    final c = await _online(t);
    final live = <ChatMessage>[];
    c.onMessage = live.add;
    t.onSend = (frame) {
      if (!frame.contains('urn:xmpp:mam:2')) return;
      final id = _idOf(frame);
      scheduleMicrotask(() {
        t.push(_row(id, '1700000000000001', 'one'));
        t.push(_fin(id,
            complete: 'true',
            first: '1700000000000001',
            last: '1700000000000001'));
      });
    };
    final page = await c.requestHistory(roomJid: _room);
    expect(live.map((m) => m.id), ['1700000000000001']);
    expect(page.messages, hasLength(1));
    expect(page.complete, true);
  });

  testWidgets('late rows of a timed-out silent query never reach the live list',
      (tester) async {
    final t = _Transport();
    final c = await _online(t);
    final live = <ChatMessage>[];
    c.onMessage = live.add;
    String? queryId;
    t.onSend = (frame) {
      if (frame.contains('urn:xmpp:mam:2')) queryId = _idOf(frame);
    };
    MamPage? page;
    final silent = c.requestHistory(roomJid: _room, deliver: false)
      ..then((p) => page = p);
    await tester.pump(const Duration(seconds: 11));
    await silent;
    expect(page?.timedOut, true);

    // the server answers after the client gave up
    t.push(_row(queryId!, '1700000000000001', 'late'));
    await tester.pump();
    expect(live, isEmpty);

    // a delivering query that times out keeps its late rows
    final delivering = c.requestHistory(roomJid: _room);
    await tester.pump(const Duration(seconds: 11));
    await delivering;
    t.push(_row(queryId!, '1700000000000002', 'late live'));
    await tester.pump();
    expect(live.map((m) => m.text), ['late live']);

    // the silent tombstone expires
    await tester.pump(const Duration(seconds: 20));
    unawaited(c.disconnect());
    await tester.pump();
  });

  test('an IQ error is an error page with no rows', () async {
    final t = _Transport();
    final c = await _online(t);
    t.onSend = (frame) {
      if (!frame.contains('urn:xmpp:mam:2')) return;
      final id = _idOf(frame);
      scheduleMicrotask(() => t.push(
          '<iq type="error" id="$id"><error type="cancel"><item-not-found xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error></iq>'));
    };
    final page =
        await c.requestHistory(roomJid: _room, beforeId: '1700000000000010');
    expect(page.error, true);
    expect(page.messages, isEmpty);
    expect(page.first, isNull);
    expect(page.complete, false);
  });

  test('requestHistory while offline is an error page, not a throw', () async {
    final c = XmppClient(
      settings: const XmppSettings(
        xmppServerUrl: 'wss://xmpp.test/ws',
        host: 'xmpp.test',
        conference: 'conference.xmpp.test',
      ),
      user: const ChatUser(xmppUsername: 'me', xmppPassword: 'pw'),
      log: (_) {},
      transportFactory: (_) => _Transport(),
    );
    final page = await c.requestHistory(roomJid: _room);
    expect(page.error, true);
  });
}
