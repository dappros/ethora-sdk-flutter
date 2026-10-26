// ICE restart policy for a p2p call (web calls/p2p/icePolicy.ts), kept apart
// from the peer connection so it can be reasoned about and tested on its own.
// The controller feeds it the connection state and runs the timers; the
// policy only decides.
//
//  - `disconnected` is often transient (a Wi-Fi blip heals by itself), so the
//    first reaction is to wait a grace period and restart only if it has not
//    recovered;
//  - `failed` is terminal for that ICE session, so restart straight away;
//  - one restart per outage, and a small cap per call so a flapping network
//    ends in a clean failure instead of an endless loop;
//  - a restart that does not bring the connection back within a deadline
//    gives up.

enum P2PConnState {
  newState,
  connecting,
  connected,
  disconnected,
  failed,
  closed
}

sealed class IceAction {
  const IceAction();
}

class IceNone extends IceAction {
  const IceNone();
}

/// Re-check with [IceRestartPolicy.onGraceElapsed] after [ms].
class IceWait extends IceAction {
  const IceWait(this.ms);
  final int ms;
}

/// Restart; call [IceRestartPolicy.onRestartDeadline] after [deadlineMs].
class IceRestart extends IceAction {
  const IceRestart(this.deadlineMs);
  final int deadlineMs;
}

class IceRecovered extends IceAction {
  const IceRecovered();
}

class IceGiveUp extends IceAction {
  const IceGiveUp(this.reason);
  final String reason;
}

class IceRestartPolicy {
  IceRestartPolicy({
    int graceMs = 3000,
    int restartDeadlineMs = 15000,
    int maxRestartsPerCall = 3,
  })  : _graceMs = graceMs,
        _restartDeadlineMs = restartDeadlineMs,
        _maxRestarts = maxRestartsPerCall;

  final int _graceMs;
  final int _restartDeadlineMs;
  final int _maxRestarts;
  int _restarts = 0;
  bool _attemptedThisOutage = false;
  bool _inOutage = false;

  int get restartCount => _restarts;

  IceAction _tryRestart() {
    if (_attemptedThisOutage) return const IceGiveUp('restart-did-not-recover');
    if (_restarts >= _maxRestarts) return const IceGiveUp('too-many-restarts');
    _attemptedThisOutage = true;
    _restarts += 1;
    return IceRestart(_restartDeadlineMs);
  }

  IceAction onState(P2PConnState state) {
    switch (state) {
      case P2PConnState.connected:
        final wasOutage = _inOutage;
        _inOutage = false;
        _attemptedThisOutage = false;
        return wasOutage ? const IceRecovered() : const IceNone();
      case P2PConnState.disconnected:
        _inOutage = true;
        if (_attemptedThisOutage) return const IceNone();
        return IceWait(_graceMs);
      case P2PConnState.failed:
        _inOutage = true;
        return _tryRestart();
      case P2PConnState.newState:
      case P2PConnState.connecting:
      case P2PConnState.closed:
        return const IceNone();
    }
  }

  /// The grace period after `disconnected` ran out without recovery.
  IceAction onGraceElapsed() {
    if (!_inOutage) return const IceNone();
    return _tryRestart();
  }

  /// The restart deadline ran out; [stillDown] is the state at that moment.
  IceAction onRestartDeadline(bool stillDown) =>
      stillDown ? const IceGiveUp('restart-timeout') : const IceNone();
}
