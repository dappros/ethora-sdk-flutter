// The one place the p2p call stack touches flutter_webrtc: adapters from the
// platform RTCPeerConnection / MediaStream types to the [P2PPeerConnection] /
// [P2PStream] ports the controller is written against.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../call_mode.dart';
import 'p2p_ice_policy.dart';
import 'p2p_ports.dart';
import 'p2p_signal.dart';

class WebRtcTrack implements P2PTrack {
  WebRtcTrack._(this.native) {
    native.onMute = _changed;
    native.onUnMute = _changed;
    native.onEnded = () {
      _ended = true;
      _changed();
    };
  }

  static final Expando<WebRtcTrack> _wrapped = Expando<WebRtcTrack>('p2p');

  /// One wrapper per native track, so list membership checks keep working.
  factory WebRtcTrack.of(rtc.MediaStreamTrack native) =>
      _wrapped[native] ??= WebRtcTrack._(native);

  final rtc.MediaStreamTrack native;
  bool _ended = false;

  void _changed() => onStateChanged?.call();

  @override
  void Function()? onStateChanged;

  @override
  String get kind => native.kind ?? '';

  @override
  bool get enabled => native.enabled;

  @override
  set enabled(bool value) => native.enabled = value;

  @override
  bool get isLive => !_ended;

  @override
  bool get isMuted => native.muted ?? false;

  @override
  Future<void> stop() async {
    _ended = true;
    await native.stop();
  }

  @override
  Future<void> switchCamera() async {
    await rtc.Helper.switchCamera(native);
  }
}

class WebRtcStream implements P2PStream {
  WebRtcStream(this.native);

  @override
  final rtc.MediaStream native;

  @override
  List<P2PTrack> get audioTracks =>
      native.getAudioTracks().map(WebRtcTrack.of).toList();

  @override
  List<P2PTrack> get videoTracks =>
      native.getVideoTracks().map(WebRtcTrack.of).toList();

  @override
  List<P2PTrack> get tracks => native.getTracks().map(WebRtcTrack.of).toList();

  @override
  Future<void> addTrack(P2PTrack track) =>
      native.addTrack((track as WebRtcTrack).native);

  @override
  Future<void> removeTrack(P2PTrack track) =>
      native.removeTrack((track as WebRtcTrack).native);
}

P2PConnState _mapConnectionState(rtc.RTCPeerConnectionState? state) {
  switch (state) {
    case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
      return P2PConnState.connected;
    case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
      return P2PConnState.connecting;
    case rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
      return P2PConnState.disconnected;
    case rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      return P2PConnState.failed;
    case rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed:
      return P2PConnState.closed;
    case rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew:
    case null:
      return P2PConnState.newState;
  }
}

P2PConnState _mapIceState(rtc.RTCIceConnectionState? state) {
  switch (state) {
    case rtc.RTCIceConnectionState.RTCIceConnectionStateConnected:
    case rtc.RTCIceConnectionState.RTCIceConnectionStateCompleted:
      return P2PConnState.connected;
    case rtc.RTCIceConnectionState.RTCIceConnectionStateChecking:
      return P2PConnState.connecting;
    case rtc.RTCIceConnectionState.RTCIceConnectionStateDisconnected:
      return P2PConnState.disconnected;
    case rtc.RTCIceConnectionState.RTCIceConnectionStateFailed:
      return P2PConnState.failed;
    case rtc.RTCIceConnectionState.RTCIceConnectionStateClosed:
      return P2PConnState.closed;
    default:
      return P2PConnState.newState;
  }
}

class WebRtcPeerConnection implements P2PPeerConnection {
  WebRtcPeerConnection(this._pc) {
    _pc.onIceCandidate = (candidate) {
      final text = candidate.candidate;
      if (text == null || text.isEmpty) return;
      onCandidate?.call(
        P2PCandidate(
          candidate: text,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    _pc.onTrack = (event) {
      final track = WebRtcTrack.of(event.track);
      final rtc.MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
        onRemoteTrack?.call(track, WebRtcStream(stream));
      } else {
        unawaited(_attachToFallbackStream(event.track, track));
      }
    };
    _pc.onConnectionState = (_) => onStateChanged?.call();
    _pc.onIceConnectionState = (_) => onStateChanged?.call();
  }

  final rtc.RTCPeerConnection _pc;
  rtc.MediaStream? _fallbackRemote;

  // A sender that never named a stream: collect its tracks in one of our own.
  Future<void> _attachToFallbackStream(
    rtc.MediaStreamTrack native,
    WebRtcTrack track,
  ) async {
    final stream =
        _fallbackRemote ??= await rtc.createLocalMediaStream('remote');
    await stream.addTrack(native);
    onRemoteTrack?.call(track, WebRtcStream(stream));
  }

  @override
  void Function(P2PCandidate candidate)? onCandidate;

  @override
  void Function(P2PTrack track, P2PStream stream)? onRemoteTrack;

  @override
  void Function()? onStateChanged;

  @override
  P2PConnState get connectionState {
    final state = _pc.connectionState;
    // Platforms that report no connection state: map the ICE state.
    return state == null
        ? _mapIceState(_pc.iceConnectionState)
        : _mapConnectionState(state);
  }

  @override
  bool get isStable =>
      _pc.signalingState == rtc.RTCSignalingState.RTCSignalingStateStable;

  @override
  bool get hasLocalOffer =>
      _pc.signalingState ==
      rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer;

  @override
  Future<String> createOffer({bool iceRestart = false}) async {
    final description = await _pc.createOffer(
      iceRestart
          ? <String, dynamic>{
              'mandatory': <String, dynamic>{'IceRestart': true},
            }
          : <String, dynamic>{},
    );
    return description.sdp ?? '';
  }

  @override
  Future<String> createAnswer() async {
    final description = await _pc.createAnswer(<String, dynamic>{});
    return description.sdp ?? '';
  }

  @override
  Future<void> setLocalDescription(String type, String sdp) =>
      _pc.setLocalDescription(rtc.RTCSessionDescription(sdp, type));

  @override
  Future<void> rollbackLocal() =>
      _pc.setLocalDescription(rtc.RTCSessionDescription('', 'rollback'));

  @override
  Future<void> setRemoteDescription(String type, String sdp) =>
      _pc.setRemoteDescription(rtc.RTCSessionDescription(sdp, type));

  @override
  Future<String?> localSdp() async => (await _pc.getLocalDescription())?.sdp;

  @override
  Future<void> addCandidate(P2PCandidate candidate) => _pc.addCandidate(
        rtc.RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      );

  P2PSender _senderOf(rtc.RTCRtpSender sender) => P2PSender(
        (track) => sender.replaceTrack(
          track == null ? null : (track as WebRtcTrack).native,
        ),
      );

  @override
  Future<P2PSender> addTrack(P2PTrack track, P2PStream stream) async {
    final sender = await _pc.addTrack(
      (track as WebRtcTrack).native,
      (stream as WebRtcStream).native,
    );
    return _senderOf(sender);
  }

  @override
  Future<P2PSender> addVideoTransceiver() async {
    final transceiver = await _pc.addTransceiver(
      kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: rtc.RTCRtpTransceiverInit(
        direction: rtc.TransceiverDirection.SendRecv,
      ),
    );
    return _senderOf(transceiver.sender);
  }

  @override
  Future<void> restartIce() => _pc.restartIce();

  @override
  Future<void> setIceServers(List<IceServerConfig> servers) {
    final config = Map<String, dynamic>.of(_pc.getConfiguration);
    config['iceServers'] = servers.map((s) => s.toMap()).toList();
    return _pc.setConfiguration(config);
  }

  @override
  Future<void> close() async {
    _pc.onIceCandidate = null;
    _pc.onTrack = null;
    _pc.onConnectionState = null;
    _pc.onIceConnectionState = null;
    await _pc.close();
    await _pc.dispose();
  }
}

/// The real [P2PCallDeps]: flutter_webrtc media and peer connections, the
/// app's signal transport and ICE credential endpoint injected by the caller.
class WebRtcCallDeps implements P2PCallDeps {
  WebRtcCallDeps({
    required Future<List<IceServerConfig>?> Function() fetchIce,
    required void Function(P2PSignalName signal, P2PSignalPayload payload)
        sendSignalFn,
    void Function(String message, [Object? detail])? logFn,
  })  : _fetchIce = fetchIce,
        _sendSignal = sendSignalFn,
        _log = logFn;

  final Future<List<IceServerConfig>?> Function() _fetchIce;
  final void Function(P2PSignalName signal, P2PSignalPayload payload)
      _sendSignal;
  final void Function(String message, [Object? detail])? _log;

  @override
  Future<P2PPeerConnection> createPeerConnection(
    List<IceServerConfig> servers,
  ) async {
    final pc = await rtc.createPeerConnection(<String, dynamic>{
      'iceServers': servers.map((s) => s.toMap()).toList(),
      'iceCandidatePoolSize': 2,
      'sdpSemantics': 'unified-plan',
    });
    return WebRtcPeerConnection(pc);
  }

  @override
  Future<P2PStream> getUserMedia({
    required bool audio,
    required bool video,
  }) async {
    final stream = await rtc.navigator.mediaDevices.getUserMedia(
      <String, dynamic>{
        'audio': audio
            ? <String, dynamic>{
                'echoCancellation': true,
                'noiseSuppression': true,
                'autoGainControl': true,
              }
            : false,
        'video': video
            ? <String, dynamic>{
                'facingMode': 'user',
                'width': <String, dynamic>{'ideal': 1280},
                'height': <String, dynamic>{'ideal': 720},
              }
            : false,
      },
    );
    return WebRtcStream(stream);
  }

  @override
  Future<List<IceServerConfig>?> fetchIceServers() => _fetchIce();

  @override
  void sendSignal(P2PSignalName signal, P2PSignalPayload payload) =>
      _sendSignal(signal, payload);

  @override
  Future<void> setSpeakerphone(bool on) => rtc.Helper.setSpeakerphoneOn(on);

  @override
  void log(String message, [Object? detail]) => _log?.call(message, detail);
}
