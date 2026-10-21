// One peer to peer call, from getUserMedia to hang-up (web calls/p2p/
// P2PCallController.ts). Everything that talks to the outside world is
// injected through [P2PCallDeps] (peer connection, media, signal transport,
// ICE credential refresh, timers), so the class is plain Dart and runs under a
// fake connection in unit tests. The decisions live in the small pure modules
// next to it (negotiator, ICE policy, signal stanzas); this class only wires
// them to a real connection and cleans up after itself.
//
// Media encryption: a WebRTC peer connection already encrypts media between
// the two peers with DTLS-SRTP, so the LiveKit insertable-streams E2EE layer
// is deliberately NOT applied on this path.

import 'dart:async';

import '../call_mode.dart';
import 'p2p_ice_policy.dart';
import 'p2p_negotiator.dart';
import 'p2p_ports.dart';
import 'p2p_signal.dart';

enum P2PStatus {
  preparing,
  waiting,
  connecting,
  connected,
  reconnecting,
  failed,
  ended,
}

class P2PSnapshot {
  const P2PSnapshot({
    this.status = P2PStatus.preparing,
    this.localStream,
    this.remoteStream,
    this.micEnabled = true,
    this.camEnabled = false,
    this.remoteVideoLive = false,
    this.speakerOn = false,
    this.notice,
  });

  final P2PStatus status;
  final P2PStream? localStream;
  final P2PStream? remoteStream;
  final bool micEnabled;
  final bool camEnabled;
  final bool remoteVideoLive;
  final bool speakerOn;

  /// Dismissible, non-fatal hint (e.g. the camera could not be re-enabled).
  final String? notice;

  P2PSnapshot copyWith({
    P2PStatus? status,
    P2PStream? localStream,
    P2PStream? remoteStream,
    bool clearStreams = false,
    bool? micEnabled,
    bool? camEnabled,
    bool? remoteVideoLive,
    bool? speakerOn,
    String? notice,
    bool clearNotice = false,
  }) {
    return P2PSnapshot(
      status: status ?? this.status,
      localStream: clearStreams ? null : (localStream ?? this.localStream),
      remoteStream: clearStreams ? null : (remoteStream ?? this.remoteStream),
      micEnabled: micEnabled ?? this.micEnabled,
      camEnabled: camEnabled ?? this.camEnabled,
      remoteVideoLive: remoteVideoLive ?? this.remoteVideoLive,
      speakerOn: speakerOn ?? this.speakerOn,
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}

class P2PCallParams {
  const P2PCallParams({
    required this.callId,
    required this.role,
    required this.kind,
    required this.peerLocal,
    this.iceServers = const <IceServerConfig>[],
    this.startWithMicOn = true,
    this.startWithCameraOn = true,
  });

  final String callId;
  final P2PRole role;
  final CallKind kind;

  /// Peer's xmpp localpart; signals from anyone else are ignored.
  final String peerLocal;
  final List<IceServerConfig> iceServers;
  final bool startWithMicOn;
  final bool startWithCameraOn;
}

class P2PCallEvents {
  const P2PCallEvents({
    this.onNegotiated,
    this.onConnected,
    this.onRemoteEnd,
    this.onFailed,
    this.onDisposed,
  });

  /// The offer/answer exchange completed: media is now negotiating.
  final void Function()? onNegotiated;

  /// Media is flowing for the first time.
  final void Function()? onConnected;

  /// The peer ended the call (hang up, decline, their own failure).
  final void Function(String reason)? onRemoteEnd;

  /// The call failed locally; the message is meant for the user.
  final void Function(String message)? onFailed;

  /// Called exactly once when the call's resources are released. `started` is
  /// false for a callee that never accepted (nothing was negotiated).
  final void Function({required bool started})? onDisposed;
}

class P2PTimings {
  const P2PTimings({
    this.connectTimeoutMs = 25000,
    // While nobody has answered, the offer and candidates are sent again: a
    // callee that was still reconnecting (woken by push) missed the first
    // copy, and the stanzas are not stored for later. Duplicates are no-ops
    // there.
    this.offerResendMs = const <int>[4000, 10000],
  });

  final int connectTimeoutMs;
  final List<int> offerResendMs;
}

/// A user-facing sentence for a getUserMedia failure.
String describeMediaError(Object? error) {
  final text = '$error'.toLowerCase();
  if (text.contains('notallowed') ||
      text.contains('securityerror') ||
      text.contains('permission') ||
      text.contains('denied')) {
    return 'Camera or microphone permission denied';
  }
  if (text.contains('notfound') || text.contains('overconstrained')) {
    return 'No camera or microphone found on this device';
  }
  if (text.contains('notreadable') ||
      text.contains('abort') ||
      text.contains('in use')) {
    return 'Your camera or microphone is already in use by another app';
  }
  return 'Could not access your camera or microphone';
}

/// What to show when the PEER ended the call for a reason that is a failure
/// rather than a normal hang up / decline. Null means "just close the call".
String? remoteEndNotice(String reason) {
  switch (reason) {
    case 'media-error':
      return 'The other person could not access their camera or microphone';
    case 'connect-timeout':
    case 'connection-failed':
    case 'negotiation-error':
    case 'setup-error':
      return 'The call could not be connected';
  }
  return null;
}

class P2PCallController {
  P2PCallController({
    required this.params,
    required P2PCallDeps deps,
    required P2PScheduler scheduler,
    P2PCallEvents events = const P2PCallEvents(),
    P2PTimings timings = const P2PTimings(),
  })  : _deps = deps,
        _scheduler = scheduler,
        _events = events,
        _timings = timings,
        _negotiator = P2PNegotiator(
          callId: params.callId,
          role: params.role,
          peerLocal: params.peerLocal,
        ) {
    _snapshot = P2PSnapshot(
      micEnabled: params.startWithMicOn,
      camEnabled: params.kind == CallKind.video && params.startWithCameraOn,
      speakerOn: params.kind == CallKind.video,
    );
  }

  final P2PCallParams params;
  final P2PCallDeps _deps;
  final P2PScheduler _scheduler;
  final P2PCallEvents _events;
  final P2PTimings _timings;
  final P2PNegotiator _negotiator;
  final IceRestartPolicy _policy = IceRestartPolicy();

  String get callId => params.callId;
  P2PRole get role => params.role;
  CallKind get kind => params.kind;

  late P2PSnapshot _snapshot;
  final Set<void Function()> _listeners = <void Function()>{};

  P2PPeerConnection? _pc;
  P2PStream? _localStream;
  P2PTrack? _audioTrack;
  P2PTrack? _videoTrack;
  P2PSender? _videoSender;
  List<P2PTrack> _ownedTracks = <P2PTrack>[];
  P2PStream? _remoteStream;
  final List<P2PTrack> _remoteTracks = <P2PTrack>[];

  Future<void> _queue = Future<void>.value();
  final Set<P2PTimerHandle> _timers = <P2PTimerHandle>{};
  P2PTimerHandle? _graceTimer;
  P2PTimerHandle? _deadlineTimer;
  P2PTimerHandle? _connectTimer;
  final List<P2PTimerHandle> _resendTimers = <P2PTimerHandle>[];

  bool _started = false;
  bool _disposed = false;
  bool _endSent = false;
  bool _connectedOnce = false;
  bool _negotiated = false;
  bool _cameraBusy = false;
  P2PConnState? _lastConn;

  // Outgoing candidates wait until the offer/answer they belong to is out, so
  // the peer never sees a candidate before its description.
  bool _candidateGateOpen = false;
  List<P2PCandidate> _heldOutgoingCandidates = <P2PCandidate>[];
  List<P2PCandidate> _sentCandidates = <P2PCandidate>[];
  String? _lastOfferSdp;

  // ---- observable state ----------------------------------------------------

  P2PSnapshot get snapshot => _snapshot;

  /// Registers a change listener; returns the function that removes it.
  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void _update(P2PSnapshot Function(P2PSnapshot current) change) {
    _snapshot = change(_snapshot);
    _notify();
  }

  void _log(String message, [Object? detail]) =>
      _deps.log('[p2p $callId] $message', detail);

  // ---- timers --------------------------------------------------------------

  P2PTimerHandle _later(void Function() fn, int ms) {
    late P2PTimerHandle handle;
    handle = _scheduler(Duration(milliseconds: ms), () {
      _timers.remove(handle);
      if (!_disposed) fn();
    });
    _timers.add(handle);
    return handle;
  }

  void _cancel(P2PTimerHandle? handle) {
    if (handle == null) return;
    handle.cancel();
    _timers.remove(handle);
  }

  // ---- lifecycle -----------------------------------------------------------

  /// Caller: get media, build the connection, offer. Callee: get media, build
  /// the connection, then apply the offer that may already be waiting. Safe to
  /// call once; every failure ends the call with a message instead of
  /// throwing.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _update((s) => s.copyWith(status: P2PStatus.preparing));

    // Credentials are fetched while the permission prompt is open.
    final icePromise = params.iceServers.isNotEmpty
        ? Future<List<IceServerConfig>>.value(params.iceServers)
        : _fetchIce();

    try {
      await _acquireMedia();
    } catch (error) {
      _log('getUserMedia failed', error);
      _fail(describeMediaError(error), 'media-error');
      return;
    }
    if (_disposed) {
      await _releaseMedia();
      return;
    }

    final servers = await icePromise;
    if (_disposed) return;

    try {
      await _createConnection(servers);
    } catch (error) {
      _log('peer connection setup failed', error);
      _fail('Could not start the call', 'setup-error');
      return;
    }
    if (_disposed) return;

    _enqueue(() async {
      await _runCommands(_negotiator.markReady());
      if (params.role == P2PRole.caller && !_disposed) {
        await _sendOffer(false);
        _update((s) => s.copyWith(status: P2PStatus.waiting));
        _scheduleOfferResends();
      }
    });
    // Audio routing is best effort and never blocks the call.
    unawaited(
      _deps.setSpeakerphone(_snapshot.speakerOn).catchError((Object e) {
        _log('speakerphone route failed', e);
      }),
    );
  }

  Future<List<IceServerConfig>> _fetchIce() async {
    try {
      return await _deps.fetchIceServers() ?? const <IceServerConfig>[];
    } catch (_) {
      return const <IceServerConfig>[];
    }
  }

  /// Feed a signal from the peer (already routed by callId).
  void receive(P2PSignal signal) {
    if (_disposed) return;
    final commands = _negotiator.receive(signal);
    // An end must act immediately: it can arrive while the permission prompt
    // is still open, before the connection (and so the job queue) is running.
    for (final command in commands) {
      if (command is RemoteEnd) {
        _handleRemoteEnd(command.reason);
        return;
      }
    }
    if (commands.isNotEmpty) _enqueue(() => _runCommands(commands));
  }

  /// Local user hung up (or cancelled): tell the peer and release everything.
  void hangup([String reason = 'hangup']) {
    if (_disposed) return;
    _sendEnd(reason);
    dispose();
  }

  /// Release every resource: timers, listeners, media tracks, the connection.
  /// Idempotent, safe from any exit path. Tells the peer unless it is already
  /// known to be over.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started && !_negotiator.isEnded) _sendEnd('hangup');

    for (final handle in _timers.toList()) {
      handle.cancel();
    }
    _timers.clear();
    _negotiator.stop();

    for (final track in _remoteTracks) {
      track.onStateChanged = null;
    }
    _remoteTracks.clear();
    _remoteStream = null;

    final pc = _pc;
    _pc = null;
    if (pc != null) {
      pc.onCandidate = null;
      pc.onRemoteTrack = null;
      pc.onStateChanged = null;
      unawaited(pc.close().catchError((Object _) {}));
    }
    unawaited(_releaseMedia());

    _snapshot = _snapshot.copyWith(
      status: _snapshot.status == P2PStatus.failed
          ? P2PStatus.failed
          : P2PStatus.ended,
      clearStreams: true,
      remoteVideoLive: false,
    );
    _notify();
    _listeners.clear();
    _events.onDisposed?.call(started: _started);
  }

  void _sendEnd(String reason) {
    if (_endSent) return;
    _endSent = true;
    try {
      _deps.sendSignal(P2PSignalName.end, P2PSignalPayload.end(reason));
    } catch (error) {
      _log('end signal failed', error);
    }
  }

  void _fail(String message, String reason) {
    if (_disposed) return;
    _sendEnd(reason);
    _snapshot = _snapshot.copyWith(status: P2PStatus.failed, notice: message);
    _events.onFailed?.call(message);
    dispose();
  }

  void _handleRemoteEnd(String reason) {
    if (_disposed) return;
    // The peer already knows; do not echo an end back.
    _endSent = true;
    _snapshot = _snapshot.copyWith(status: P2PStatus.ended);
    _events.onRemoteEnd?.call(reason);
    dispose();
  }

  // ---- media ---------------------------------------------------------------

  Future<void> _acquireMedia() async {
    final wantVideo = params.kind == CallKind.video && params.startWithCameraOn;
    final stream = await _deps.getUserMedia(audio: true, video: wantVideo);
    _localStream = stream;
    _ownedTracks = List<P2PTrack>.of(stream.tracks);
    _audioTrack = stream.audioTracks.isEmpty ? null : stream.audioTracks.first;
    _videoTrack = stream.videoTracks.isEmpty ? null : stream.videoTracks.first;
    final audio = _audioTrack;
    if (audio != null && !params.startWithMicOn) audio.enabled = false;
    _update(
      (s) => s.copyWith(
        localStream: stream,
        micEnabled: audio != null && audio.enabled,
        camEnabled: _videoTrack != null,
      ),
    );
  }

  Future<void> _releaseMedia() async {
    final tracks = <P2PTrack>{..._ownedTracks, ...?_localStream?.tracks};
    for (final track in tracks) {
      try {
        await track.stop();
      } catch (_) {
        // already stopped
      }
    }
    _ownedTracks = <P2PTrack>[];
    _audioTrack = null;
    _videoTrack = null;
    _videoSender = null;
    _localStream = null;
  }

  void toggleMic() {
    final audio = _audioTrack;
    if (_disposed || audio == null) return;
    audio.enabled = !audio.enabled;
    _update((s) => s.copyWith(micEnabled: audio.enabled));
  }

  /// Loudspeaker (true) or earpiece (false).
  Future<void> setSpeaker(bool on) async {
    if (_disposed) return;
    try {
      await _deps.setSpeakerphone(on);
      _update((s) => s.copyWith(speakerOn: on));
    } catch (error) {
      _log('speakerphone route failed', error);
    }
  }

  /// Front/back camera flip. A no-op while the camera is off.
  Future<void> flipCamera() async {
    final video = _videoTrack;
    if (_disposed || video == null) return;
    try {
      await video.switchCamera();
    } catch (error) {
      _log('flip camera failed', error);
      _update((s) => s.copyWith(notice: describeMediaError(error)));
    }
  }

  /// Turning the camera off stops sending video and releases the device (the
  /// camera light goes out); turning it on opens the camera again and swaps it
  /// into the existing sender, so no renegotiation is needed.
  Future<void> toggleCamera() async {
    final sender = _videoSender;
    final local = _localStream;
    if (_disposed ||
        params.kind != CallKind.video ||
        sender == null ||
        local == null ||
        _cameraBusy) {
      return;
    }
    _cameraBusy = true;
    try {
      final current = _videoTrack;
      if (current != null) {
        _videoTrack = null;
        try {
          await sender.replaceTrack(null);
        } catch (error) {
          _log('replaceTrack(null) failed', error);
        }
        try {
          await local.removeTrack(current);
        } catch (_) {
          // not in the stream
        }
        await current.stop();
        _ownedTracks = _ownedTracks.where((t) => t != current).toList();
        _update((s) => s.copyWith(camEnabled: false, clearNotice: true));
      } else {
        final media = await _deps.getUserMedia(audio: false, video: true);
        if (media.videoTracks.isEmpty) return;
        final track = media.videoTracks.first;
        if (_disposed || _videoSender == null || _localStream == null) {
          await track.stop();
          return;
        }
        await sender.replaceTrack(track);
        await local.addTrack(track);
        _videoTrack = track;
        _ownedTracks.add(track);
        _update((s) => s.copyWith(camEnabled: true, clearNotice: true));
      }
    } catch (error) {
      _log('camera toggle failed', error);
      _update((s) => s.copyWith(notice: describeMediaError(error)));
    } finally {
      _cameraBusy = false;
    }
  }

  void dismissNotice() {
    if (_snapshot.notice != null) {
      _update((s) => s.copyWith(clearNotice: true));
    }
  }

  // ---- peer connection -----------------------------------------------------

  Future<void> _createConnection(List<IceServerConfig> servers) async {
    final pc = await _deps.createPeerConnection(servers);
    if (_disposed) {
      await pc.close();
      return;
    }
    _pc = pc;

    pc.onCandidate = (candidate) {
      if (candidate.candidate.isEmpty) return;
      if (_candidateGateOpen) {
        _emitCandidate(candidate);
      } else {
        _heldOutgoingCandidates.add(candidate);
      }
    };
    pc.onRemoteTrack = _onRemoteTrack;
    pc.onStateChanged = _onConnectionState;

    final stream = _localStream;
    if (stream != null) {
      final audio = _audioTrack;
      if (audio != null) await pc.addTrack(audio, stream);
      if (params.kind == CallKind.video) {
        final video = _videoTrack;
        if (video != null) {
          _videoSender = await pc.addTrack(video, stream);
        } else {
          // Camera starts off: keep a video section so it can be turned on
          // later without renegotiating.
          _videoSender = await pc.addVideoTransceiver();
        }
      }
    }
  }

  void _emitCandidate(P2PCandidate candidate) {
    _sentCandidates.add(candidate);
    _deps.sendSignal(
      P2PSignalName.candidate,
      P2PSignalPayload.candidate(candidate),
    );
  }

  void _openCandidateGate() {
    _candidateGateOpen = true;
    final held = _heldOutgoingCandidates;
    _heldOutgoingCandidates = <P2PCandidate>[];
    held.forEach(_emitCandidate);
  }

  void _onRemoteTrack(P2PTrack track, P2PStream stream) {
    _remoteStream ??= stream;
    if (!_remoteTracks.contains(track)) {
      _remoteTracks.add(track);
      track.onStateChanged = () {
        if (_disposed) return;
        _update((s) => s.copyWith(remoteVideoLive: _remoteVideoLive()));
      };
    }
    _update(
      (s) => s.copyWith(
        remoteStream: _remoteStream,
        remoteVideoLive: _remoteVideoLive(),
      ),
    );
  }

  bool _remoteVideoLive() => _remoteTracks.any(
        (t) => t.kind == 'video' && t.isLive && !t.isMuted && t.enabled,
      );

  // ---- negotiation ---------------------------------------------------------

  void _enqueue(Future<void> Function() job) {
    _queue = _queue.then<void>((_) async {
      if (!_disposed) await job();
    }).catchError((Object error) {
      _log('negotiation step failed', error);
      // A broken negotiation cannot recover on its own.
      _fail('Could not set up the call', 'negotiation-error');
    });
  }

  Future<void> _sendOffer(bool iceRestart) async {
    final pc = _pc;
    if (pc == null || _disposed) return;
    _candidateGateOpen = false;
    final offer = await pc.createOffer(iceRestart: iceRestart);
    await pc.setLocalDescription('offer', offer);
    if (_disposed) return;
    final sdp = (await pc.localSdp()) ?? offer;
    _negotiator.markLocalOffer();
    _lastOfferSdp = sdp;
    _sentCandidates = <P2PCandidate>[];
    _deps.sendSignal(P2PSignalName.offer, P2PSignalPayload.sdp(sdp));
    _openCandidateGate();
  }

  void _scheduleOfferResends() {
    for (final ms in _timings.offerResendMs) {
      _resendTimers.add(_later(() {
        final offer = _lastOfferSdp;
        if (!_negotiator.awaitingAnswer || offer == null) return;
        _log('re-sending offer');
        _deps.sendSignal(P2PSignalName.offer, P2PSignalPayload.sdp(offer));
        for (final candidate in List<P2PCandidate>.of(_sentCandidates)) {
          _deps.sendSignal(
            P2PSignalName.candidate,
            P2PSignalPayload.candidate(candidate),
          );
        }
      }, ms));
    }
  }

  Future<void> _runCommands(List<NegotiatorCommand> commands) async {
    for (final command in commands) {
      final pc = _pc;
      if (_disposed || pc == null) return;
      switch (command) {
        case ApplyOffer():
          await _applyOffer(command);
        case ApplyAnswer():
          await pc.setRemoteDescription('answer', command.sdp);
          await _runCommands(_negotiator.markRemoteApplied());
          _onNegotiated();
        case AddCandidate():
          try {
            await pc.addCandidate(command.candidate);
          } catch (error) {
            // A candidate from a superseded ICE session; harmless.
            _log('addCandidate ignored', error);
          }
        case RemoteEnd():
          // Handled synchronously in receive(); never queued.
          break;
      }
    }
  }

  Future<void> _applyOffer(ApplyOffer command) async {
    final pc = _pc;
    if (pc == null) return;
    if (command.rollback && pc.hasLocalOffer) {
      await pc.rollbackLocal();
    }
    await pc.setRemoteDescription('offer', command.sdp);
    await _runCommands(_negotiator.markRemoteApplied());
    if (_disposed || _pc == null) return;

    _candidateGateOpen = false;
    final answer = await pc.createAnswer();
    await pc.setLocalDescription('answer', answer);
    if (_disposed) return;
    _deps.sendSignal(
      P2PSignalName.answer,
      P2PSignalPayload.sdp((await pc.localSdp()) ?? answer),
    );
    _openCandidateGate();
    if (command.initial) _onNegotiated();
  }

  void _onNegotiated() {
    if (_negotiated || _disposed) return;
    _negotiated = true;
    // Answered: the offer needs no more re-sending.
    for (final handle in _resendTimers) {
      _cancel(handle);
    }
    _resendTimers.clear();
    if (!_connectedOnce) {
      _update((s) => s.copyWith(status: P2PStatus.connecting));
      _connectTimer = _later(() {
        if (!_connectedOnce) {
          _fail('Could not connect the call', 'connect-timeout');
        }
      }, _timings.connectTimeoutMs);
    }
    _events.onNegotiated?.call();
  }

  // ---- connection health ---------------------------------------------------

  void _onConnectionState() {
    if (_disposed) return;
    final pc = _pc;
    if (pc == null) return;
    final state = pc.connectionState;
    if (state == _lastConn) return;
    _lastConn = state;
    _log('connection ${state.name}');

    if (state == P2PConnState.connected) {
      _cancel(_graceTimer);
      _cancel(_deadlineTimer);
      _cancel(_connectTimer);
      _graceTimer = _deadlineTimer = _connectTimer = null;
      _runIceAction(_policy.onState(state));
      _update((s) => s.copyWith(status: P2PStatus.connected));
      if (!_connectedOnce) {
        _connectedOnce = true;
        _events.onConnected?.call();
      }
      return;
    }
    if (state == P2PConnState.connecting) {
      if (_connectedOnce) {
        _update((s) => s.copyWith(status: P2PStatus.reconnecting));
      }
      return;
    }
    if (state == P2PConnState.disconnected || state == P2PConnState.failed) {
      if (_connectedOnce) {
        _update((s) => s.copyWith(status: P2PStatus.reconnecting));
      }
      _runIceAction(_policy.onState(state));
    }
  }

  void _runIceAction(IceAction action) {
    switch (action) {
      case IceWait():
        _cancel(_graceTimer);
        _graceTimer = _later(() {
          _graceTimer = null;
          _runIceAction(_policy.onGraceElapsed());
        }, action.ms);
      case IceRestart():
        _cancel(_graceTimer);
        _graceTimer = null;
        _cancel(_deadlineTimer);
        _deadlineTimer = _later(() {
          _deadlineTimer = null;
          final down = _lastConn != P2PConnState.connected;
          _runIceAction(_policy.onRestartDeadline(down));
        }, action.deadlineMs);
        _enqueue(_restartIce);
      case IceGiveUp():
        _fail('Connection lost', 'connection-failed');
      case IceRecovered():
      case IceNone():
        break;
    }
  }

  /// ICE restart with fresh TURN credentials; the policy decides when.
  Future<void> _restartIce() async {
    final pc = _pc;
    if (pc == null || _disposed) return;
    List<IceServerConfig>? fresh;
    try {
      fresh = await _deps.fetchIceServers();
    } catch (_) {
      fresh = null;
    }
    if (_disposed || _pc == null) return;
    if (fresh != null && fresh.isNotEmpty) {
      try {
        await pc.setIceServers(fresh);
      } catch (error) {
        _log('setIceServers failed', error);
      }
    }
    // A negotiation is already in flight (e.g. the peer is restarting too);
    // the restart deadline still guards the outcome.
    if (!pc.isStable) return;
    await pc.restartIce();
    await _sendOffer(true);
  }
}
