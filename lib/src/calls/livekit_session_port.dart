// The seam between the calls coordinator and the LiveKit SDK. The coordinator
// only knows this interface, so its state machine runs under a fake session in
// unit tests; livekit_room_session.dart holds the real implementation.

import 'call_mode.dart';

class LiveKitSessionParams {
  const LiveKitSessionParams({
    required this.url,
    required this.token,
    required this.kind,
    required this.isGroup,
    this.startWithMicOn = true,
    this.startWithCameraOn = true,
  });

  final String url;
  final String token;
  final CallKind kind;

  /// A group call keeps going while others remain; a 1:1 call ends locally as
  /// soon as the single remote peer leaves.
  final bool isGroup;
  final bool startWithMicOn;
  final bool startWithCameraOn;
}

class LiveKitSessionEvents {
  const LiveKitSessionEvents({
    this.onConnected,
    this.onError,
    this.onPeerLeft,
  });

  /// Joined the room and the local devices were started.
  final void Function()? onConnected;

  /// Joining failed, or the room dropped for good.
  final void Function(String message)? onError;

  /// 1:1 only: the one remote participant left after having been there.
  final void Function()? onPeerLeft;
}

class LiveKitSnapshot {
  const LiveKitSnapshot({
    this.micEnabled = true,
    this.camEnabled = false,
    this.screenShareEnabled = false,
    this.speakerOn = false,
    this.remoteCount = 0,
    this.connected = false,
    this.notice,
  });

  final bool micEnabled;
  final bool camEnabled;
  final bool screenShareEnabled;
  final bool speakerOn;
  final int remoteCount;
  final bool connected;

  /// Dismissible, non-fatal hint (a device could not be started).
  final String? notice;

  LiveKitSnapshot copyWith({
    bool? micEnabled,
    bool? camEnabled,
    bool? screenShareEnabled,
    bool? speakerOn,
    int? remoteCount,
    bool? connected,
    String? notice,
    bool clearNotice = false,
  }) {
    return LiveKitSnapshot(
      micEnabled: micEnabled ?? this.micEnabled,
      camEnabled: camEnabled ?? this.camEnabled,
      screenShareEnabled: screenShareEnabled ?? this.screenShareEnabled,
      speakerOn: speakerOn ?? this.speakerOn,
      remoteCount: remoteCount ?? this.remoteCount,
      connected: connected ?? this.connected,
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}

abstract class LiveKitSession {
  LiveKitSnapshot get snapshot;

  /// Registers a change listener; returns the function that removes it.
  void Function() subscribe(void Function() listener);

  Future<void> connect();
  Future<void> toggleMic();
  Future<void> toggleCamera();
  Future<void> flipCamera();

  /// Starts or stops sharing the screen.
  Future<void> toggleScreenShare();
  Future<void> setSpeaker(bool on);
  void dismissNotice();

  /// Leaves the room and releases every device. Idempotent.
  Future<void> dispose();
}

typedef LiveKitSessionFactory = LiveKitSession Function(
  LiveKitSessionParams params,
  LiveKitSessionEvents events,
);
