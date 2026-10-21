import 'dart:convert';

import 'package:ethora_sdk_flutter/src/calls/call_display.dart';
import 'package:ethora_sdk_flutter/src/calls/call_mode.dart';
import 'package:ethora_sdk_flutter/src/calls/call_sender_trust.dart';
import 'package:ethora_sdk_flutter/src/calls/call_stanza.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

XmlElement parse(String xml) => XmlDocument.parse(xml).rootElement;

String jwt(Map<String, Object?> payload) {
  String enc(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${enc(<String, Object>{'alg': 'HS256'})}.${enc(payload)}.sig';
}

const String hex24 = '0123456789abcdef01234567';
const String system = '${hex24}_$hex24';

void main() {
  group('parseCallTokenAttrs', () {
    test('a legacy stanza (no mode, no group) is a plain 1:1 livekit call', () {
      final a = parseCallTokenAttrs(<String, String>{
        'token': ' jwt ',
        'room': 'room1',
        'callId': 'c1',
      });
      expect(a.mode, CallMode.livekit);
      expect(a.group, isFalse);
      expect(a.token, 'jwt');
      expect(a.room, 'room1');
      expect(a.callId, 'c1');
      expect(a.kind, isNull);
      expect(a.livekitUrl, isNull);
      expect(a.iceServers, isNull);
    });

    test('reads mode, kind, group, livekitUrl, callerName and caller', () {
      final a = parseCallTokenAttrs(<String, String>{
        'token': 't',
        'room': 'r',
        'mode': 'LIVEKIT',
        'kind': 'Audio',
        'group': 'true',
        'livekitUrl': 'wss://lk.example.com',
        'callerName': '  Ann   Lee ',
        'caller': 'abc_def',
        'callid': 'x9',
      });
      expect(a.mode, CallMode.livekit);
      expect(a.kind, CallKind.audio);
      expect(a.group, isTrue);
      expect(a.livekitUrl, 'wss://lk.example.com');
      expect(a.callerName, 'Ann Lee');
      expect(a.caller, 'abc_def');
      expect(a.callId, 'x9');
    });

    test('mode p2p carries ice servers and no token, and is never a group', () {
      final a = parseCallTokenAttrs(<String, String>{
        'room': 'r',
        'mode': 'p2p',
        'group': 'true',
        'callId': 'p1',
        'livekitUrl': 'wss://lk.example.com',
        'ice': jsonEncode(<Object>[
          <String, Object>{
            'urls': <String>['stun:s.example.com:3478'],
          },
          <String, Object>{
            'urls': 'turn:t.example.com:3478',
            'username': 'u',
            'credential': 'p',
          },
          <String, Object>{'urls': 'http://not-ice'},
          'garbage',
        ]),
      });
      expect(a.mode, CallMode.p2p);
      expect(a.group, isFalse);
      expect(a.token, isEmpty);
      expect(a.livekitUrl, isNull, reason: 'livekitUrl is livekit-only');
      expect(a.iceServers, hasLength(2));
      expect(a.iceServers![1].urls, <String>['turn:t.example.com:3478']);
      expect(a.iceServers![1].username, 'u');
      expect(a.iceServers![1].credential, 'p');
    });

    test('unknown or malformed attributes fall back to legacy livekit', () {
      for (final mode in <String>['', 'weird', 'p2p2', 'null']) {
        final a = parseCallTokenAttrs(<String, String>{
          'mode': mode,
          'token': 't',
          'ice': '{not json',
          'group': 'maybe',
          'kind': 'hologram',
          'livekitUrl': 'javascript:alert(1)',
          'callerName':
              '${String.fromCharCode(0x202E)}evil${String.fromCharCode(7)}',
          'caller': 'has space',
        });
        expect(a.mode, CallMode.livekit, reason: 'mode "$mode"');
        expect(a.group, isFalse);
        expect(a.kind, isNull);
        expect(a.livekitUrl, isNull);
        expect(a.iceServers, isNull);
        expect(a.callerName, 'evil');
        expect(a.caller, isNull);
      }
      // p2p with an unparseable ice list is still p2p (ice is fetched by REST).
      final p2p = parseCallTokenAttrs(<String, String>{
        'mode': 'p2p',
        'ice': '{not json',
        'callId': 'c',
        'room': 'r',
      });
      expect(p2p.mode, CallMode.p2p);
      expect(p2p.iceServers, isNull);
      expect(parseCallTokenAttrs(null).token, isEmpty);
    });

    test('a raw chat name is never accepted as callerName', () {
      final raw = '${hex24}_$hex24-${hex24}_fedcba9876543210fedcba98';
      expect(sanitizeCallName(raw), isEmpty);
      expect(sanitizeCallName('Ann'), 'Ann');
      expect(looksLikeRawRoomName('${hex24}_$hex24'), isTrue);
      expect(looksLikeRawRoomName('Ann Lee'), isFalse);
    });
  });

  group('normalizeIceServers', () {
    test('accepts an envelope, a json string and url/urls', () {
      expect(
        normalizeIceServers(<String, Object>{
          'iceServers': <Object>[
            <String, Object>{'url': 'STUN:a.example.com'},
          ],
        }),
        hasLength(1),
      );
      expect(normalizeIceServers(''), isEmpty);
      expect(normalizeIceServers(null), isEmpty);
      expect(normalizeIceServers(42), isEmpty);
      final list = normalizeIceServers(
        '[{"urls":["turns:t.example.com:443","bad:x"],"username":"","credential":"c"}]',
      );
      expect(list.single.urls, <String>['turns:t.example.com:443']);
      expect(list.single.username, isNull);
      expect(list.single.toMap()['urls'], 'turns:t.example.com:443');
    });
  });

  group('parseCallCreateResponse', () {
    test('an old server (no mode) is livekit with the fallback kind', () {
      final r = parseCallCreateResponse(
        <String, Object>{'ok': true, 'callId': 'c1'},
        CallKind.audio,
      );
      expect(r.mode, CallMode.livekit);
      expect(r.kind, CallKind.audio);
      expect(r.callId, 'c1');
      expect(r.group, isNull);
    });

    test('p2p response: ice servers, ttl and callId', () {
      final r = parseCallCreateResponse(
        <String, Object>{
          'ok': true,
          'callId': 'c2',
          'mode': 'p2p',
          'kind': 'video',
          'ttlSeconds': 3600,
          'iceServers': <Object>[
            <String, Object>{'urls': 'turn:t.example.com', 'username': 'u'},
          ],
        },
        CallKind.audio,
      );
      expect(r.mode, CallMode.p2p);
      expect(r.kind, CallKind.video);
      expect(r.iceServers, hasLength(1));
      expect(r.ttlSeconds, 3600);
    });

    test('livekit response with group and url; p2p without callId throws', () {
      final r = parseCallCreateResponse(
        <String, Object>{
          'callId': 'c3',
          'mode': 'livekit',
          'group': true,
          'livekitUrl': 'wss://lk.example.com',
        },
        CallKind.video,
      );
      expect(r.group, isTrue);
      expect(r.livekitUrl, 'wss://lk.example.com');
      expect(
        () => parseCallCreateResponse(
          <String, Object>{'mode': 'p2p'},
          CallKind.video,
        ),
        throwsFormatException,
      );
    });
  });

  group('isSystemAccountSender', () {
    test('only <appId>_<appId> on the right domain', () {
      expect(isSystemAccountSender('$system@xmpp.example.com'), isTrue);
      expect(isSystemAccountSender('$system@xmpp.example.com/res'), isTrue);
      expect(
        isSystemAccountSender('$system@XMPP.example.com', 'xmpp.example.com'),
        isTrue,
      );
      expect(
        isSystemAccountSender('$system@evil.example.com', 'xmpp.example.com'),
        isFalse,
      );
      expect(
          isSystemAccountSender('${hex24}_${hex24.replaceFirst('0', '1')}@h'),
          isFalse);
      expect(isSystemAccountSender('alice@xmpp.example.com'), isFalse);
      expect(isSystemAccountSender('$system@a@b'), isFalse);
      expect(isSystemAccountSender(null), isFalse);
      expect(isSystemAccountSender(''), isFalse);
      expect(isSystemAccountSender('@host'), isFalse);
    });
  });

  group('freshness (5 s)', () {
    String stanzaWithId(String id) =>
        '<message><stanza-id xmlns="urn:xmpp:sid:0" by="r" id="$id"/></message>';

    test('a microsecond stanza-id within 5 s is fresh, older is not', () {
      const now = 1760000000000;
      final fresh = parse(stanzaWithId('${now - 4000}123'));
      final stale = parse(stanzaWithId('${now - 6000}123'));
      expect(isFreshCallToken(fresh, nowMs: now), isTrue);
      expect(isFreshCallToken(stale, nowMs: now), isFalse);
      expect(
          isFreshCallToken(parse(stanzaWithId('${now - 5000}000')), nowMs: now),
          isTrue);
    });

    test('no stanza-id, or a non numeric one, is never fresh', () {
      expect(
          isFreshCallToken(parse('<message/>'), nowMs: 1760000000000), isFalse);
      expect(
        isFreshCallToken(parse(stanzaWithId('abc')), nowMs: 1760000000000),
        isFalse,
      );
    });

    test('extractNumericTimestamp takes the first 13 digits', () {
      expect(extractNumericTimestamp('1760000000123456'), 1760000000123);
      expect(extractNumericTimestamp('1760000000123'), 1760000000123);
      expect(extractNumericTimestamp('x1760000000123456y'), 1760000000123);
      expect(extractNumericTimestamp(''), isNull);
      expect(extractNumericTimestamp(null), isNull);
    });
  });

  group('JWT claims', () {
    test('sub is the caller name, raw ids are skipped', () {
      expect(
        extractCallerDisplayName(
            decodeJwtPayload(jwt(<String, Object?>{'sub': 'Ann Lee'}))),
        'Ann Lee',
      );
      expect(
        extractCallerDisplayName(
          decodeJwtPayload(jwt(<String, Object?>{'sub': '${hex24}_$hex24'})),
        ),
        isEmpty,
      );
      expect(extractCallerDisplayName(null), isEmpty);
    });

    test('callId comes from the attribute, else the JWT metadata', () {
      final withAttr = parse('<data type="call-token" callId="A1"/>');
      expect(extractCallId(withAttr, null), 'A1');
      final noAttr = parse('<data type="call-token"/>');
      expect(
        extractCallId(
          noAttr,
          decodeJwtPayload(
            jwt(<String, Object?>{
              'metadata': jsonEncode(<String, Object>{'callId': 'M2'})
            }),
          ),
        ),
        'M2',
      );
      expect(
        extractCallId(
          noAttr,
          decodeJwtPayload(
            jwt(<String, Object?>{
              'metadata': <String, Object>{'callId': 'M3'},
            }),
          ),
        ),
        'M3',
      );
      expect(extractCallId(noAttr, null), isNull);
    });

    test('a malformed token decodes to null instead of throwing', () {
      expect(decodeJwtPayload(null), isNull);
      expect(decodeJwtPayload(''), isNull);
      expect(decodeJwtPayload('nodots'), isNull);
      expect(decodeJwtPayload('a.!!!.c'), isNull);
    });
  });

  test('derivePeerXmppUsername removes our own half of the room name', () {
    expect(derivePeerXmppUsername('me-you', 'me'), 'you');
    expect(derivePeerXmppUsername('me-you', 'you@host'), 'me');
    expect(derivePeerXmppUsername('a-b-c', 'a'), isNull);
    expect(derivePeerXmppUsername('plain', 'a'), isNull);
  });

  group('kind hints', () {
    test('a hint is consumed once, by room or by callId, and expires', () {
      var now = 1000;
      final hints = CallKindHints(now: () => now);
      hints.stash('roomA', 'audio');
      hints.stash('call1', 'audio');
      expect(hints.consume(<String?>[null, 'roomA']), 'audio');
      expect(hints.consume(<String?>['roomA']), isNull);
      expect(hints.consume(<String?>['call1']), 'audio');
      hints.stash('roomB', 'video');
      now += kKindHintTtlMs + 1;
      expect(hints.consume(<String?>['roomB']), isNull);
    });
  });

  group('classifyCallMessage', () {
    test('unwraps a MUCSub wrapper and finds the call-token', () {
      final wrapped = parse('''
<message from="room@conference.h" type="headline">
  <event xmlns="http://jabber.org/protocol/pubsub#event"><items node="urn:xmpp:mucsub:nodes:messages"><item id="1">
    <message from="room@conference.h/sys" type="groupchat">
      <data type="call-token" token="t" room="room" callId="c"/>
      <stanza-id xmlns="urn:xmpp:sid:0" by="room@conference.h" id="1760000000000111"/>
    </message>
  </item></items></event>
</message>''');
      final c = classifyCallMessage(wrapped);
      expect(c, isA<CallTokenStanza>());
      expect((c as CallTokenStanza).attr('callId'), 'c');
      expect(c.fromRoom, 'room');
    });

    test('classifies every call-* type and body-only keywords', () {
      Object? kind(String data) => classifyCallMessage(parse(
          '<message from="a@h" type="chat"><data type="$data"/></message>'));
      expect(kind('call-state'), isA<CallStateStanza>());
      expect(kind('call-invite'), isA<CallInviteStanza>());
      expect(kind('call-p2p'), isA<CallP2pStanza>());
      expect(kind('call-state-declined'), isA<CallDeclinedRelayStanza>());
      expect(kind('call-state-ringing'), isA<CallRingingRelayStanza>());
      expect(kind('call-something-new'), isA<CallUnknownStanza>());
      expect(kind('message'), isNull);
      final body = classifyCallMessage(
        parse('<message type="groupchat"><body>call-ended</body></message>'),
      );
      expect(body, isA<CallBodyOnlyStanza>());
      expect((body! as CallBodyOnlyStanza).state, 'ended');
      expect(
        classifyCallMessage(parse('<message><body>hello</body></message>')),
        isNull,
      );
    });

    test('callStateHasLogData tells a server log from bare signalling', () {
      expect(
        callStateHasLogData(parse('<data type="call-state" durationMs="0"/>')),
        isTrue,
      );
      expect(
        callStateHasLogData(
          parse('<data type="call-state" callerXmppUsername="a"/>'),
        ),
        isTrue,
      );
      expect(
        callStateHasLogData(parse('<data type="call-state" state="ended"/>')),
        isFalse,
      );
    });
  });

  group('outgoing stanzas', () {
    test('call-state and call-invite round trip through the parser', () {
      final state = parse(buildCallStateStanza(
        to: 'peer@host',
        state: CallSignalState.declined,
        callId: 'c"1',
        room: 'r&m',
        nowMs: 5,
      ));
      expect(state.getAttribute('to'), 'peer@host');
      expect(state.getAttribute('type'), 'chat');
      expect(state.getAttribute('id'), 'call-state-5');
      final sd = state.getElement('data')!;
      expect(sd.getAttribute('state'), 'declined');
      expect(sd.getAttribute('callId'), 'c"1');
      expect(sd.getAttribute('room'), 'r&m');

      final invite = parse(buildCallInviteStanza(
        to: 'peer@host',
        kind: 'audio',
        room: 'r',
        nowMs: 6,
      ));
      expect(invite.getAttribute('id'), 'call-invite-6');
      final id = invite.getElement('data')!;
      expect(id.getAttribute('type'), 'call-invite');
      expect(id.getAttribute('kind'), 'audio');
      expect(id.getAttribute('callId'), '');
    });
  });
}
