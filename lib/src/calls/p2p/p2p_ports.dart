// The seams between the p2p call controller and the platform WebRTC stack.
//
// The controller never imports flutter_webrtc: it talks to these small
// abstractions, so the whole negotiation (offer/answer, candidates, ICE
// restart, camera toggling, teardown) runs under a fake connection in unit
// tests. p2p_webrtc.dart holds the one real implementation.

import 'dart:async';

import '../call_mode.dart';
import 'p2p_ice_policy.dart';
import 'p2p_signal.dart';

/// One local or remote media track.
abstract class P2PTrack {
  /// `audio` or `video`.
  String get kind;
  bool get enabled;
  set enabled(bool value);

  /// The track is still delivering (not ended).
  bool get isLive;

  /// The remote end is not sending right now (RTCTrack `muted`).
  bool get isMuted;

  /// Called when the track is muted, unmuted or ended.
  void Function()? onStateChanged;

  Future<void> stop();

  /// Front/back camera flip (video tracks only).
  Future<void> switchCamera();
}

/// A set of tracks that is rendered or sent together.
abstract class P2PStream {
  List<P2PTrack> get audioTracks;
  List<P2PTrack> get videoTracks;
  List<P2PTrack> get tracks;
  Future<void> addTrack(P2PTrack track);
  Future<void> removeTrack(P2PTrack track);

  /// The platform object (a flutter_webrtc `MediaStream`) the video widget
  /// renders. Opaque to the controller.
  Object get native;
}

class P2PSender {
  P2PSender(this._replaceTrack);
  final Future<void> Function(P2PTrack? track) _replaceTrack;

  Future<void> replaceTrack(P2PTrack? track) => _replaceTrack(track);
}

/// The slice of RTCPeerConnection the controller uses.
abstract class P2PPeerConnection {
  /// Current state mapped to [P2PConnState] (falls back to the ICE state on
  /// platforms that do not report a connection state).
  P2PConnState get connectionState;

  /// Signalling state is `stable` (no negotiation in flight).
  bool get isStable;

  /// Signalling state is `have-local-offer`.
  bool get hasLocalOffer;

  void Function(P2PCandidate candidate)? onCandidate;

  /// A remote track arrived; [stream] is the stream it belongs to.
  void Function(P2PTrack track, P2PStream stream)? onRemoteTrack;

  /// The connection or ICE state changed.
  void Function()? onStateChanged;

  Future<String> createOffer({bool iceRestart = false});
  Future<String> createAnswer();
  Future<void> setLocalDescription(String type, String sdp);
  Future<void> rollbackLocal();
  Future<void> setRemoteDescription(String type, String sdp);

  /// The SDP the connection is actually using (it carries gathered
  /// candidates), null when none is set.
  Future<String?> localSdp();
  Future<void> addCandidate(P2PCandidate candidate);
  Future<P2PSender> addTrack(P2PTrack track, P2PStream stream);

  /// A send+receive video section with no track yet, so the camera can be
  /// turned on later without renegotiating.
  Future<P2PSender> addVideoTransceiver();
  Future<void> restartIce();
  Future<void> setIceServers(List<IceServerConfig> servers);
  Future<void> close();
}

/// Cancels a scheduled callback.
abstract class P2PTimerHandle {
  void cancel();
}

typedef P2PScheduler = P2PTimerHandle Function(
  Duration delay,
  void Function() action,
);

/// [P2PScheduler] on top of dart:async timers.
P2PTimerHandle timerScheduler(Duration delay, void Function() action) =>
    _TimerHandle(Timer(delay, action));

class _TimerHandle implements P2PTimerHandle {
  _TimerHandle(this._timer);
  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// Everything one call controller needs from the outside world.
abstract class P2PCallDeps {
  Future<P2PPeerConnection> createPeerConnection(
    List<IceServerConfig> servers,
  );

  /// Opens the microphone (and the camera when [video]). Throws when the user
  /// denies permission or no device is available.
  Future<P2PStream> getUserMedia({required bool audio, required bool video});

  /// Fresh credentials; null/empty keeps the servers already in use.
  Future<List<IceServerConfig>?> fetchIceServers();

  void sendSignal(P2PSignalName signal, P2PSignalPayload payload);

  /// Routes call audio to the loudspeaker (true) or the earpiece (false).
  Future<void> setSpeakerphone(bool on);

  void log(String message, [Object? detail]);
}
