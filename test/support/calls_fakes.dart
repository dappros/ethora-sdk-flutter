import 'dart:async';

import 'package:ethora_sdk_flutter/src/calls/call_mode.dart';
import 'package:ethora_sdk_flutter/src/calls/call_tones.dart';
import 'package:ethora_sdk_flutter/src/calls/native_call_ui.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_ice_policy.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_ports.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_signal.dart';

/// Timers you fire by hand: no real waiting in call tests.
class ManualScheduler {
  int now = 0;
  final List<_Pending> _pending = <_Pending>[];

  P2PTimerHandle call(Duration delay, void Function() action) {
    final pending = _Pending(now + delay.inMilliseconds, action);
    _pending.add(pending);
    return pending;
  }

  int get pendingCount => _pending.where((p) => !p.cancelled).length;

  /// Runs every timer due within [ms], in order, advancing the clock.
  void advance(int ms) {
    final target = now + ms;
    while (true) {
      final due = _pending.where((p) => !p.cancelled && p.at <= target).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final next = due.first;
      now = next.at;
      next.cancelled = true;
      next.action();
    }
    now = target;
  }
}

class _Pending implements P2PTimerHandle {
  _Pending(this.at, this.action);
  final int at;
  final void Function() action;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

class FakeTrack implements P2PTrack {
  FakeTrack(this.kind);

  @override
  final String kind;
  @override
  bool enabled = true;
  @override
  bool isLive = true;
  @override
  bool isMuted = false;
  @override
  void Function()? onStateChanged;
  bool stopped = false;
  int flips = 0;

  @override
  Future<void> stop() async {
    stopped = true;
    isLive = false;
  }

  @override
  Future<void> switchCamera() async => flips++;
}

class FakeStream implements P2PStream {
  FakeStream(List<FakeTrack> initial) : _tracks = List<FakeTrack>.of(initial);
  final List<FakeTrack> _tracks;

  @override
  List<P2PTrack> get audioTracks =>
      _tracks.where((t) => t.kind == 'audio').toList();
  @override
  List<P2PTrack> get videoTracks =>
      _tracks.where((t) => t.kind == 'video').toList();
  @override
  List<P2PTrack> get tracks => List<P2PTrack>.of(_tracks);

  @override
  Future<void> addTrack(P2PTrack track) async =>
      _tracks.add(track as FakeTrack);

  @override
  Future<void> removeTrack(P2PTrack track) async => _tracks.remove(track);

  @override
  Object get native => this;
}

class FakePeerConnection implements P2PPeerConnection {
  final List<String> calls = <String>[];
  final List<P2PCandidate> remoteCandidates = <P2PCandidate>[];
  final List<FakeSender> senders = <FakeSender>[];
  String signaling = 'stable';
  String? local;
  String? remote;
  bool closed = false;
  bool failAddCandidate = false;
  List<IceServerConfig>? iceServers;
  int _sdpCounter = 0;

  @override
  P2PConnState connectionState = P2PConnState.newState;

  @override
  bool get isStable => signaling == 'stable';

  @override
  bool get hasLocalOffer => signaling == 'have-local-offer';

  @override
  void Function(P2PCandidate candidate)? onCandidate;
  @override
  void Function(P2PTrack track, P2PStream stream)? onRemoteTrack;
  @override
  void Function()? onStateChanged;

  void emitState(P2PConnState state) {
    connectionState = state;
    onStateChanged?.call();
  }

  void emitCandidate(String text) => onCandidate?.call(
        P2PCandidate(candidate: text, sdpMid: '0', sdpMLineIndex: 0),
      );

  @override
  Future<String> createOffer({bool iceRestart = false}) async {
    calls.add(iceRestart ? 'createOffer:restart' : 'createOffer');
    return 'offer-sdp-${++_sdpCounter}';
  }

  @override
  Future<String> createAnswer() async {
    calls.add('createAnswer');
    return 'answer-sdp-${++_sdpCounter}';
  }

  @override
  Future<void> setLocalDescription(String type, String sdp) async {
    calls.add('setLocal:$type');
    local = sdp;
    signaling = type == 'offer' ? 'have-local-offer' : 'stable';
  }

  @override
  Future<void> rollbackLocal() async {
    calls.add('rollback');
    signaling = 'stable';
  }

  @override
  Future<void> setRemoteDescription(String type, String sdp) async {
    calls.add('setRemote:$type');
    remote = sdp;
    signaling = type == 'offer' ? 'have-remote-offer' : 'stable';
  }

  @override
  Future<String?> localSdp() async => local;

  @override
  Future<void> addCandidate(P2PCandidate candidate) async {
    if (failAddCandidate) throw StateError('stale candidate');
    calls.add('addCandidate:${candidate.candidate}');
    remoteCandidates.add(candidate);
  }

  @override
  Future<P2PSender> addTrack(P2PTrack track, P2PStream stream) async {
    calls.add('addTrack:${track.kind}');
    final sender = FakeSender(track as FakeTrack);
    senders.add(sender);
    return P2PSender(sender.replace);
  }

  @override
  Future<P2PSender> addVideoTransceiver() async {
    calls.add('addVideoTransceiver');
    final sender = FakeSender(null);
    senders.add(sender);
    return P2PSender(sender.replace);
  }

  @override
  Future<void> restartIce() async => calls.add('restartIce');

  @override
  Future<void> setIceServers(List<IceServerConfig> servers) async {
    calls.add('setIceServers');
    iceServers = servers;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class FakeSender {
  FakeSender(this.track);
  FakeTrack? track;

  Future<void> replace(P2PTrack? next) async => track = next as FakeTrack?;
}

class SentSignal {
  SentSignal(this.name, this.payload);
  final P2PSignalName name;
  final P2PSignalPayload payload;
}

class FakeP2pDeps implements P2PCallDeps {
  final List<FakePeerConnection> peers = <FakePeerConnection>[];
  final List<SentSignal> signals = <SentSignal>[];
  final List<FakeStream> localStreams = <FakeStream>[];
  final List<List<IceServerConfig>> servers = <List<IceServerConfig>>[];
  final List<bool> speaker = <bool>[];
  Object? mediaError;
  int mediaCalls = 0;
  int iceFetches = 0;
  List<IceServerConfig>? fetchedIce = const <IceServerConfig>[
    IceServerConfig(urls: <String>['turn:fresh.example.com'], username: 'u'),
  ];

  FakePeerConnection get pc => peers.last;

  List<String> signalNames() => signals.map((s) => s.name.name).toList();

  @override
  Future<P2PPeerConnection> createPeerConnection(
    List<IceServerConfig> list,
  ) async {
    servers.add(list);
    final peer = FakePeerConnection();
    peers.add(peer);
    return peer;
  }

  @override
  Future<P2PStream> getUserMedia({
    required bool audio,
    required bool video,
  }) async {
    mediaCalls++;
    final error = mediaError;
    if (error != null) throw error;
    final stream = FakeStream(<FakeTrack>[
      if (audio) FakeTrack('audio'),
      if (video) FakeTrack('video'),
    ]);
    localStreams.add(stream);
    return stream;
  }

  @override
  Future<List<IceServerConfig>?> fetchIceServers() async {
    iceFetches++;
    return fetchedIce;
  }

  @override
  void sendSignal(P2PSignalName signal, P2PSignalPayload payload) =>
      signals.add(SentSignal(signal, payload));

  @override
  Future<void> setSpeakerphone(bool on) async => speaker.add(on);

  @override
  void log(String message, [Object? detail]) {}
}

/// Records what the coordinator asks of the native call UI and lets a test
/// press its buttons.
class FakeNativeUi implements NativeCallUi {
  final StreamController<NativeCallEvent> _events =
      StreamController<NativeCallEvent>.broadcast(sync: true);
  final List<String> log = <String>[];
  List<NativeCallInfo> active = <NativeCallInfo>[];

  @override
  Stream<NativeCallEvent> get events => _events.stream;

  @override
  Future<void> showIncoming(NativeCallInfo info) async =>
      log.add('incoming:${info.callId}');
  @override
  Future<void> startOngoing(NativeCallInfo info) async =>
      log.add('ongoing:${info.callId}');
  @override
  Future<void> markConnected(NativeCallInfo info) async =>
      log.add('connected:${info.callId}');
  @override
  Future<void> end(NativeCallInfo info) async => log.add('end:${info.callId}');
  @override
  Future<List<NativeCallInfo>> activeCalls() async => active;

  /// The user pressed a button on the native UI.
  void press(
    NativeCallEventType type,
    String callId, {
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) {
    _events.add(
      NativeCallEvent(
        type: type,
        uuid: callUuid(callId),
        callId: callId,
        extra: <String, dynamic>{...extra, 'callId': callId},
      ),
    );
  }
}

class FakeTonePlayer implements CallTonePlayer {
  final List<String> log = <String>[];

  @override
  Future<void> play(CallTone tone, {required bool speaker}) async =>
      log.add('play:${tone.name}:${speaker ? 'speaker' : 'earpiece'}');
  @override
  Future<void> stop() async => log.add('stop');
  @override
  Future<void> dispose() async => log.add('dispose');
}
