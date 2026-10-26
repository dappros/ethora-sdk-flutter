import 'dart:convert';

import 'package:ethora_sdk_flutter/src/calls/call_log.dart';
import 'package:ethora_sdk_flutter/src/calls/call_mode.dart';
import 'package:ethora_sdk_flutter/src/calls/call_push.dart';
import 'package:ethora_sdk_flutter/src/calls/call_state.dart';
import 'package:ethora_sdk_flutter/src/calls/native_call_ui.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_ice_policy.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_signal.dart';
import 'package:ethora_sdk_flutter/src/models/chat_room.dart';
import 'package:ethora_sdk_flutter/src/models/video_calls_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/calls_fakes.dart';
import 'support/calls_setup.dart';

String jwt(Map<String, Object?> payload) {
  String enc(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${enc(<String, Object>{'alg': 'HS256'})}.${enc(payload)}.sig';
}

Map<String, dynamic> p2pPush({
  String callId = 'p1',
  String room = roomName,
  String caller = 'Ann Lee',
}) =>
    <String, dynamic>{
      'type': 'call',
      'callId': callId,
      'callToken': '',
      'room': room,
      'kind': 'video',
      'callerName': caller,
      'callerXmppUsername': 'you',
      'mode': 'p2p',
      'group': 'false',
    };

Map<String, dynamic> lkPush(
  Setup s, {
  String callId = 'l1',
  String room = roomName,
  int? expMs,
}) =>
    <String, dynamic>{
      'type': 'call',
      'callId': callId,
      'callToken': jwt(<String, Object?>{
        'sub': 'Ann Lee',
        'exp': ((expMs ?? s.nowMs + 60000) / 1000).round(),
      }),
      'room': room,
      'kind': 'audio',
      'callerName': 'Ann Lee',
      'callerXmppUsername': 'you',
      'mode': 'livekit',
      'group': 'false',
    };

void main() {
  group('call push parsing', () {
    test('recognises a call by marker, or by callId plus a call field', () {
      expect(looksLikeCallPush(<String, dynamic>{'type': 'incoming-call'}),
          isTrue);
      expect(looksLikeCallPush(<String, dynamic>{'pushType': 'CALL'}), isTrue);
      expect(
        looksLikeCallPush(
            <String, dynamic>{'callId': 'c', 'callKind': 'audio'}),
        isTrue,
      );
      expect(
        looksLikeCallPush(<String, dynamic>{'callid': 'c', 'kind': 'video'}),
        isTrue,
      );
      expect(looksLikeCallPush(<String, dynamic>{'callId': 'c'}), isFalse);
      expect(looksLikeCallPush(<String, dynamic>{'jid': 'room@conf'}), isFalse);
      expect(looksLikeCallPush(null), isFalse);
    });

    test('reads the field-name variations and the new mode / group fields', () {
      final p = parseCallPush(<String, dynamic>{
        'callID': 'c9',
        'livekitToken': jwt(<String, Object?>{'exp': 1760000060}),
        'callKind': 'audio',
        'roomJid': 'abc_123@conference.h/res',
        'senderName': 'Ann Lee',
        'senderJid': 'ann@h',
        'group': '1',
        'livekitUrl': 'wss://lk.example.com',
      });
      expect(p.callId, 'c9');
      expect(p.token, isNotEmpty);
      expect(p.kind, CallKind.audio);
      expect(p.roomBareName, 'abc_123');
      expect(p.roomRef, 'abc_123@conference.h/res');
      expect(p.callerName, 'Ann Lee');
      expect(p.callerXmppUsername, 'ann');
      expect(p.group, isTrue);
      expect(p.mode, CallMode.livekit);
      expect(p.livekitUrl, 'wss://lk.example.com');
      expect(p.exp, 1760000060000);
    });

    test('p2p is never a group; a raw id is never a caller name', () {
      final p = parseCallPush(<String, dynamic>{
        'callId': 'c',
        'mode': 'p2p',
        'group': 'true',
        'callerName': '0123456789abcdef01234567_0123456789abcdef01234567',
      });
      expect(p.mode, CallMode.p2p);
      expect(p.group, isFalse);
      expect(p.callerName, isEmpty);
      expect(p.exp, isNull);
    });

    test('token expiry has a little skew', () {
      expect(isCallTokenExpired(null), isFalse);
      expect(isCallTokenExpired(10000, nowMs: 11000), isFalse);
      expect(isCallTokenExpired(10000, nowMs: 12001), isTrue);
    });
  });

  group('handleCallPush', () {
    test('a p2p push rings with the pushed caller and reports ringing',
        () async {
      final s = Setup();
      expect(s.calls.handleCallPush(p2pPush()), isTrue);
      await s.settle();
      expect(s.state.isRingingIncoming, isTrue);
      expect(s.state.mode, CallMode.p2p);
      expect(s.state.callId, 'p1');
      expect(s.state.roomName, 'Ann Lee');
      expect(s.state.peerXmppUsername, 'you');
      expect(s.state.token, isEmpty);
      expect(s.api.reports, <String>['ringing:p1']);
      expect(s.p2pDeps.single.mediaCalls, 0, reason: 'rings before any media');
    });

    test('accepting joins: the offer the caller re-sends is answered',
        () async {
      final s = Setup();
      s.calls.handleCallPush(p2pPush(), accept: true);
      await s.settle();
      expect(s.state.phase, CallPhase.connecting);
      expect(s.p2pDeps.single.mediaCalls, 1);
      // The caller's offer lands after the app woke up.
      s.p2pSignalFromPeer(
        P2PSignalName.offer,
        const P2PSignalPayload.sdp('offer-sdp'),
      );
      await s.settle();
      expect(s.host.p2pSignals(), <String>['answer']);
      s.p2pDeps.single.pc.emitState(P2PConnState.connected);
      expect(s.state.phase, CallPhase.inCall);
    });

    test(
        'a cold start has no chat list: the room jid is built from the '
        'conference domain', () async {
      final s = Setup();
      s.host.rooms = <ChatRoom>[];
      s.calls.handleCallPush(p2pPush(room: 'app_user-other'));
      expect(s.state.roomJid, 'app_user-other@conference.xmpp.example.com');
      expect(s.state.roomBareName, 'app_user-other');
    });

    test('a livekit push rings with its token and joins with the config url',
        () async {
      final s = Setup();
      expect(s.calls.handleCallPush(lkPush(s), accept: true), isTrue);
      await s.settle();
      expect(s.state.phase, CallPhase.connecting);
      expect(s.state.kind, CallKind.audio);
      final session = s.sessions.single;
      expect(session.params.url, 'wss://lk.example.com');
      expect(session.params.kind, CallKind.audio);
      expect(s.api.reports, isEmpty, reason: 'no p2p reports for livekit');
    });

    test(
        'an expired livekit token cannot join: ignored, or an error when '
        'the user already pressed accept', () async {
      final s = Setup();
      final stale = lkPush(s, expMs: s.nowMs - 120000);
      expect(s.calls.handleCallPush(stale), isTrue);
      expect(s.state.isIdle, isTrue);
      expect(s.calls.handleCallPush(stale, accept: true), isTrue);
      expect(s.state.phase, CallPhase.error);
      expect(s.state.error, contains('already ended'));
      expect(s.sessions, isEmpty);
    });

    test('not consumed: calls off, not a call, nothing to join, public room',
        () async {
      final off = Setup(config: const VideoCallsConfig());
      expect(off.calls.handleCallPush(p2pPush()), isFalse);

      final s = Setup();
      expect(s.calls.handleCallPush(<String, dynamic>{'jid': 'x@y'}), isFalse);
      final noToken = lkPush(s)..['callToken'] = '';
      expect(s.calls.handleCallPush(noToken), isFalse);
      final noRoom = p2pPush()..remove('room');
      expect(s.calls.handleCallPush(noRoom), isFalse);

      s.host.rooms = <ChatRoom>[
        ...s.host.rooms,
        const ChatRoom(
          jid: 'lobby@conference.xmpp.example.com',
          title: 'Lobby',
          type: 'public',
          usersCnt: 40,
        ),
      ];
      final group = lkPush(s, room: 'lobby')..['group'] = 'true';
      expect(s.calls.handleCallPush(group), isFalse,
          reason: 'public rooms never call');
      expect(s.state.isIdle, isTrue);
    });

    test(
        'a push for the call already ringing (live token came first) is '
        'one ring; a busy line declines a new p2p call', () async {
      final s = Setup();
      s.p2pToken(callId: 'p1');
      await s.settle();
      final started = s.state.startedAt;
      expect(s.calls.handleCallPush(p2pPush(callId: 'p1')), isTrue);
      expect(s.state.startedAt, started);
      expect(s.p2pDeps, hasLength(1));

      s.calls.acceptIncoming();
      expect(s.calls.handleCallPush(p2pPush(callId: 'other')), isTrue);
      expect(s.api.reports, contains('decline:other'));
      expect(s.state.callId, 'p1');
    });

    test('the live token of a call that already rang by push is ignored',
        () async {
      final s = Setup();
      s.calls.handleCallPush(p2pPush(callId: 'p1'));
      await s.settle();
      s.p2pToken(callId: 'p1');
      s.lkToken(callId: 'p1');
      await s.settle();
      expect(s.api.reports.where((r) => r.startsWith('ringing')), hasLength(1));
      expect(s.p2pDeps, hasLength(1));
    });
  });

  group('native call UI', () {
    test(
        'a ring while the app is in the background is shown natively; '
        'accepting there joins', () async {
      final ui = FakeNativeUi();
      var resumed = false;
      final s = Setup(nativeUi: ui, appResumed: () => resumed);
      await s.calls.startNativeCallUi();
      s.p2pToken();
      await s.settle();
      expect(ui.log, <String>['incoming:p1']);

      ui.press(NativeCallEventType.accept, 'p1');
      await s.settle();
      expect(s.state.phase, CallPhase.connecting);
      expect(ui.log, <String>['incoming:p1'],
          reason: 'its own service already runs');
      resumed = true;
    });

    test('a cold start: the accept carries the push data and joins the call',
        () async {
      final ui = FakeNativeUi();
      final s = Setup(nativeUi: ui, appResumed: () => false);
      await s.calls.startNativeCallUi();
      ui.press(NativeCallEventType.accept, 'p1', extra: p2pPush());
      await s.settle();
      expect(s.state.phase, CallPhase.connecting);
      expect(s.state.callId, 'p1');
      expect(s.p2pDeps.single.mediaCalls, 1);
    });

    test(
        'a call the native layer kept across the launch rings in-app, and '
        'an accept already tapped joins', () async {
      final ui = FakeNativeUi()
        ..active = <NativeCallInfo>[
          NativeCallInfo(
            callId: 'p1',
            callerName: 'Ann Lee',
            kind: CallKind.video,
            accepted: true,
            extra: p2pPush(),
          ),
        ];
      final s = Setup(nativeUi: ui);
      await s.calls.startNativeCallUi();
      await s.settle();
      expect(s.state.phase, CallPhase.connecting);
    });

    test(
        'declining on the native UI declines the live ring, or tells the '
        'server about a push-only p2p call', () async {
      final ui = FakeNativeUi();
      final s = Setup(nativeUi: ui, appResumed: () => false);
      await s.calls.startNativeCallUi();
      s.p2pToken();
      await s.settle();
      ui.press(NativeCallEventType.decline, 'p1');
      await s.settle();
      expect(s.state.isIdle, isTrue);
      expect(s.api.reports, contains('decline:p1'));
      expect(s.host.sentOfType('call-state'), hasLength(1));

      final coldUi = FakeNativeUi();
      final c = Setup(nativeUi: coldUi);
      await c.calls.startNativeCallUi();
      coldUi.press(NativeCallEventType.decline, 'p7',
          extra: p2pPush(callId: 'p7'));
      expect(c.api.reports, <String>['decline:p7']);
    });

    test(
        'hanging up from the ongoing notification ends the call; a native '
        'ring timeout dismisses the ring', () async {
      final ui = FakeNativeUi();
      final s = Setup(nativeUi: ui);
      await s.calls.startNativeCallUi();
      s.p2pToken();
      s.calls.acceptIncoming();
      await s.settle();
      expect(ui.log, contains('ongoing:p1'));
      ui.press(NativeCallEventType.ended, 'p1');
      await s.settle();
      expect(s.state.isIdle, isTrue);
      expect(s.host.sentOfType('call-state'), isNotEmpty);

      s.p2pToken(callId: 'p2');
      await s.settle();
      ui.press(NativeCallEventType.timeout, 'p2');
      expect(s.state.isIdle, isTrue);
    });

    test('an unanswered ring dismisses itself', () async {
      final s = Setup(incomingRingTimeout: const Duration(milliseconds: 40));
      s.p2pToken();
      await s.settle();
      expect(s.state.isRingingIncoming, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(s.state.isIdle, isTrue);
    });
  });

  group('ringtone', () {
    test('rings while an incoming call rings, stops on accept', () async {
      final tones = FakeTonePlayer();
      final s = Setup(tonePlayer: tones);
      s.p2pToken();
      await s.settle();
      expect(tones.log, <String>['play:ringtone:speaker']);
      s.calls.acceptIncoming();
      await s.settle();
      expect(tones.log.last, 'stop');
    });

    test('ringback while dialling, until the callee answers', () async {
      final tones = FakeTonePlayer();
      final s = Setup(tonePlayer: tones);
      s.api.result = p2pCreated;
      await s.calls.startCall(s.host.rooms.first, CallKind.audio);
      await s.settle();
      expect(tones.log.first, 'play:ringback:earpiece',
          reason: 'an audio call rings back on the earpiece');
      s.p2pSignalFromPeer(
        P2PSignalName.answer,
        const P2PSignalPayload.sdp('a'),
      );
      await s.settle();
      expect(tones.log.last, 'stop');
    });

    test(
        'in the background the in-app ringtone stays silent (the native UI '
        'rings)', () async {
      final tones = FakeTonePlayer();
      final ui = FakeNativeUi();
      final s = Setup(tonePlayer: tones, nativeUi: ui, appResumed: () => false);
      s.p2pToken();
      await s.settle();
      expect(tones.log.where((l) => l.startsWith('play')), isEmpty);
      expect(ui.log, <String>['incoming:p1']);
    });
  });

  group('local call log', () {
    test('a connected call hung up here logs its duration once', () async {
      final s = Setup();
      s.api.result = p2pCreated;
      await s.calls.startCall(s.host.rooms.first, CallKind.video);
      await s.settle();
      s.p2pSignalFromPeer(
        P2PSignalName.answer,
        const P2PSignalPayload.sdp('a'),
      );
      await s.settle();
      s.p2pDeps.single.pc.emitState(P2PConnState.connected);
      s.nowMs += 12000;
      s.calls.hangup();
      await s.settle();

      final log = s.host.callLogs.single;
      expect(log.id, 'calllog-p1');
      expect(log.roomJid, roomJid);
      expect(log.system, isTrue);
      expect(log.data['durationMs'], '12000');
      expect(log.data['callerXmppUsername'], 'me');
      final info = CallLogInfo.fromMessage(log, selfXmppUsername: 'me')!;
      expect(info.outgoing, isTrue);
      expect(info.durationMs, 12000);
    });

    test('a missed incoming call logs "missed" with the caller as author',
        () async {
      final s = Setup();
      s.p2pToken();
      await s.settle();
      s.deliverXml(
        '<message from="you@xmpp.example.com" type="chat">'
        '<data type="call-state" state="cancelled" callId="p1" room="$roomName"/>'
        '</message>',
      );
      final log = s.host.callLogs.single;
      expect(log.data['durationMs'], '0');
      final info = CallLogInfo.fromMessage(log, selfXmppUsername: 'me')!;
      expect(info.outgoing, isFalse);
      expect(info.missed, isTrue);
    });

    test(
        'a call that never got an id or a connection is not logged, nor is '
        'a logout', () async {
      final s = Setup();
      s.api.gate = null;
      s.api.error = Exception('offline');
      await s.calls.startCall(s.host.rooms.first, CallKind.video);
      s.calls.dismissError();
      expect(s.host.callLogs, isEmpty);

      s.p2pToken();
      await s.settle();
      s.calls.reset();
      expect(s.host.callLogs, isEmpty);
    });
  });
}
