// Call sounds: the ringtone the callee hears while the app is in the
// foreground and the ringback the caller hears while the other side rings.
//
// Which tone should play is a pure function of the call state, so it is unit
// tested; [CallToneDriver] only starts and stops the player when the answer
// changes. The player is a port: audioplayers_call_tone_player.dart holds the
// real one, and a native incoming-call UI (CallKit / the Android full-screen
// notification) plays the system ringtone itself, in which case the in-app
// ringtone stays silent.

import 'call_state.dart';
import 'call_mode.dart';

enum CallTone { ringtone, ringback }

/// The tone that should be playing for [state], or null for silence.
///
///  - incoming ring: the ringtone, unless the app is in the background or a
///    native incoming-call UI is already ringing;
///  - outgoing call: ringback while dialling, and for a LiveKit call (which
///    has no ringing signal) until the first remote participant joins. A p2p
///    call stops it when the callee answers.
CallTone? desiredCallTone(
  CallSessionState state, {
  required bool remoteJoined,
  required bool appResumed,
  required bool nativeIncomingShown,
}) {
  if (state.isRingingIncoming) {
    return appResumed && !nativeIncomingShown ? CallTone.ringtone : null;
  }
  if (!state.isOutgoing) return null;
  if (state.phase == CallPhase.requesting) return CallTone.ringback;
  final waitingForPeer = state.mode == CallMode.livekit &&
      !remoteJoined &&
      (state.phase == CallPhase.connecting || state.phase == CallPhase.inCall);
  return waitingForPeer ? CallTone.ringback : null;
}

abstract class CallTonePlayer {
  /// Loops [tone] until [stop]. [speaker] routes to the loudspeaker (a video
  /// call) instead of the earpiece (ringback of an audio call).
  Future<void> play(CallTone tone, {required bool speaker});
  Future<void> stop();
  Future<void> dispose();
}

class CallToneDriver {
  CallToneDriver(this._player, {void Function(String message)? log})
      : _log = log;

  final CallTonePlayer _player;
  final void Function(String message)? _log;
  CallTone? _current;
  bool _disposed = false;

  CallTone? get current => _current;

  /// Plays [wanted] (null stops). A tone already playing is left alone.
  void apply(CallTone? wanted, {bool speaker = true}) {
    if (_disposed || wanted == _current) return;
    _current = wanted;
    if (wanted == null) {
      _run(_player.stop());
    } else {
      _run(_player.play(wanted, speaker: speaker));
    }
  }

  void _run(Future<void> action) {
    action.catchError((Object error) {
      // A missing sound must never break a call.
      _log?.call('[call] tone failed: $error');
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _current = null;
    _run(_player.stop());
    _run(_player.dispose());
  }
}
