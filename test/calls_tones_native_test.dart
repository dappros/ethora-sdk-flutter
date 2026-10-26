import 'package:ethora_sdk_flutter/src/calls/call_mode.dart';
import 'package:ethora_sdk_flutter/src/calls/call_native_bridge.dart';
import 'package:ethora_sdk_flutter/src/calls/call_state.dart';
import 'package:ethora_sdk_flutter/src/calls/call_tones.dart';
import 'package:ethora_sdk_flutter/src/calls/native_call_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/calls_fakes.dart';

CallSessionState ringing(
        {String callId = 'c1', CallMode mode = CallMode.p2p}) =>
    CallSessionState.incoming(
      roomJid: 'r@c',
      roomBareName: 'r',
      roomName: 'Ann Lee',
      token: mode == CallMode.p2p ? '' : 'jwt',
      callId: callId,
      mode: mode,
      callerName: 'Ann Lee',
      callerXmppUsername: 'ann',
      nowMs: 1,
    );

CallSessionState dialling({CallMode mode = CallMode.p2p}) =>
    CallSessionState.startOutgoing(
      roomJid: 'r@c',
      roomBareName: 'r',
      roomName: 'Ann Lee',
      nowMs: 1,
    ).withOutgoingRoute(
      startedAt: 1,
      callId: 'o1',
      mode: mode,
      iceServers: const <IceServerConfig>[],
    );

void main() {
  group('desiredCallTone', () {
    CallTone? tone(
      CallSessionState s, {
      bool remoteJoined = false,
      bool appResumed = true,
      bool native = false,
    }) =>
        desiredCallTone(
          s,
          remoteJoined: remoteJoined,
          appResumed: appResumed,
          nativeIncomingShown: native,
        );

    test(
        'incoming: the ringtone only while the app is visible and no native '
        'ring is up', () {
      expect(tone(ringing()), CallTone.ringtone);
      expect(tone(ringing(), appResumed: false), isNull);
      expect(tone(ringing(), native: true), isNull);
      expect(tone(ringing().accepted(2)), isNull);
    });

    test('outgoing: ringback while dialling, until the callee answers', () {
      expect(tone(dialling()), CallTone.ringback);
      expect(tone(dialling().copyWith(phase: CallPhase.connecting)), isNull,
          reason: 'p2p: the answer ends the ringback');
      expect(tone(dialling().copyWith(phase: CallPhase.inCall)), isNull);
      expect(tone(dialling().withError('x', 2)), isNull);
    });

    test('a livekit call rings back until the first remote participant joins',
        () {
      final connecting = dialling(mode: CallMode.livekit)
          .copyWith(phase: CallPhase.connecting);
      expect(tone(connecting), CallTone.ringback);
      expect(tone(connecting, remoteJoined: true), isNull);
      expect(tone(connecting.copyWith(phase: CallPhase.inCall)),
          CallTone.ringback);
    });

    test('idle is silent', () {
      expect(tone(CallSessionState.idle), isNull);
    });
  });

  test(
      'CallToneDriver starts a tone once, stops it, and survives a failing '
      'player', () async {
    final player = FakeTonePlayer();
    final driver = CallToneDriver(player);
    driver.apply(CallTone.ringtone);
    driver.apply(CallTone.ringtone);
    driver.apply(CallTone.ringback, speaker: false);
    driver.apply(null);
    driver.apply(null);
    await pumpEventQueue();
    expect(player.log, <String>[
      'play:ringtone:speaker',
      'play:ringback:earpiece',
      'stop',
    ]);
    driver.dispose();
    driver.apply(CallTone.ringtone);
    await pumpEventQueue();
    expect(player.log.last, 'dispose');
    expect(player.log.where((l) => l.startsWith('play')), hasLength(2));

    final failing = CallToneDriver(_ThrowingPlayer(), log: (_) {});
    failing.apply(CallTone.ringtone);
    await pumpEventQueue();
    expect(failing.current, CallTone.ringtone);
  });

  group('callUuid', () {
    test('is a stable, well formed UUID', () {
      final a = callUuid('call-1');
      expect(a, callUuid('call-1'));
      expect(a, isNot(callUuid('call-2')));
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(a),
        isTrue,
        reason: a,
      );
      expect(callUuid(''), hasLength(36));
    });
  });

  group('CallNativeBridge', () {
    late FakeNativeUi ui;
    late bool resumed;
    late List<String> handled;
    late CallNativeBridge bridge;

    setUp(() {
      ui = FakeNativeUi();
      resumed = true;
      handled = <String>[];
      bridge = CallNativeBridge(
        ui: ui,
        appResumed: () => resumed,
        handlers: CallNativeHandlers(
          onAccept: (id, extra) => handled.add('accept:$id'),
          onDecline: (id, extra) => handled.add('decline:$id'),
          onEnded: (id) => handled.add('ended:$id'),
          onTimeout: (id) => handled.add('timeout:$id'),
          onRestored: (extra) => handled.add('restored:${extra['callId']}'),
        ),
      );
    });

    test('a ring in the foreground stays in-app', () async {
      await bridge.start();
      bridge.onStateChanged(ringing());
      expect(ui.log, isEmpty);
      expect(bridge.isRingingNatively('c1'), isFalse);
    });

    test(
        'a ring in the background goes native once, and the app coming to '
        'the foreground mid-ring does not double it', () async {
      resumed = false;
      await bridge.start();
      bridge.onStateChanged(ringing());
      bridge.onStateChanged(ringing());
      expect(ui.log, <String>['incoming:c1']);
      expect(bridge.isRingingNatively('c1'), isTrue);
    });

    test('a ring that is up when the app backgrounds moves to the native UI',
        () async {
      await bridge.start();
      final s = ringing();
      bridge.onStateChanged(s);
      expect(ui.log, isEmpty);
      resumed = false;
      bridge.onLifecycleChanged(s);
      expect(ui.log, <String>['incoming:c1']);
    });

    test(
        'accepting in-app dismisses the native ring and keeps the process '
        'alive; connecting reports connected', () async {
      resumed = false;
      await bridge.start();
      bridge.onStateChanged(ringing());
      resumed = true;
      final accepted = ringing().accepted(2);
      bridge.onStateChanged(accepted);
      expect(ui.log, <String>['incoming:c1', 'end:c1', 'ongoing:c1']);
      bridge.onStateChanged(accepted.connected(3));
      bridge.onStateChanged(accepted.connected(3));
      expect(ui.log.last, 'connected:c1');
      expect(ui.log.where((l) => l == 'connected:c1'), hasLength(1));
      // The echo of our own end() is not the user hanging up.
      ui.press(NativeCallEventType.ended, 'c1');
      expect(handled, isEmpty);
    });

    test(
        'accepting on the native UI drives the call and does not restart '
        'its service', () async {
      resumed = false;
      await bridge.start();
      bridge.onStateChanged(ringing());
      ui.press(NativeCallEventType.accept, 'c1');
      expect(handled, <String>['accept:c1']);
      bridge.onStateChanged(ringing().accepted(2));
      expect(ui.log, <String>['incoming:c1'],
          reason: 'the plugin already runs the ongoing service');
      bridge.onStateChanged(ringing().accepted(2).connected(3));
      expect(ui.log.last, 'connected:c1');
    });

    test(
        'decline, timeout and a hang-up from the ongoing notification are '
        'forwarded', () async {
      await bridge.start();
      ui.press(NativeCallEventType.decline, 'c1');
      ui.press(NativeCallEventType.timeout, 'c2');
      ui.press(NativeCallEventType.ended, 'c3');
      expect(handled, <String>['decline:c1', 'timeout:c2', 'ended:c3']);
      // A call this SDK did not report (no callId in extra) is ignored.
      ui.press(NativeCallEventType.accept, '');
      expect(handled, hasLength(3));
    });

    test(
        'an outgoing call starts the ongoing service once it is being set '
        'up, and ends it with the call', () async {
      await bridge.start();
      final d = dialling();
      bridge.onStateChanged(d);
      expect(ui.log, isEmpty, reason: 'dialling needs no service yet');
      final connecting = d.copyWith(phase: CallPhase.connecting);
      bridge.onStateChanged(connecting);
      bridge.onStateChanged(connecting);
      expect(ui.log, <String>['ongoing:o1']);
      bridge.onStateChanged(CallSessionState.idle);
      expect(ui.log.last, 'end:o1');
      bridge.onStateChanged(CallSessionState.idle);
      expect(ui.log.where((l) => l == 'end:o1'), hasLength(1));
    });

    test('a failed call dismisses the native UI', () async {
      resumed = false;
      await bridge.start();
      final s = ringing();
      bridge.onStateChanged(s);
      bridge.onStateChanged(s.withError('boom', 2));
      expect(ui.log, <String>['incoming:c1', 'end:c1']);
    });

    test('calls the native layer kept across a cold start are restored',
        () async {
      ui.active = <NativeCallInfo>[
        const NativeCallInfo(
          callId: 'accepted1',
          callerName: 'A',
          kind: CallKind.video,
          accepted: true,
          extra: <String, dynamic>{'callId': 'accepted1'},
        ),
        const NativeCallInfo(
          callId: 'ringing1',
          callerName: 'B',
          kind: CallKind.audio,
          extra: <String, dynamic>{'callId': 'ringing1'},
        ),
      ];
      await bridge.start();
      expect(handled, <String>['accept:accepted1', 'restored:ringing1']);
    });

    test('a native layer that throws never breaks the call', () async {
      final bad = CallNativeBridge(
        ui: _ThrowingUi(),
        appResumed: () => false,
        handlers: CallNativeHandlers(
          onAccept: (a, b) {},
          onDecline: (a, b) {},
          onEnded: (a) {},
          onTimeout: (a) {},
          onRestored: (a) {},
        ),
        log: (_) {},
      );
      await bad.start();
      bad.onStateChanged(ringing());
      await pumpEventQueue();
    });
  });
}

class _ThrowingPlayer implements CallTonePlayer {
  @override
  Future<void> play(CallTone tone, {required bool speaker}) =>
      Future<void>.error(StateError('no audio'));
  @override
  Future<void> stop() => Future<void>.error(StateError('no audio'));
  @override
  Future<void> dispose() => Future<void>.error(StateError('no audio'));
}

class _ThrowingUi implements NativeCallUi {
  @override
  Stream<NativeCallEvent> get events => const Stream<NativeCallEvent>.empty();
  @override
  Future<void> showIncoming(NativeCallInfo info) =>
      Future<void>.error(StateError('x'));
  @override
  Future<void> startOngoing(NativeCallInfo info) =>
      Future<void>.error(StateError('x'));
  @override
  Future<void> markConnected(NativeCallInfo info) =>
      Future<void>.error(StateError('x'));
  @override
  Future<void> end(NativeCallInfo info) => Future<void>.error(StateError('x'));
  @override
  Future<List<NativeCallInfo>> activeCalls() =>
      Future<List<NativeCallInfo>>.error(StateError('x'));
}
