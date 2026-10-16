import 'dart:async';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/networking/stanza_parser.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTransport implements XmppTransport {
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

/// Plays the server side of open, SASL success, restart, bind.
void _autoServer(FakeTransport t) {
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

XmppClient _client(FakeTransport t, List<ChatLogEvent> logs) => XmppClient(
      settings: const XmppSettings(
        xmppServerUrl: 'wss://xmpp.test/ws',
        host: 'xmpp.test',
        conference: 'conference.xmpp.test',
      ),
      user: const ChatUser(xmppUsername: 'me', xmppPassword: 'secret-pass'),
      log: logs.add,
      transportFactory: (_) => t,
    );

void main() {
  test('goes online only after SASL success and bind', () async {
    final t = FakeTransport();
    _autoServer(t);
    final logs = <ChatLogEvent>[];
    final c = _client(t, logs);
    await c.connect();
    expect(c.state, ChatConnectionState.online);
    expect(c.boundJid, 'me@xmpp.test/flutter');
    expect(t.sent.where((f) => f.startsWith('<open')).length, 2);
    // the SASL payload must never reach the logs
    expect(logs.any((l) => l.message.contains('c2VjcmV0')), false);
  });

  test('SASL failure reports auth error', () async {
    final t = FakeTransport();
    t.onSend = (frame) {
      if (frame.startsWith('<open')) {
        scheduleMicrotask(() => t.push(
              '<stream:features xmlns:stream="http://etherx.jabber.org/streams"><mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl"/></stream:features>',
            ));
      } else if (frame.startsWith('<auth')) {
        scheduleMicrotask(() => t.push(
              '<failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><not-authorized/></failure>',
            ));
      }
    };
    final c = _client(t, <ChatLogEvent>[]);
    XmppAuthException? error;
    c.onAuthFailed = (e) => error = e;
    await c.connect();
    expect(error?.condition, 'not-authorized');
    expect(c.state, ChatConnectionState.error);
  });

  test('MAM page: rows counted, fin parsed', () async {
    final t = FakeTransport();
    _autoServer(t);
    final c = _client(t, <ChatLogEvent>[]);
    await c.connect();
    final received = <ChatMessage>[];
    c.onMessage = received.add;
    t.onSend = (frame) {
      if (!frame.contains('urn:xmpp:mam:2')) return;
      final id = RegExp(r'id="([^"]+)"').firstMatch(frame)!.group(1);
      expect(frame, contains('<before>1712000000000100</before>'));
      scheduleMicrotask(() {
        t.push(
            '<message><result xmlns="urn:xmpp:mam:2" queryid="$id" id="1712000000000050"><forwarded xmlns="urn:xmpp:forward:0"><message from="r@conference.xmpp.test/a" id="m"><body>x</body></message></forwarded></result></message>');
        t.push(
            '<iq type="result" id="$id"><fin xmlns="urn:xmpp:mam:2" complete="true"><set xmlns="http://jabber.org/protocol/rsm"><first>1712000000000050</first><last>1712000000000050</last></set></fin></iq>');
      });
    };
    final page = await c.requestHistory(
      roomJid: 'r@conference.xmpp.test',
      beforeId: '1712000000000100',
    );
    expect(page.complete, true);
    expect(page.count, 1);
    expect(page.first, '1712000000000050');
    expect(received.single.id, '1712000000000050');
  });

  test('MAM error answer is an empty page', () async {
    final t = FakeTransport();
    _autoServer(t);
    final c = _client(t, <ChatLogEvent>[]);
    await c.connect();
    t.onSend = (frame) {
      if (!frame.contains('urn:xmpp:mam:2')) return;
      final id = RegExp(r'id="([^"]+)"').firstMatch(frame)!.group(1);
      scheduleMicrotask(() => t.push('<iq type="error" id="$id"/>'));
    };
    final page = await c.requestHistory(roomJid: 'r@conference.xmpp.test');
    expect(page.error, true);
    expect(page.count, 0);
  });

  test('private store get parses chatjson', () async {
    final t = FakeTransport();
    _autoServer(t);
    final c = _client(t, <ChatLogEvent>[]);
    await c.connect();
    t.onSend = (frame) {
      if (!frame.contains('chatjson')) return;
      final id = RegExp(r'id="([^"]+)"').firstMatch(frame)!.group(1);
      scheduleMicrotask(() => t.push(
            '<iq type="result" id="$id"><query xmlns="jabber:iq:private"><chatjson xmlns="chatjson:store" value="{&quot;r@conference.xmpp.test&quot;:&quot;1712000000000&quot;}"/></query></iq>',
          ));
    };
    final map = await c.getChatsPrivateStore();
    expect(map['r@conference.xmpp.test'], 1712000000000);
  });

  test('text stanza matches web shape and escapes attributes', () async {
    final t = FakeTransport();
    _autoServer(t);
    final c = _client(t, <ChatLogEvent>[]);
    await c.connect();
    await c.sendText(
      roomJid: 'r@conference.xmpp.test',
      messageId: 'send-text-message-1',
      text: 'a "quoted" <b>',
    );
    final frame = t.sent.last;
    expect(frame, contains('id="send-text-message-1"'));
    expect(frame, contains('userMessage="a &quot;quoted&quot; &lt;b&gt;"'));
    expect(frame, contains('<translate source="en"/>'));
    expect(frame, contains('push="true"'));
  });

  test('parsePrivateStoreValue tolerates junk', () {
    expect(parsePrivateStoreValue('not json'), isEmpty);
    expect(parsePrivateStoreValue('{"a":"x","b":"1712000000000"}'),
        {'b': 1712000000000});
    expect(localPart('a@b/c'), 'a');
  });
}
