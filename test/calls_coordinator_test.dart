import 'dart:async';

import 'package:ethora_sdk_flutter/src/calls/call_api.dart';
import 'package:ethora_sdk_flutter/src/calls/call_mode.dart';
import 'package:ethora_sdk_flutter/src/calls/call_state.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_ice_policy.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_signal.dart';
import 'package:ethora_sdk_flutter/src/models/chat_room.dart';
import 'package:ethora_sdk_flutter/src/models/video_calls_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/calls_setup.dart';

void main() {
  group('dialling a p2p call', () {
    test('invite, create, offer, answer, connected, hang up', () async {
      final s = Setup();
      s.api.result = p2pCreated;
      final room = s.host.rooms.first;

      final dialing = s.calls.startCall(room, CallKind.video);
      expect(s.state.phase, CallPhase.requesting);
      expect(s.state.roomName, 'Ann Lee');
      expect(s.state.peerXmppUsername, 'you');
      expect(s.calls.isBusy, isTrue);

      // The kind hint goes to the peer BEFORE the create request.
      final invite = s.host.sent.single;
      expect(invite.getAttribute('to'), 'you@xmpp.example.com');
      expect(invite.getAttribute('type'), 'chat');
      final inviteData = invite.getElement('data')!;
      expect(inviteData.getAttribute('type'), 'call-invite');
      expect(inviteData.getAttribute('kind'), 'video');
      expect(inviteData.getAttribute('room'), roomName);

      await dialing;
      await s.settle();
      expect(s.api.created, <String>['$roomName:video']);
      expect(s.state.mode, CallMode.p2p);
      expect(s.state.callId, 'p1');
      expect(s.calls.p2pController, isNotNull);
      expect(s.host.p2pSignals(), <String>['offer']);
      final offerStanza = s.host.sentOfType('call-p2p').single;
      expect(offerStanza.getAttribute('to'), 'you@xmpp.example.com');

      // The callee answers; media connects.
      expect(
        s.p2pSignalFromPeer(
          P2PSignalName.answer,
          const P2PSignalPayload.sdp('answer-sdp'),
        ),
        isTrue,
        reason: 'p2p signalling never reaches the chat pipeline',
      );
      await s.settle();
      expect(s.state.phase, CallPhase.connecting);

      s.p2pDeps.single.pc.emitState(P2PConnState.connected);
      expect(s.state.phase, CallPhase.inCall);
      expect(s.state.connectedAt, isNotNull);
      expect(s.api.reports, contains('connected:p1'));

      s.calls.hangup();
      await s.settle();
      expect(s.state.isIdle, isTrue);
      expect(s.calls.p2pController, isNull);
      final endSignal = s.host.sentOfType('call-state').single;
      expect(endSignal.getElement('data')!.getAttribute('state'), 'ended');
      expect(endSignal.getElement('data')!.getAttribute('callId'), 'p1');
      expect(s.host.p2pSignals().last, 'end');
      expect(s.api.reports, contains('end:p1'));
    });

    test('the callee not answering for 30 s cancels and reports the end',
        () async {
      final s = Setup(outgoingTimeout: const Duration(milliseconds: 40));
      s.api.result = p2pCreated;
      await s.calls.startCall(s.host.rooms.first, CallKind.video);
      await s.settle();
      expect(s.state.phase, CallPhase.requesting);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(s.state.phase, CallPhase.error);
      expect(s.state.error, 'No answer - call timed out');
      final cancelled = s.host.sentOfType('call-state').single;
      expect(cancelled.getElement('data')!.getAttribute('state'), 'cancelled');
      expect(s.api.reports, contains('end:p1'));
      expect(s.calls.p2pController, isNull);

      s.calls.dismissError();
      expect(s.state.isIdle, isTrue);
    });

    test(
        'cancelling while the create request is in flight cleans up the '
        'late p2p answer', () async {
      final s = Setup();
      s.api.gate = Completer<CallCreateResult>();
      final dialing = s.calls.startCall(s.host.rooms.first, CallKind.video);
      s.calls.hangup();
      expect(s.state.isIdle, isTrue);
      expect(
        s.host
            .sentOfType('call-state')
            .single
            .getElement('data')!
            .getAttribute('state'),
        'cancelled',
      );

      s.api.gate!.complete(p2pCreated);
      await dialing;
      expect(s.state.isIdle, isTrue,
          reason: 'the late answer did not revive it');
      expect(s.api.reports, <String>['end:p1']);
      final cancels = s.host.sentOfType('call-state');
      expect(cancels, hasLength(2));
      expect(cancels.last.getElement('data')!.getAttribute('callId'), 'p1');
      expect(s.calls.p2pController, isNull);
    });

    test('a failed create request shows the error and is dismissible',
        () async {
      final s = Setup();
      s.api.error = const CallCreateException('Chat not found');
      await s.calls.startCall(s.host.rooms.first, CallKind.audio);
      expect(s.state.phase, CallPhase.error);
      expect(s.state.error, 'Chat not found');
      s.calls.hangup();
      expect(s.state.isIdle, isTrue);
    });

    test('calls are refused when off, busy, a missing url or a wrong room',
        () async {
      final off = Setup(config: const VideoCallsConfig());
      await off.calls.startCall(off.host.rooms.first, CallKind.video);
      expect(off.state.isIdle, isTrue);
      expect(off.api.created, isEmpty);

      final noUrl = Setup(config: const VideoCallsConfig(enabled: true));
      expect(noUrl.calls.canCallRoom(noUrl.host.rooms.first), isFalse);

      final onlyPrivate = Setup(
        config: const VideoCallsConfig(
          enabled: true,
          livekitUrl: 'wss://lk.example.com',
          allowedRoomTypes: <CallRoomType>[CallRoomType.private],
        ),
      );
      expect(
          onlyPrivate.calls.canCallRoom(onlyPrivate.host.rooms.first), isTrue);
      expect(
          onlyPrivate.calls.canCallRoom(onlyPrivate.host.rooms.last), isFalse);

      final s = Setup();
      s.api.result = p2pCreated;
      await s.calls.startCall(s.host.rooms.first, CallKind.video);
      await s.calls.startCall(s.host.rooms.first, CallKind.video);
      expect(s.api.created, hasLength(1), reason: 'one call at a time');
    });
  });

  group('incoming p2p call', () {
    test(
        'rings, reports ringing once, catches an early offer, answers on '
        'accept', () async {
      final s = Setup();
      expect(s.p2pToken(), isTrue);
      await s.settle();
      expect(s.state.isRingingIncoming, isTrue);
      expect(s.state.roomName, 'Ann Lee');
      expect(s.state.kind, CallKind.video);
      expect(s.state.mode, CallMode.p2p);
      expect(s.state.peerXmppUsername, 'you');
      expect(s.api.reports, <String>['ringing:p1']);
      expect(s.calls.p2pController, isNotNull);
      expect(s.p2pDeps.single.mediaCalls, 0, reason: 'no media before Accept');

      // The caller's offer and a candidate arrive while it rings.
      s.p2pSignalFromPeer(
        P2PSignalName.offer,
        const P2PSignalPayload.sdp('offer-sdp'),
      );
      s.p2pSignalFromPeer(
        P2PSignalName.candidate,
        const P2PSignalPayload.candidate(P2PCandidate(candidate: 'early')),
      );
      await s.settle();
      expect(s.host.p2pSignals(), isEmpty);

      s.calls.acceptIncoming();
      await s.settle();
      expect(s.state.phase, CallPhase.connecting);
      expect(s.host.p2pSignals(), <String>['answer']);
      final pc = s.p2pDeps.single.pc;
      expect(pc.calls, contains('setRemote:offer'));
      expect(pc.calls, contains('addCandidate:early'));

      pc.emitState(P2PConnState.connected);
      expect(s.state.phase, CallPhase.inCall);
      expect(s.api.reports, isNot(contains('connected:p1')),
          reason: 'only the caller reports connected');

      // The caller hangs up.
      s.p2pSignalFromPeer(
          P2PSignalName.end, const P2PSignalPayload.end('hangup'));
      await s.settle();
      expect(s.state.isIdle, isTrue);
      expect(s.api.reports, contains('end:p1'));
      expect(s.host.p2pSignals(), isNot(contains('end')), reason: 'no echo');
    });

    test('a signal re-delivery of the same token does not ring twice',
        () async {
      final s = Setup();
      s.p2pToken();
      s.p2pToken();
      await s.settle();
      expect(s.api.reports.where((r) => r.startsWith('ringing')), hasLength(1));
      expect(s.p2pDeps, hasLength(1));
    });

    test('declining tells the caller twice-over and reports the decline',
        () async {
      final s = Setup();
      s.p2pToken();
      await s.settle();
      s.calls.declineIncoming();
      await s.settle();
      expect(s.state.isIdle, isTrue);
      final declined = s.host.sentOfType('call-state').single;
      expect(declined.getElement('data')!.getAttribute('state'), 'declined');
      expect(declined.getAttribute('to'), 'you@xmpp.example.com');
      expect(s.api.reports, <String>['ringing:p1', 'decline:p1']);
      expect(s.p2pDeps.single.mediaCalls, 0);
      expect(s.calls.p2pController, isNull);
      // Stragglers of the declined call are dropped, not buffered.
      s.p2pSignalFromPeer(
        P2PSignalName.offer,
        const P2PSignalPayload.sdp('late'),
      );
      expect(s.state.isIdle, isTrue);
    });

    test('the caller cancelling while it rings dismisses the ring', () async {
      final s = Setup();
      s.p2pToken();
      await s.settle();
      expect(
        s.deliverXml(
          '<message from="you@xmpp.example.com" type="chat">'
          '<data type="call-state" state="cancelled" callId="p1" room="$roomName"/>'
          '</message>',
        ),
        isTrue,
      );
      expect(s.state.isIdle, isTrue);
    });

    test('a stale, forged or busy token never rings', () async {
      final s = Setup();
      s.p2pToken(ageMs: 9000);
      expect(s.state.isIdle, isTrue);

      // Forged sender: still rings (its network targets are dropped) ...
      s.p2pToken(from: 'mallory@xmpp.example.com', callId: 'f1');
      await s.settle();
      expect(s.state.isRingingIncoming, isTrue);
      expect(s.state.iceServers, isNull, reason: 'untrusted ice is dropped');

      // ... and a second call while busy is declined.
      s.host.rooms = <ChatRoom>[
        ...s.host.rooms,
        const ChatRoom(
          jid: 'me-other@conference.xmpp.example.com',
          title: 'Bob',
          type: 'private',
          usersCnt: 2,
        ),
      ];
      s.p2pToken(callId: 'second', room: 'me-other');
      await s.settle();
      expect(s.state.callId, 'f1');
      expect(s.api.reports, contains('decline:second'));
      final declined = s.host.sentOfType('call-state').single;
      expect(declined.getElement('data')!.getAttribute('callId'), 'second');
    });

    test('glare: both dial at once, the smaller callId survives on both ends',
        () async {
      final s = Setup();
      s.api.result = const CallCreateResult(
        callId: 'bbb',
        mode: CallMode.p2p,
        kind: CallKind.video,
        group: null,
        livekitUrl: null,
        iceServers: <IceServerConfig>[
          IceServerConfig(urls: <String>['turn:t.example.com']),
        ],
        ttlSeconds: null,
      );
      await s.calls.startCall(s.host.rooms.first, CallKind.video);
      await s.settle();
      expect(s.state.callId, 'bbb');
      final ours = s.p2pDeps.single;

      // Their call has the smaller id: we yield and ring for it.
      s.p2pToken(callId: 'aaa');
      await s.settle();
      expect(s.state.isRingingIncoming, isTrue);
      expect(s.state.callId, 'aaa');
      expect(s.api.reports, contains('end:bbb'));
      expect(
        s.host
            .sentOfType('call-state')
            .first
            .getElement('data')!
            .getAttribute('state'),
        'cancelled',
      );
      expect(ours.pc.closed, isTrue, reason: 'our attempt was torn down');
    });
  });

  group('server signalling', () {
    test('a call-state log flows on to the chat, bare signalling does not',
        () async {
      final s = Setup();
      expect(
        s.deliverXml(
          '<message from="$roomJid/sys" type="groupchat"><body>call-state</body>'
          '<data type="call-state" callId="x" durationMs="0" '
          'callerXmppUsername="you" isSystemMessage="true"/></message>',
        ),
        isFalse,
        reason: 'the chat shows it as a log entry',
      );
      expect(
        s.deliverXml(
          '<message from="you@xmpp.example.com" type="chat">'
          '<data type="call-state" state="ended" callId="x"/></message>',
        ),
        isTrue,
      );
    });

    test(
        'the server call-log of the active call ends it; another call does '
        'not', () async {
      final s = Setup();
      s.p2pToken();
      await s.settle();
      s.calls.acceptIncoming();
      await s.settle();
      s.deliverXml(
        '<message from="$roomJid/sys" type="groupchat">'
        '<data type="call-state" callId="old" durationMs="9" '
        'callerXmppUsername="you"/></message>',
      );
      expect(s.state.isIdle, isFalse, reason: 'a late log of another call');
      s.deliverXml(
        '<message from="$roomJid/sys" type="groupchat">'
        '<data type="call-state" callId="p1" durationMs="9" '
        'callerXmppUsername="you"/></message>',
      );
      expect(s.state.isIdle, isTrue);
    });

    test('the server decline relay ends a 1:1 call but not a group call',
        () async {
      final s = Setup();
      s.api.result = p2pCreated;
      await s.calls.startCall(s.host.rooms.first, CallKind.video);
      await s.settle();
      s.deliverXml(
        '<message from="$systemFrom" type="chat">'
        '<data type="call-state-declined" room="$roomName" callId="p1" '
        'group="true" by="x"/></message>',
      );
      expect(s.state.isIdle, isFalse, reason: 'one decline in a group');
      s.deliverXml(
        '<message from="$systemFrom" type="chat">'
        '<data type="call-state-declined" room="$roomName" callId="p1"/></message>',
      );
      expect(s.state.isIdle, isTrue);
    });

    test('the ringing relay marks the dial as ringing', () async {
      final s = Setup();
      s.api.result = p2pCreated;
      await s.calls.startCall(s.host.rooms.first, CallKind.video);
      await s.settle();
      expect(s.state.peerRinging, isFalse);
      s.deliverXml(
        '<message from="$systemFrom" type="chat">'
        '<data type="call-state-ringing" room="$roomName" callId="p1"/></message>',
      );
      expect(s.state.peerRinging, isTrue);
    });

    test('an invite hint switches an already-rung call to audio', () async {
      final s = Setup();
      s.p2pToken(kind: 'video');
      await s.settle();
      expect(s.state.kind, CallKind.video);
      s.deliverXml(
        '<message from="you@xmpp.example.com" type="chat">'
        '<data type="call-invite" kind="audio" room="$roomName" callId=""/></message>',
      );
      expect(s.state.kind, CallKind.audio);
    });

    test('the kind hint sent before the token decides the ring kind', () async {
      final s = Setup();
      s.deliverXml(
        '<message from="you@xmpp.example.com" type="chat">'
        '<data type="call-invite" kind="audio" room="$roomName"/></message>',
      );
      s.lkToken();
      expect(s.state.kind, CallKind.audio);
    });

    test('with calls off every call stanza is still swallowed', () async {
      final s = Setup(config: const VideoCallsConfig());
      expect(s.p2pToken(), isTrue);
      expect(s.state.isIdle, isTrue);
      expect(
        s.deliverXml(
          '<message type="groupchat"><body>call-token</body></message>',
        ),
        isTrue,
        reason: 'a legacy body-only signal never shows as a chat bubble',
      );
      expect(
        s.deliverXml('<message type="chat"><body>hello</body></message>'),
        isFalse,
      );
      expect(s.api.reports, isEmpty);
    });
  });

  group('livekit calls', () {
    test(
        '1:1: the token connects the dial, the server url wins, a peer '
        'leaving ends it', () async {
      final s = Setup();
      s.api.result = lkCreated;
      await s.calls.startCall(s.host.rooms.first, CallKind.audio);
      expect(s.state.mode, CallMode.livekit);
      expect(s.state.callId, 'l1');
      expect(s.sessions, isEmpty, reason: 'waiting for the call-token');

      expect(s.lkToken(), isTrue);
      await s.settle();
      expect(s.state.phase, CallPhase.connecting);
      final session = s.sessions.single;
      expect(session.params.url, 'wss://server.example.com');
      expect(session.params.token, 'jwt');
      expect(session.params.kind, CallKind.audio);
      expect(session.params.isGroup, isFalse);
      expect(session.connected, isTrue);

      session.events.onConnected!();
      expect(s.state.phase, CallPhase.inCall);

      session.events.onPeerLeft!();
      await s.settle();
      expect(s.state.isIdle, isTrue);
      expect(session.disposed, isTrue);
      expect(
        s.host
            .sentOfType('call-state')
            .single
            .getElement('data')!
            .getAttribute('state'),
        'ended',
      );
      expect(s.api.reports, isEmpty, reason: 'no p2p reports for livekit');
    });

    test('incoming: accept joins with the config url when the stanza has none',
        () async {
      final s = Setup();
      s.deliverXml(
        '<message from="$systemFrom" type="chat">'
        '<data type="call-token" token="jwt2" room="$roomName" callId="l9"/>'
        '${s.stanzaId()}</message>',
      );
      await s.settle();
      expect(s.state.isRingingIncoming, isTrue);
      expect(s.sessions, isEmpty);
      s.calls.acceptIncoming();
      await s.settle();
      expect(s.sessions.single.params.url, 'wss://lk.example.com');

      // Declining a livekit ring never uses the p2p decline report.
      final t = Setup();
      t.lkToken();
      t.calls.declineIncoming();
      expect(t.api.reports, isEmpty);
      expect(t.state.isIdle, isTrue);
    });

    test('a group call is livekit, group layout, and one leave does not end it',
        () async {
      final s = Setup();
      s.api.result = const CallCreateResult(
        callId: 'g1',
        mode: CallMode.livekit,
        kind: CallKind.video,
        group: true,
        livekitUrl: null,
        iceServers: <IceServerConfig>[],
        ttlSeconds: null,
      );
      await s.calls.startCall(s.host.rooms.last, CallKind.video);
      expect(s.state.isGroup, isTrue);
      expect(s.state.peerXmppUsername, isNull);
      expect(s.host.sentOfType('call-invite'), isEmpty,
          reason: 'a group has no single peer to hint');

      s.deliverXml(
        '<message from="$systemFrom" type="chat">'
        '<data type="call-token" token="jwt" room="$groupName" callId="g1" '
        'group="true"/>${s.stanzaId()}</message>',
      );
      await s.settle();
      expect(s.sessions.single.params.isGroup, isTrue);
      // The group session decides when the room is over; hanging up sends no
      // 1:1 signal because there is no peer.
      s.calls.hangup();
      expect(s.state.isIdle, isTrue);
      expect(s.host.sentOfType('call-state'), isEmpty);
    });

    test('a join failure shows the error and releases the session', () async {
      final s = Setup();
      s.lkToken();
      s.calls.acceptIncoming();
      await s.settle();
      s.sessions.single.events.onError!('token expired');
      await s.settle();
      expect(s.state.phase, CallPhase.error);
      expect(s.state.error, 'token expired');
      expect(s.sessions.single.disposed, isTrue);
    });

    test('a missing livekit url fails the call with a clear message', () async {
      final s = Setup(
        config: const VideoCallsConfig(enabled: true, livekitUrl: ' '),
      );
      s.deliverXml(
        '<message from="$systemFrom" type="chat">'
        '<data type="call-token" token="jwt" room="$roomName" callId="l9"/>'
        '${s.stanzaId()}</message>',
      );
      s.calls.acceptIncoming();
      await s.settle();
      expect(s.state.phase, CallPhase.error);
      expect(s.state.error, contains('livekitUrl'));
      expect(s.sessions, isEmpty);
    });
  });

  test('reset drops the call and held signalling; detach stops intercepting',
      () async {
    final s = Setup();
    s.p2pToken();
    await s.settle();
    s.calls.reset();
    expect(s.state.isIdle, isTrue);
    expect(s.calls.p2pController, isNull);
    s.calls.detach();
    expect(s.xmpp.messageInterceptors, isEmpty);
    expect(
      s.deliverXml('<message type="chat"><body>call-token</body></message>'),
      isFalse,
    );
  });
}
