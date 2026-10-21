import 'package:ethora_sdk_flutter/src/calls/call_mode.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_call_controller.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_ice_policy.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_negotiator.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_signal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/calls_fakes.dart';

class Harness {
  Harness({
    P2PRole role = P2PRole.caller,
    CallKind kind = CallKind.video,
    bool startWithMicOn = true,
    bool startWithCameraOn = true,
    List<IceServerConfig> ice = const <IceServerConfig>[
      IceServerConfig(urls: <String>['turn:t.example.com'], username: 'u'),
    ],
  }) {
    controller = P2PCallController(
      params: P2PCallParams(
        callId: 'c1',
        role: role,
        kind: kind,
        peerLocal: 'peer',
        iceServers: ice,
        startWithMicOn: startWithMicOn,
        startWithCameraOn: startWithCameraOn,
      ),
      deps: deps,
      scheduler: scheduler.call,
      events: P2PCallEvents(
        onNegotiated: () => events.add('negotiated'),
        onConnected: () => events.add('connected'),
        onRemoteEnd: (reason) => events.add('remoteEnd:$reason'),
        onFailed: (message) => events.add('failed:$message'),
        onDisposed: ({required bool started}) =>
            events.add('disposed:$started'),
      ),
    );
  }

  final FakeP2pDeps deps = FakeP2pDeps();
  final ManualScheduler scheduler = ManualScheduler();
  final List<String> events = <String>[];
  late final P2PCallController controller;

  Future<void> start() async {
    await controller.start();
    await pumpEventQueue();
  }

  void feed(P2PSignalName name, P2PSignalPayload payload,
      {String from = 'peer'}) {
    controller.receive(
      P2PSignal(
        callId: 'c1',
        signal: name,
        payload: payload,
        fromBare: '$from@host',
        fromLocal: from,
      ),
    );
  }

  Future<void> settle() => pumpEventQueue();
}

void main() {
  group('caller', () {
    test('offers, sends candidates after the offer, connects, hangs up clean',
        () async {
      final h = Harness();
      await h.start();

      expect(h.controller.snapshot.status, P2PStatus.waiting);
      expect(h.deps.servers.single.single.urls, <String>['turn:t.example.com']);
      expect(h.deps.iceFetches, 0, reason: 'ice came with the call');
      expect(h.deps.pc.calls, <String>[
        'addTrack:audio',
        'addTrack:video',
        'createOffer',
        'setLocal:offer',
      ]);
      expect(h.deps.signalNames(), <String>['offer']);

      // A candidate gathered now goes out after the offer, never before it.
      h.deps.pc.emitCandidate('candidate:1');
      expect(h.deps.signalNames(), <String>['offer', 'candidate']);

      // The answer completes the exchange.
      h.feed(
          P2PSignalName.answer, const P2PSignalPayload.sdp('answer-from-peer'));
      await h.settle();
      expect(h.deps.pc.remote, 'answer-from-peer');
      expect(h.controller.snapshot.status, P2PStatus.connecting);
      expect(h.events, <String>['negotiated']);

      h.feed(
        P2PSignalName.candidate,
        const P2PSignalPayload.candidate(
            P2PCandidate(candidate: 'remote-cand')),
      );
      await h.settle();
      expect(h.deps.pc.remoteCandidates.single.candidate, 'remote-cand');

      h.deps.pc.emitState(P2PConnState.connected);
      expect(h.controller.snapshot.status, P2PStatus.connected);
      expect(h.events, <String>['negotiated', 'connected']);
      expect(h.scheduler.pendingCount, 0, reason: 'connect timer cancelled');

      h.controller.hangup();
      await h.settle();
      expect(h.deps.signalNames().last, 'end');
      expect(h.deps.signals.last.payload.reason, 'hangup');
      expect(h.deps.pc.closed, isTrue);
      expect(
        h.deps.localStreams.single.tracks
            .every((t) => (t as FakeTrack).stopped),
        isTrue,
        reason: 'camera and microphone released',
      );
      expect(h.events.last, 'disposed:true');
      expect(h.controller.snapshot.status, P2PStatus.ended);
      expect(h.controller.snapshot.localStream, isNull);
    });

    test('without ice servers on the call it fetches fresh ones', () async {
      final h = Harness(ice: const <IceServerConfig>[]);
      await h.start();
      expect(h.deps.iceFetches, 1);
      expect(h.deps.servers.single.single.urls,
          <String>['turn:fresh.example.com']);
    });

    test('re-sends the offer and candidates while unanswered, then stops',
        () async {
      final h = Harness();
      await h.start();
      h.deps.pc.emitCandidate('candidate:1');
      expect(h.deps.signalNames(), <String>['offer', 'candidate']);

      h.scheduler.advance(4000);
      expect(h.deps.signalNames(), <String>[
        'offer',
        'candidate',
        'offer',
        'candidate',
      ]);

      h.feed(P2PSignalName.answer, const P2PSignalPayload.sdp('a'));
      await h.settle();
      final before = h.deps.signals.length;
      h.scheduler.advance(10000);
      expect(h.deps.signals.length, before,
          reason: 'answered: no more resends');
    });

    test('an answer from a stranger or for another call is ignored', () async {
      final h = Harness();
      await h.start();
      h.feed(P2PSignalName.answer, const P2PSignalPayload.sdp('a'),
          from: 'eve');
      await h.settle();
      expect(h.deps.pc.remote, isNull);
      expect(h.events, isEmpty);
    });

    test('times out when media never connects after the exchange', () async {
      final h = Harness();
      await h.start();
      h.feed(P2PSignalName.answer, const P2PSignalPayload.sdp('a'));
      await h.settle();
      h.scheduler.advance(24000);
      expect(h.events, <String>['negotiated']);
      h.scheduler.advance(2000);
      await h.settle();
      expect(h.events, contains('failed:Could not connect the call'));
      expect(h.deps.signals.last.payload.reason, 'connect-timeout');
      expect(h.deps.pc.closed, isTrue);
      expect(h.controller.snapshot.status, P2PStatus.failed);
    });

    test('an audio call opens no camera and adds no video section', () async {
      final h = Harness(kind: CallKind.audio);
      await h.start();
      expect(h.deps.localStreams.single.videoTracks, isEmpty);
      expect(h.deps.pc.calls, isNot(contains('addTrack:video')));
      expect(h.deps.pc.calls, isNot(contains('addVideoTransceiver')));
      expect(h.controller.snapshot.camEnabled, isFalse);
      expect(h.deps.speaker, <bool>[false], reason: 'audio call: earpiece');
      await h.controller.toggleCamera();
      expect(h.deps.mediaCalls, 1, reason: 'camera toggle is video only');
    });

    test('a video call starts on the loudspeaker; the mic can start muted',
        () async {
      final h = Harness(startWithMicOn: false);
      await h.start();
      expect(h.deps.speaker, <bool>[true]);
      expect(h.controller.snapshot.micEnabled, isFalse);
      expect(
        (h.deps.localStreams.single.audioTracks.single as FakeTrack).enabled,
        isFalse,
      );
      h.controller.toggleMic();
      expect(h.controller.snapshot.micEnabled, isTrue);
      await h.controller.setSpeaker(false);
      expect(h.controller.snapshot.speakerOn, isFalse);
    });
  });

  group('callee', () {
    test('holds an early offer and candidates until it starts, then answers',
        () async {
      final h = Harness(role: P2PRole.callee);
      // Everything arrives while the ring screen is still up.
      h.feed(
          P2PSignalName.offer, const P2PSignalPayload.sdp('offer-from-peer'));
      h.feed(
        P2PSignalName.candidate,
        const P2PSignalPayload.candidate(P2PCandidate(candidate: 'early-cand')),
      );
      await h.settle();
      expect(h.deps.peers, isEmpty, reason: 'no connection before Accept');
      expect(h.deps.mediaCalls, 0);

      await h.start();
      expect(h.deps.pc.calls, <String>[
        'addTrack:audio',
        'addTrack:video',
        'setRemote:offer',
        'addCandidate:early-cand',
        'createAnswer',
        'setLocal:answer',
      ]);
      expect(h.deps.signalNames(), <String>['answer']);
      expect(h.controller.snapshot.status, P2PStatus.connecting);
      expect(h.events, <String>['negotiated']);

      h.deps.pc.emitCandidate('mine');
      expect(h.deps.signalNames(), <String>['answer', 'candidate']);
      h.deps.pc.emitState(P2PConnState.connected);
      expect(h.events.last, 'connected');
    });

    test('a callee that never accepted disposes quietly (no end signal)',
        () async {
      final h = Harness(role: P2PRole.callee);
      h.feed(P2PSignalName.offer, const P2PSignalPayload.sdp('o'));
      h.controller.dispose();
      expect(h.deps.signals, isEmpty);
      expect(h.events, <String>['disposed:false']);
      h.controller.dispose();
      expect(h.events, <String>['disposed:false'], reason: 'idempotent');
    });

    test('the caller cancelling before Accept ends the call without media',
        () async {
      final h = Harness(role: P2PRole.callee);
      h.feed(P2PSignalName.end, const P2PSignalPayload.end('hangup'));
      expect(h.events, <String>['remoteEnd:hangup', 'disposed:false']);
      expect(h.deps.signals, isEmpty);
      await h.controller.start();
      expect(h.deps.mediaCalls, 0);
    });
  });

  group('failure paths', () {
    test('a denied camera or microphone fails the call and tells the peer',
        () async {
      final h = Harness();
      h.deps.mediaError = StateError('NotAllowedError: Permission denied');
      await h.start();
      expect(h.events, <String>[
        'failed:Camera or microphone permission denied',
        'disposed:true',
      ]);
      expect(h.deps.signalNames(), <String>['end']);
      expect(h.deps.signals.single.payload.reason, 'media-error');
      expect(h.deps.peers, isEmpty);
    });

    test('describeMediaError and remoteEndNotice map the known reasons', () {
      expect(describeMediaError('NotFoundError'), contains('No camera'));
      expect(
          describeMediaError('NotReadableError'), contains('already in use'));
      expect(describeMediaError('boom'),
          'Could not access your camera or microphone');
      expect(remoteEndNotice('media-error'), contains('other person'));
      expect(remoteEndNotice('connect-timeout'),
          'The call could not be connected');
      expect(remoteEndNotice('hangup'), isNull);
    });

    test('the peer ending the call closes everything without an echo',
        () async {
      final h = Harness();
      await h.start();
      h.feed(P2PSignalName.end, const P2PSignalPayload.end('hangup'));
      await h.settle();
      expect(h.events, <String>['remoteEnd:hangup', 'disposed:true']);
      expect(h.deps.signalNames(), <String>['offer'], reason: 'no echoed end');
      expect(h.deps.pc.closed, isTrue);
    });

    test('an end that arrives while the permission prompt is open still wins',
        () async {
      final h = Harness();
      final starting = h.controller.start();
      h.feed(P2PSignalName.end, const P2PSignalPayload.end());
      await starting;
      await h.settle();
      expect(h.events.first, 'remoteEnd:ended');
      expect(h.deps.peers, isEmpty);
      expect(
        h.deps.localStreams.single.tracks
            .every((t) => (t as FakeTrack).stopped),
        isTrue,
        reason: 'media opened after the end is released again',
      );
    });

    test('a stale remote candidate is harmless', () async {
      final h = Harness();
      await h.start();
      h.feed(P2PSignalName.answer, const P2PSignalPayload.sdp('a'));
      await h.settle();
      h.deps.pc.failAddCandidate = true;
      h.feed(
        P2PSignalName.candidate,
        const P2PSignalPayload.candidate(P2PCandidate(candidate: 'x')),
      );
      await h.settle();
      expect(h.controller.snapshot.status, P2PStatus.connecting,
          reason: 'a stale candidate is harmless');
    });
  });

  group('connection health', () {
    Future<Harness> connected() async {
      final h = Harness();
      await h.start();
      h.feed(P2PSignalName.answer, const P2PSignalPayload.sdp('a'));
      await h.settle();
      h.deps.pc.emitState(P2PConnState.connected);
      return h;
    }

    test('a blip that heals within the grace period does nothing', () async {
      final h = await connected();
      h.deps.pc.emitState(P2PConnState.disconnected);
      expect(h.controller.snapshot.status, P2PStatus.reconnecting);
      h.scheduler.advance(2000);
      h.deps.pc.emitState(P2PConnState.connected);
      h.scheduler.advance(10000);
      await h.settle();
      expect(h.controller.snapshot.status, P2PStatus.connected);
      expect(h.deps.pc.calls, isNot(contains('restartIce')));
    });

    test('a lasting outage restarts ICE with fresh credentials', () async {
      final h = await connected();
      h.deps.pc.emitState(P2PConnState.disconnected);
      h.scheduler.advance(3000);
      await h.settle();
      expect(h.deps.iceFetches, 1);
      expect(h.deps.pc.iceServers!.single.urls,
          <String>['turn:fresh.example.com']);
      expect(
        h.deps.pc.calls.skipWhile((c) => c != 'setIceServers').toList(),
        <String>[
          'setIceServers',
          'restartIce',
          'createOffer:restart',
          'setLocal:offer'
        ],
      );
      expect(h.deps.signalNames().last, 'offer');

      // The restart answer arrives and media recovers.
      h.feed(P2PSignalName.answer, const P2PSignalPayload.sdp('a2'));
      await h.settle();
      h.deps.pc.emitState(P2PConnState.connected);
      expect(h.controller.snapshot.status, P2PStatus.connected);
      h.scheduler.advance(30000);
      await h.settle();
      expect(h.controller.snapshot.status, P2PStatus.connected,
          reason: 'recovered before the restart deadline');
    });

    test(
        'failed restarts straight away; a restart that never recovers gives up',
        () async {
      final h = await connected();
      h.deps.pc.emitState(P2PConnState.failed);
      await h.settle();
      expect(h.deps.pc.calls, contains('restartIce'));
      h.scheduler.advance(15000);
      await h.settle();
      expect(h.events, contains('failed:Connection lost'));
      expect(h.deps.signals.last.payload.reason, 'connection-failed');
      expect(h.controller.snapshot.status, P2PStatus.failed);
    });

    test('a restart is skipped while another negotiation is in flight',
        () async {
      final h = await connected();
      h.deps.pc.signaling = 'have-remote-offer';
      h.deps.pc.emitState(P2PConnState.failed);
      await h.settle();
      expect(h.deps.pc.calls, isNot(contains('restartIce')));
    });
  });

  group('camera', () {
    test('off releases the device, on opens it again and swaps it in',
        () async {
      final h = Harness();
      await h.start();
      final firstVideo =
          h.deps.localStreams.single.videoTracks.single as FakeTrack;
      expect(h.controller.snapshot.camEnabled, isTrue);

      await h.controller.toggleCamera();
      expect(firstVideo.stopped, isTrue, reason: 'camera light goes out');
      expect(h.deps.pc.senders.last.track, isNull);
      expect(h.controller.snapshot.camEnabled, isFalse);

      await h.controller.toggleCamera();
      expect(h.deps.mediaCalls, 2);
      final newVideo = h.deps.pc.senders.last.track!;
      expect(newVideo, isNot(same(firstVideo)));
      expect(h.controller.snapshot.camEnabled, isTrue);

      await h.controller.flipCamera();
      expect((h.deps.pc.senders.last.track)!.flips, 1);
    });

    test('a call that starts with the camera off keeps a video section',
        () async {
      final h = Harness(startWithCameraOn: false);
      await h.start();
      expect(h.deps.pc.calls, contains('addVideoTransceiver'));
      expect(h.controller.snapshot.camEnabled, isFalse);
      await h.controller.toggleCamera();
      expect(h.controller.snapshot.camEnabled, isTrue);
      expect(h.deps.pc.senders.last.track, isNotNull);
    });

    test('a refused camera shows a dismissible notice, not a failed call',
        () async {
      final h = Harness();
      await h.start();
      await h.controller.toggleCamera(); // off
      h.deps.mediaError = StateError('NotAllowedError');
      await h.controller.toggleCamera(); // on, refused
      expect(h.controller.snapshot.notice, contains('permission denied'));
      expect(h.controller.snapshot.status, isNot(P2PStatus.failed));
      h.controller.dismissNotice();
      expect(h.controller.snapshot.notice, isNull);
    });
  });

  group('remote video', () {
    test('tracks the remote video track mute state', () async {
      final h = Harness();
      await h.start();
      final video = FakeTrack('video');
      final stream = FakeStream(<FakeTrack>[video]);
      h.deps.pc.onRemoteTrack!(video, stream);
      expect(h.controller.snapshot.remoteStream, same(stream));
      expect(h.controller.snapshot.remoteVideoLive, isTrue);
      video.isMuted = true;
      video.onStateChanged!();
      expect(h.controller.snapshot.remoteVideoLive, isFalse);
    });
  });

  test('listeners are notified and removed', () async {
    final h = Harness();
    var calls = 0;
    final remove = h.controller.subscribe(() => calls++);
    await h.start();
    expect(calls, greaterThan(0));
    remove();
    final seen = calls;
    h.controller.toggleMic();
    expect(calls, seen);
  });
}
