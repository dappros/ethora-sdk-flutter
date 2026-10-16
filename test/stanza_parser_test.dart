import 'package:ethora_sdk_flutter/src/networking/stanza_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

XmlElement _el(String xml) => XmlDocument.parse(xml).rootElement;

void main() {
  const room = 'room@conference.xmpp.test';

  test('live text: archive id from stanza-id, xmppId from outer id', () {
    final parsed = parseMessageStanza(_el(
      '<message from="$room/alice" type="groupchat" id="send-text-message-1">'
      '<data senderFirstName="Alice" senderLastName="Lee" isReply="false" showInChannel="false"/>'
      '<body>hi</body>'
      '<stanza-id xmlns="urn:xmpp:sid:0" by="$room" id="1712000000000123"/>'
      '</message>',
    ));
    expect(parsed, isA<ParsedChatMessage>());
    final m = (parsed! as ParsedChatMessage).message;
    expect(m.id, '1712000000000123');
    expect(m.xmppId, 'send-text-message-1');
    expect(m.text, 'hi');
    expect(m.user.xmppUsername, 'alice');
    expect(m.user.firstName, 'Alice');
    expect(m.createdAtMs, 1712000000000);
    expect(m.showInChannel, true);
  });

  test('MAM result: id from result, timestamp from delay, queryid kept', () {
    final parsed = parseMessageStanza(_el(
      '<message to="me@xmpp.test"><result xmlns="urn:xmpp:mam:2" queryid="get-history:1:1" id="1712000000000555">'
      '<forwarded xmlns="urn:xmpp:forward:0"><delay xmlns="urn:xmpp:delay" stamp="2024-04-01T10:00:00.000Z"/>'
      '<message from="$room/bob" type="groupchat" id="x1"><body>old</body></message>'
      '</forwarded></result></message>',
    )) as ParsedChatMessage;
    expect(parsed.queryId, 'get-history:1:1');
    expect(parsed.message.id, '1712000000000555');
    expect(parsed.message.isHistory, true);
    expect(
      parsed.message.createdAtMs,
      DateTime.parse('2024-04-01T10:00:00.000Z').millisecondsSinceEpoch,
    );
  });

  test('media with attachments JSON', () {
    final m = (parseMessageStanza(_el(
      '<message from="$room/bob" type="groupchat" id="send-media-message-1"><body>media</body>'
      '<data isMediafile="true" location="https://f/a.png" mimetype="image/png" '
      'attachments="[{&quot;location&quot;:&quot;https://f/a.png&quot;,&quot;mimetype&quot;:&quot;image/png&quot;},{&quot;location&quot;:&quot;https://f/b.pdf&quot;,&quot;mimetype&quot;:&quot;application/pdf&quot;}]"/>'
      '</message>',
    )) as ParsedChatMessage)
        .message;
    expect(m.isMedia, true);
    expect(m.mediaUrl, 'https://f/a.png');
    expect(m.attachments.length, 2);
    expect(m.attachments[1]['mimetype'], 'application/pdf');
  });

  test('thread reply flags', () {
    final m = (parseMessageStanza(_el(
      '<message from="$room/bob" type="groupchat" id="x"><body>r</body>'
      '<data isReply="true" showInChannel="false" mainMessage="{&quot;id&quot;:&quot;1&quot;}"/></message>',
    )) as ParsedChatMessage)
        .message;
    expect(m.isReply, true);
    expect(m.showInChannel, false);
    expect(m.mainMessage, '{"id":"1"}');
  });

  test('system message flag', () {
    final m = (parseMessageStanza(_el(
      '<message from="$room/server" type="groupchat" id="x"><body>Missed call</body>'
      '<data type="call-state" isSystemMessage="true"/></message>',
    )) as ParsedChatMessage)
        .message;
    expect(m.system, true);
  });

  test('call signalling is swallowed', () {
    expect(
      parseMessageStanza(_el(
        '<message from="$room/x" type="groupchat"><data type="call-token" token="t"/></message>',
      )),
      isNull,
    );
  });

  test('edit, delete, reaction shapes', () {
    final edit = parseMessageStanza(_el(
      '<message from="$room/a" type="groupchat" id="edit-message-1"><replace id="111" text="new"/></message>',
    ));
    expect(edit, isA<ParsedEdit>());
    expect((edit! as ParsedEdit).text, 'new');

    final del = parseMessageStanza(_el(
      '<message from="$room/a" type="groupchat" id="deleteMessageStanza"><stanza-id xmlns="urn:xmpp:sid:0" by="$room" id="2"/><delete id="111"/></message>',
    )) as ParsedDelete;
    expect(del.targetId, '111');
    expect(del.roomJid, room);

    final reaction = parseMessageStanza(_el(
      '<message from="$room/a" type="groupchat" id="message-reaction:1">'
      '<reactions id="111" from="alice@xmpp.test/res" xmlns="urn:xmpp:reactions:0"><reaction>heart</reaction><reaction>+1</reaction></reactions>'
      '<stanza-id xmlns="urn:xmpp:sid:0" by="$room" id="1712000000000999"/></message>',
    )) as ParsedReaction;
    expect(reaction.reactor, 'alice');
    expect(reaction.reaction.emoji, <String>['heart', '+1']);
  });

  test('typing composing and paused', () {
    final t = parseMessageStanza(_el(
      '<message from="$room/alice" type="groupchat" id="typing-1"><composing xmlns="http://jabber.org/protocol/chatstates"/><data fullName="Alice Lee"/></message>',
    )) as ParsedTyping;
    expect(t.composing, true);
    expect(t.fullName, 'Alice Lee');
    final p = parseMessageStanza(_el(
      '<message from="$room/alice" type="groupchat" id="stop-typing-1"><paused xmlns="http://jabber.org/protocol/chatstates"/></message>',
    )) as ParsedTyping;
    expect(p.composing, false);
  });

  test('MUC-SUB wrapped message is unwrapped', () {
    final m = parseMessageStanza(_el(
      '<message from="$room"><event xmlns="http://jabber.org/protocol/pubsub#event"><items node="urn:xmpp:mucsub:nodes:messages">'
      '<item id="1"><message from="$room/bob" type="groupchat" id="z"><body>wrapped</body></message></item></items></event></message>',
    )) as ParsedChatMessage;
    expect(m.message.text, 'wrapped');
  });

  test('timestampFromUnknown handles micro, ms, seconds, ISO', () {
    expect(timestampFromUnknown('1712000000000123'), 1712000000000);
    expect(timestampFromUnknown('1712000000000'), 1712000000000);
    expect(timestampFromUnknown('1712000000'), 1712000000000);
    expect(timestampFromUnknown('send-text-message-1712000000000-ab'),
        1712000000000);
  });
}
