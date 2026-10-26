// The LiveKit implementation of a call session (web VideoCallSession.tsx
// connect logic). Joining the room is the only step whose failure fails the
// call; the devices are best effort, so a denied camera or microphone prompt
// leaves the call connected with a dismissible hint.

import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

import 'call_mode.dart';
import 'livekit_session_port.dart';
import 'screen_share_support.dart';

class LiveKitRoomSession implements LiveKitSession {
  LiveKitRoomSession(
    this.params,
    this.events, {
    ScreenShareSupport? screenShare,
  })  : _screenShare = screenShare ?? PlatformScreenShareSupport(),
        room = Room(
          roomOptions: const RoomOptions(
            adaptiveStream: true,
            dynacast: true,
            defaultCameraCaptureOptions: CameraCaptureOptions(
              params: VideoParametersPresets.h720_169,
            ),
            defaultVideoPublishOptions: VideoPublishOptions(
              simulcast: true,
              videoSimulcastLayers: <VideoParameters>[
                VideoParametersPresets.h540_169,
                VideoParametersPresets.h216_169,
              ],
            ),
          ),
        ) {
    _snapshot = LiveKitSnapshot(
      micEnabled: params.startWithMicOn,
      camEnabled: params.kind == CallKind.video && params.startWithCameraOn,
      speakerOn: params.kind == CallKind.video,
    );
    _listener = room.createListener()
      ..on<ParticipantConnectedEvent>((_) => _onParticipants())
      ..on<ParticipantDisconnectedEvent>((_) => _onParticipants())
      ..on<RoomDisconnectedEvent>((_) => _onRoomDisconnected());
    room.addListener(_onRoomChanged);
  }

  final LiveKitSessionParams params;
  final LiveKitSessionEvents events;
  final ScreenShareSupport _screenShare;

  /// The room, for the UI to render participants' tracks.
  final Room room;

  late final EventsListener<RoomEvent> _listener;
  late LiveKitSnapshot _snapshot;
  final Set<void Function()> _listeners = <void Function()>{};
  bool _disposed = false;
  bool _everJoined = false;
  bool _peerLeftFired = false;
  bool _frontCamera = true;

  @override
  LiveKitSnapshot get snapshot => _snapshot;

  @override
  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _update(LiveKitSnapshot Function(LiveKitSnapshot s) change) {
    if (_disposed) return;
    _snapshot = change(_snapshot);
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void _onRoomChanged() {
    final lp = room.localParticipant;
    if (lp == null) return;
    final mic = lp.isMicrophoneEnabled();
    final cam = lp.isCameraEnabled();
    final share = lp.isScreenShareEnabled();
    if (mic != _snapshot.micEnabled ||
        cam != _snapshot.camEnabled ||
        share != _snapshot.screenShareEnabled) {
      _update(
        (s) => s.copyWith(
          micEnabled: mic,
          camEnabled: cam,
          screenShareEnabled: share,
        ),
      );
      // Sharing ended from outside (the system "stop sharing" control).
      if (!share) unawaited(_screenShare.release());
    }
  }

  void _onParticipants() {
    if (_disposed) return;
    final count = room.remoteParticipants.length;
    _update((s) => s.copyWith(remoteCount: count));
    if (count > 0) {
      _everJoined = true;
      return;
    }
    // A 1:1 call is over when the one remote peer leaves. A group call must
    // NOT end that way: the others are still in the room.
    if (!params.isGroup && _everJoined && !_peerLeftFired) {
      _peerLeftFired = true;
      events.onPeerLeft?.call();
    }
  }

  void _onRoomDisconnected() {
    if (_disposed) return;
    events.onError?.call('Connection lost');
  }

  @override
  Future<void> connect() async {
    try {
      await room.connect(params.url, params.token);
    } catch (error) {
      if (_disposed) return;
      events.onError?.call(_describe(error));
      return;
    }
    if (_disposed) return;

    // Devices are best effort: if the user blocks the permission prompt the
    // call still connects (they can hear the peer and retry via the buttons).
    final audioOnly = params.kind == CallKind.audio;
    try {
      await room.localParticipant?.setMicrophoneEnabled(params.startWithMicOn);
    } catch (error) {
      _update((s) => s.copyWith(notice: _describeDevice(error)));
    }
    if (!audioOnly) {
      try {
        await room.localParticipant?.setCameraEnabled(params.startWithCameraOn);
      } catch (error) {
        _update((s) => s.copyWith(notice: _describeDevice(error)));
      }
    }
    if (_disposed) return;
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(!audioOnly);
    } catch (_) {
      // Not every platform can route audio; the call still works.
    }
    _update((s) => s.copyWith(connected: true));
    _onParticipants();
    events.onConnected?.call();
  }

  @override
  Future<void> toggleMic() async {
    final lp = room.localParticipant;
    if (_disposed || lp == null) return;
    try {
      await lp.setMicrophoneEnabled(!lp.isMicrophoneEnabled());
    } catch (error) {
      _update((s) => s.copyWith(notice: _describeDevice(error)));
    }
  }

  @override
  Future<void> toggleCamera() async {
    final lp = room.localParticipant;
    if (_disposed || lp == null || params.kind != CallKind.video) return;
    try {
      await lp.setCameraEnabled(!lp.isCameraEnabled());
    } catch (error) {
      _update((s) => s.copyWith(notice: _describeDevice(error)));
    }
  }

  @override
  Future<void> flipCamera() async {
    final lp = room.localParticipant;
    if (_disposed || lp == null) return;
    for (final publication in lp.videoTrackPublications) {
      if (publication.source != TrackSource.camera) continue;
      final track = publication.track;
      if (track is! LocalVideoTrack) continue;
      try {
        await track.setCameraPosition(
          _frontCamera ? CameraPosition.back : CameraPosition.front,
        );
        _frontCamera = !_frontCamera;
      } catch (error) {
        _update((s) => s.copyWith(notice: _describeDevice(error)));
      }
      return;
    }
  }

  @override
  Future<void> toggleScreenShare() async {
    final lp = room.localParticipant;
    if (_disposed || lp == null) return;
    try {
      if (lp.isScreenShareEnabled()) {
        await lp.setScreenShareEnabled(false);
        await _screenShare.release();
      } else {
        if (!await _screenShare.prepare()) {
          _update(
            (s) => s.copyWith(notice: 'Screen sharing was not allowed'),
          );
          return;
        }
        await lp.setScreenShareEnabled(true);
      }
    } catch (error) {
      await _screenShare.release();
      _update((s) => s.copyWith(notice: 'Could not share the screen'));
    }
  }

  @override
  Future<void> setSpeaker(bool on) async {
    if (_disposed) return;
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(on);
      _update((s) => s.copyWith(speakerOn: on));
    } catch (_) {
      // Routing is best effort.
    }
  }

  @override
  void dismissNotice() {
    if (_snapshot.notice != null) {
      _update((s) => s.copyWith(clearNotice: true));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    room.removeListener(_onRoomChanged);
    unawaited(_screenShare.release().catchError((Object _) {}));
    try {
      await _listener.dispose();
    } catch (_) {}
    try {
      await room.disconnect();
    } catch (_) {}
    try {
      await room.dispose();
    } catch (_) {}
    _listeners.clear();
  }

  static String _describe(Object error) {
    final text = '$error';
    return text.isEmpty ? 'Could not join the call' : text;
  }

  static String _describeDevice(Object error) {
    final text = '$error'.toLowerCase();
    if (text.contains('permission') ||
        text.contains('denied') ||
        text.contains('notallowed')) {
      return 'Camera or microphone permission denied';
    }
    if (text.contains('notfound')) {
      return 'No camera or microphone found on this device';
    }
    return 'Could not access your camera or microphone';
  }
}
