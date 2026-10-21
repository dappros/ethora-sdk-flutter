import '../calls/call_mode.dart';

/// Web `config.videoCalls`: 1:1 and group audio/video calls. Off by default.
///
/// The 1:1 transport (our own WebRTC peer to peer, or LiveKit) is chosen by
/// the server per call, not by this config. Group calls always run over
/// LiveKit and need a backend that accepts them.
class VideoCallsConfig {
  const VideoCallsConfig({
    this.enabled = false,
    this.livekitUrl = '',
    this.allowedRoomTypes,
    this.enableAudioCalls = false,
    this.startWithCameraOn = true,
    this.startWithMicOn = true,
    this.showScreenShare = false,
    this.ringtone = true,
    this.nativeCallUi = true,
  });

  /// Master switch.
  final bool enabled;

  /// The LiveKit server (`wss://...`). A call-token or create response that
  /// carries a trusted URL wins over this; the header call buttons still
  /// need it, like web.
  final String livekitUrl;

  /// Room types that can start and receive calls. Defaults to private and
  /// group chats; pass `[CallRoomType.private]` to keep calls 1:1 only. Public
  /// rooms never call.
  final List<CallRoomType>? allowedRoomTypes;

  /// Show the audio-only call button next to the video-call button.
  final bool enableAudioCalls;

  /// Start a video call with the camera already on. Default true.
  final bool startWithCameraOn;

  /// Start a call with the microphone already on. Default true.
  final bool startWithMicOn;

  /// Show the screen-share button in LiveKit calls (web default is on, but a
  /// phone needs extra native setup, see the README, so it is off here as in
  /// the React Native SDK). Not available in p2p calls, like web.
  final bool showScreenShare;

  /// Play the in-app ringtone for an incoming call and the ringback tone for
  /// an outgoing one.
  final bool ringtone;

  /// Show a ringing call on the native call UI (CallKit on iOS, a full-screen
  /// notification on Android) when the app is not in the foreground, and run
  /// the Android ongoing-call foreground service during a call.
  final bool nativeCallUi;

  bool get hasLivekitUrl => livekitUrl.trim().isNotEmpty;
}
