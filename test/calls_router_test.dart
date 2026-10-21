import 'dart:convert';

import 'package:ethora_sdk_flutter/src/calls/call_mode.dart';
import 'package:ethora_sdk_flutter/src/calls/call_stanza.dart';
import 'package:ethora_sdk_flutter/src/calls/call_state.dart';
import 'package:ethora_sdk_flutter/src/calls/call_token_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const String hex24 = '0123456789abcdef01234567';
const String systemFrom = '${hex24}_$hex24@xmpp.example.com';
const int now = 1760000000000;

String jwt(Map<String, Object?> payload) {
  String enc(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${enc(<String, Object>{'alg': 'HS256'})}.${enc(payload)}.sig';
}

/// A call-token message as the router sees it.
XmlElement tokenMessage({
  String from = systemFrom,
  String attrs = '',
  int stanzaAgeMs = 1000,
}) {
  return XmlDocument.parse(
    '<message from="$from" type="chat">'
    '<data type="call-token" $attrs/>'
    '<stanza-id xmlns="urn:xmpp:sid:0" by="x" id="${now - stanzaAgeMs}123"/>'
    '</message>',
  ).rootElement;
}

IncomingTokenPlan plan(
  XmlElement message, {
  bool enabled = true,
  List<CallRoomType>? allowed,
  CallSessionState current = CallSessionState.idle,
  CallRoomInfo? Function(String)? resolve,
  bool p2pSupported = true,
  CallKindHints? hints,
  String Function(String?)? lookup,
}) {
  return planIncomingCallToken(
    message: message,
    data: message.getElement('data')!,
    videoCallsEnabled: enabled,
    allowedRoomTypes: allowed,
    current: current,
    selfXmppUsername: 'me',
    sessionDomain: 'xmpp.example.com',
    resolveRoom: resolve ??
        (room) => CallRoomInfo(
              jid: '$room@conference.xmpp.example.com',
              title: 'Ann Lee',
              type: 'private',
              usersCnt: 2,
            ),
    lookupUserName: lookup ?? (_) => '',
    kindHints: hints ?? CallKindHints(now: () => now),
    p2pSupported: p2pSupported,
    nowMs: now,
  );
}

CallSessionState outgoingP2p({String callId = 'm1', String room = 'me-you'}) {
  return CallSessionState.startOutgoing(
    roomJid: '$room@conference.xmpp.example.com',
    roomBareName: room,
    kind: CallKind.video,
    peerXmppUsername: 'you',
    nowMs: now,
  ).withOutgoingRoute(
    startedAt: now,
    callId: callId,
    mode: CallMode.p2p,
    iceServers: const <IceServerConfig>[],
  );
}

void main() {
  group('planIncomingCallToken', () {
    test('a fresh livekit token rings, named after the JWT sub', () {
      final token = jwt(<String, Object?>{
        'sub': 'Roman Test',
        'metadata': jsonEncode(<String, String>{'callId': 'jwt-call'}),
      });
      final p = plan(
        tokenMessage(attrs: 'token="$token" room="me-you"'),
        resolve: (_) => null,
      );
      // No resolvable room and not a private name: ignored.
      expect(p.action, IncomingTokenAction.ignore);

      final ring = plan(
        tokenMessage(attrs: 'token="$token" room="me-you" kind="audio"'),
        resolve: (room) => CallRoomInfo(
          jid: '$room@conference.xmpp.example.com',
          title: 'deleted',
          type: 'private',
          usersCnt: 2,
        ),
      );
      expect(ring.action, IncomingTokenAction.ring);
      expect(ring.roomName, 'Roman Test', reason: 'JWT sub beats a bad title');
      expect(ring.callId, 'jwt-call', reason: 'from JWT metadata');
      expect(ring.mode, CallMode.livekit);
      expect(ring.kind, CallKind.audio);
      expect(ring.peerXmppUsername, 'you');
      expect(ring.roomJid, 'me-you@conference.xmpp.example.com');
    });

    test('a call-invite kind hint beats the stanza kind', () {
      final hints = CallKindHints(now: () => now)..stash('me-you', 'audio');
      final p = plan(
        tokenMessage(attrs: 'token="t" room="me-you" kind="video" callId="c"'),
        hints: hints,
      );
      expect(p.kind, CallKind.audio);
    });

    test('disabled, stale, tokenless or roomless stanzas are ignored', () {
      const ok = 'token="t" room="me-you" callId="c"';
      expect(plan(tokenMessage(attrs: ok)).action, IncomingTokenAction.ring);
      expect(
        plan(tokenMessage(attrs: ok), enabled: false).action,
        IncomingTokenAction.ignore,
      );
      expect(
        plan(tokenMessage(attrs: ok, stanzaAgeMs: 6000)).action,
        IncomingTokenAction.ignore,
        reason: '5 s freshness',
      );
      expect(
        plan(tokenMessage(attrs: 'room="me-you" callId="c"')).action,
        IncomingTokenAction.ignore,
        reason: 'livekit needs a token',
      );
      expect(
        plan(tokenMessage(attrs: 'token="t" callId="c"')).action,
        IncomingTokenAction.ignore,
      );
    });

    test('mode=p2p needs no token but needs a callId; it rings like livekit',
        () {
      final ice = jsonEncode(<Object>[
        <String, String>{'urls': 'turn:t.example.com', 'username': 'u'},
      ]);
      final p = plan(
        tokenMessage(
          attrs: "mode=\"p2p\" room=\"me-you\" callId=\"p1\" kind=\"video\" "
              "ice='$ice' callerName=\"Ann Lee\" caller=\"you\"",
        ),
      );
      expect(p.action, IncomingTokenAction.ring);
      expect(p.mode, CallMode.p2p);
      expect(p.token, isEmpty);
      expect(p.callId, 'p1');
      expect(p.iceServers, hasLength(1));
      expect(p.roomName, 'Ann Lee');
      expect(p.callerXmppUsername, 'you');

      expect(
        plan(tokenMessage(attrs: 'mode="p2p" room="me-you"')).action,
        IncomingTokenAction.ignore,
        reason: 'a p2p token without a callId is unusable',
      );
    });

    test(
        'livekitUrl, ice, callerName and caller are honoured only from the '
        'system account', () {
      const attrs =
          'token="t" room="me-you" callId="c" livekitUrl="wss://lk.example.com" '
          'callerName="Mallory" caller="mal"';
      final trusted = plan(tokenMessage(attrs: attrs));
      expect(trusted.livekitUrl, 'wss://lk.example.com');
      expect(trusted.callerName, 'Mallory');
      expect(trusted.callerXmppUsername, 'mal');

      final forged =
          plan(tokenMessage(from: 'mallory@xmpp.example.com', attrs: attrs));
      expect(forged.action, IncomingTokenAction.ring, reason: 'still rings');
      expect(forged.livekitUrl, isNull);
      expect(forged.callerName, isNull);
      expect(forged.callerXmppUsername, isNull);
      expect(forged.roomName, 'Ann Lee', reason: 'falls back to the title');

      final wrongDomain = plan(
          tokenMessage(from: '${hex24}_$hex24@evil.example.org', attrs: attrs));
      expect(wrongDomain.livekitUrl, isNull);

      final p2pForged = plan(
        tokenMessage(
          from: 'mallory@xmpp.example.com',
          attrs: 'mode="p2p" room="me-you" callId="p1" '
              'ice=\'[{"urls":"turn:evil.example.org"}]\'',
        ),
      );
      expect(p2pForged.action, IncomingTokenAction.ring);
      expect(p2pForged.iceServers, isNull);
    });

    test('a raw chat name is never the ring name', () {
      final raw = '${hex24}_$hex24-${hex24.replaceFirst('0', '9')}_$hex24';
      final p = plan(
        tokenMessage(attrs: 'mode="p2p" room="$raw" callId="p1"'),
        resolve: (room) => CallRoomInfo(
          jid: '$room@conference.xmpp.example.com',
          title: raw,
          type: 'private',
          usersCnt: 2,
        ),
      );
      expect(p.action, IncomingTokenAction.ring);
      expect(p.roomName, isEmpty, reason: 'UI then shows a neutral label');
    });

    test('names the caller from the members when the title is unusable', () {
      final p = plan(
        tokenMessage(attrs: 'mode="p2p" room="me-you" callId="p1"'),
        resolve: (room) => CallRoomInfo(
          jid: '$room@conference.xmpp.example.com',
          title: 'Deleted User',
          type: 'private',
          usersCnt: 2,
        ),
        lookup: (xmpp) => xmpp == 'you' ? 'Ann Lee' : '',
      );
      expect(p.roomName, 'Ann Lee');
    });

    test('group tokens: livekit only, name the room, honour allowedRoomTypes',
        () {
      const attrs = 'token="t" room="grp" callId="g1" group="true" '
          'callerName="Ann" ';
      CallRoomInfo? groupRoom(String room) => CallRoomInfo(
            jid: '$room@conference.xmpp.example.com',
            title: 'Team Chat',
            type: 'group',
            usersCnt: 5,
          );
      final p = plan(tokenMessage(attrs: attrs), resolve: groupRoom);
      expect(p.action, IncomingTokenAction.ring);
      expect(p.isGroup, isTrue);
      expect(p.roomName, 'Team Chat');
      expect(p.callerName, 'Ann');
      expect(p.peerXmppUsername, isNull);

      expect(
        plan(
          tokenMessage(attrs: attrs),
          resolve: groupRoom,
          allowed: const <CallRoomType>[CallRoomType.private],
        ).action,
        IncomingTokenAction.ignore,
      );
      // A room we know to be private contradicts `group`.
      expect(
          plan(tokenMessage(attrs: attrs)).action, IncomingTokenAction.ignore);
      // A 1:1 token for a big public room is not ours to ring for.
      expect(
        plan(
          tokenMessage(attrs: 'token="t" room="grp" callId="x"'),
          resolve: groupRoom,
        ).action,
        IncomingTokenAction.ignore,
      );
    });

    test('allowedRoomTypes [group] refuses a 1:1 token', () {
      expect(
        plan(
          tokenMessage(attrs: 'token="t" room="me-you" callId="c"'),
          allowed: const <CallRoomType>[CallRoomType.group],
        ).action,
        IncomingTokenAction.ignore,
      );
    });

    test('p2p while another call is active: duplicate ignored, busy declined',
        () {
      final mine = outgoingP2p(callId: 'same');
      expect(
        plan(
          tokenMessage(attrs: 'mode="p2p" room="other" callId="same"'),
          current: mine,
        ).action,
        IncomingTokenAction.ignore,
        reason: 'server re-delivery of the active call',
      );
      final busy = plan(
        tokenMessage(attrs: 'mode="p2p" room="other-one" callId="zzz"'),
        current: mine,
      );
      expect(busy.action, IncomingTokenAction.declineBusy);
      expect(busy.callId, 'zzz');
      expect(busy.roomBareName, 'other-one');

      // A livekit token while a p2p call runs is ignored, not declined.
      expect(
        plan(tokenMessage(attrs: 'token="t" room="x-y" callId="q"'),
                current: mine)
            .action,
        IncomingTokenAction.ignore,
      );
    });

    test('glare: the smaller callId wins on both ends', () {
      final mine = outgoingP2p(callId: 'bbb');
      final theirSmaller = plan(
        tokenMessage(attrs: 'mode="p2p" room="me-you" callId="aaa"'),
        current: mine,
      );
      expect(theirSmaller.action, IncomingTokenAction.ring);
      expect(theirSmaller.glareYield, isTrue);

      final theirLarger = plan(
        tokenMessage(attrs: 'mode="p2p" room="me-you" callId="ccc"'),
        current: mine,
      );
      expect(theirLarger.action, IncomingTokenAction.ignore,
          reason: 'we keep ours, they yield');
    });

    test('p2p on a platform without WebRTC is declined, not rung', () {
      final p = plan(
        tokenMessage(attrs: 'mode="p2p" room="me-you" callId="p1"'),
        p2pSupported: false,
      );
      expect(p.action, IncomingTokenAction.declineUnsupported);
      expect(p.callId, 'p1');
    });

    test('the token for the call we dialled connects it instead of ringing',
        () {
      final dialling = CallSessionState.startOutgoing(
        roomJid: 'me-you@conference.xmpp.example.com',
        roomName: 'Ann Lee',
        roomBareName: 'me-you',
        peerXmppUsername: 'you',
        nowMs: now,
      );
      final p = plan(
        tokenMessage(
          attrs:
              'token="t" room="me-you" callId="c" livekitUrl="wss://lk.example.com"',
        ),
        current: dialling,
      );
      expect(p.action, IncomingTokenAction.outgoingToken);
      expect(p.token, 't');
      expect(p.callId, 'c');
      expect(p.livekitUrl, 'wss://lk.example.com');

      final next = dialling.withOutgoingToken(
        roomJid: p.roomJid,
        token: p.token,
        callId: p.callId,
        livekitUrl: p.livekitUrl,
        nowMs: now,
      );
      expect(next.phase, CallPhase.connecting);
      expect(next.token, 't');
      expect(next.livekitUrl, 'wss://lk.example.com');
    });
  });

  group('decideIncomingWhileBusy', () {
    BusyCallSnapshot snap({
      String phase = 'in-call',
      String? direction = 'incoming',
      CallMode mode = CallMode.livekit,
      String? callId = 'c1',
      String? room = 'r1',
    }) =>
        BusyCallSnapshot(
          phase: phase,
          direction: direction,
          mode: mode,
          callId: callId,
          roomBareName: room,
        );

    test('idle accepts; same callId is a duplicate', () {
      expect(
        decideIncomingWhileBusy(snap(phase: 'idle'),
            mode: CallMode.p2p, callId: 'x', roomBareName: 'r'),
        IncomingWhileBusy.accept,
      );
      expect(
        decideIncomingWhileBusy(snap(),
            mode: CallMode.livekit, callId: 'c1', roomBareName: 'r'),
        IncomingWhileBusy.duplicate,
      );
    });

    test('livekit over livekit keeps the legacy replace behaviour', () {
      expect(
        decideIncomingWhileBusy(snap(),
            mode: CallMode.livekit, callId: 'c2', roomBareName: 'r2'),
        IncomingWhileBusy.replace,
      );
    });

    test('anything involving p2p and a different call is busy', () {
      expect(
        decideIncomingWhileBusy(snap(mode: CallMode.p2p),
            mode: CallMode.livekit, callId: 'c2', roomBareName: 'r1'),
        IncomingWhileBusy.busy,
      );
      expect(
        decideIncomingWhileBusy(snap(),
            mode: CallMode.p2p, callId: 'c2', roomBareName: 'r1'),
        IncomingWhileBusy.busy,
      );
    });

    test('glare needs the same room, our own dial, both p2p and both ids', () {
      final dialling = snap(
        phase: 'requesting',
        direction: 'outgoing',
        mode: CallMode.p2p,
        callId: 'm',
      );
      expect(
        decideIncomingWhileBusy(dialling,
            mode: CallMode.p2p, callId: 'a', roomBareName: 'r1'),
        IncomingWhileBusy.glareYield,
      );
      expect(
        decideIncomingWhileBusy(dialling,
            mode: CallMode.p2p, callId: 'z', roomBareName: 'r1'),
        IncomingWhileBusy.glareKeep,
      );
      expect(
        decideIncomingWhileBusy(dialling,
            mode: CallMode.p2p, callId: 'a', roomBareName: 'other'),
        IncomingWhileBusy.busy,
      );
      expect(
        decideIncomingWhileBusy(
            snap(
              phase: 'connecting',
              direction: 'outgoing',
              mode: CallMode.p2p,
              callId: 'm',
            ),
            mode: CallMode.p2p,
            callId: 'a',
            roomBareName: 'r1'),
        IncomingWhileBusy.busy,
        reason: 'already connecting: not a glare',
      );
    });
  });

  group('shouldEndCallForState', () {
    CallSessionState active() => CallSessionState.incoming(
          roomJid: 'room@conference.h',
          roomBareName: 'room',
          token: 't',
          callId: 'c1',
          nowMs: now,
        ).accepted(now);

    test('a terminal client state for this call or room ends it', () {
      for (final state in <String>[
        'ended',
        'declined',
        'cancelled',
        'rejected'
      ]) {
        expect(
          shouldEndCallForState(active(),
              state: state,
              roomAttr: 'room',
              callIdAttr: '',
              hasLogData: false),
          isTrue,
          reason: state,
        );
      }
      expect(
        shouldEndCallForState(active(),
            state: 'ended',
            roomAttr: 'nope',
            callIdAttr: 'c1',
            hasLogData: false),
        isTrue,
      );
    });

    test('a server call-log (no state, with log data) ends it', () {
      expect(
        shouldEndCallForState(active(),
            state: '', roomAttr: 'room', callIdAttr: 'c1', hasLogData: true),
        isTrue,
      );
      expect(
        shouldEndCallForState(active(),
            state: '', roomAttr: 'room', callIdAttr: 'c1', hasLogData: false),
        isFalse,
      );
    });

    test(
        'a signal for a DIFFERENT call, an idle state or a non terminal '
        'state is ignored', () {
      expect(
        shouldEndCallForState(active(),
            state: 'ended',
            roomAttr: 'room',
            callIdAttr: 'other',
            hasLogData: false),
        isFalse,
      );
      expect(
        shouldEndCallForState(CallSessionState.idle,
            state: 'ended',
            roomAttr: 'room',
            callIdAttr: 'c1',
            hasLogData: false),
        isFalse,
      );
      expect(
        shouldEndCallForState(active(),
            state: 'ringing',
            roomAttr: 'room',
            callIdAttr: 'c1',
            hasLogData: false),
        isFalse,
      );
      expect(
        shouldEndCallForState(active(),
            state: 'ended',
            roomAttr: 'other-room',
            callIdAttr: '',
            hasLogData: false),
        isFalse,
      );
    });
  });
}
