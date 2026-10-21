// Ties the call state to the native call UI.
//
//  - A call that rings while the app is NOT in the foreground is shown on the
//    native UI (CallKit / full-screen notification) instead of an overlay
//    nobody can see; in the foreground the in-app screen is used.
//  - Once a call is being set up the native layer is told, so Android keeps
//    the process alive with an ongoing-call foreground service (microphone
//    and camera access survive going to the home screen).
//  - The native accept / decline / hang-up buttons drive the call, including
//    an accept after a cold start (the push data round-trips through the
//    native layer).
//
// Pure Dart over [NativeCallUi], so every rule is unit tested.

import 'dart:async';

import 'call_mode.dart';
import 'call_state.dart';
import 'native_call_ui.dart';

class CallNativeHandlers {
  const CallNativeHandlers({
    required this.onAccept,
    required this.onDecline,
    required this.onEnded,
    required this.onTimeout,
    required this.onRestored,
  });

  /// The user accepted on the native UI. [extra] is the push data.
  final void Function(String callId, Map<String, dynamic> extra) onAccept;
  final void Function(String callId, Map<String, dynamic> extra) onDecline;

  /// Hung up from the native UI / ongoing notification.
  final void Function(String callId) onEnded;

  /// The native ring timed out unanswered.
  final void Function(String callId) onTimeout;

  /// A call the native layer still had on a cold start, not yet accepted.
  final void Function(Map<String, dynamic> extra) onRestored;
}

class CallNativeBridge {
  CallNativeBridge({
    required NativeCallUi ui,
    required bool Function() appResumed,
    required CallNativeHandlers handlers,
    void Function(String message)? log,
  })  : _ui = ui,
        _appResumed = appResumed,
        _handlers = handlers,
        _log = log;

  final NativeCallUi _ui;
  final bool Function() _appResumed;
  final CallNativeHandlers _handlers;
  final void Function(String message)? _log;

  StreamSubscription<NativeCallEvent>? _subscription;
  // Calls whose incoming UI is up natively.
  final Set<String> _ringing = <String>{};
  // Calls the user accepted on the native UI (its service is already up).
  final Set<String> _acceptedNatively = <String>{};
  // Calls registered as ongoing / reported connected.
  final Set<String> _ongoing = <String>{};
  final Set<String> _connected = <String>{};
  // Calls we ended ourselves: the platform echoes an "ended" event for them.
  final Set<String> _ending = <String>{};
  CallSessionState _last = CallSessionState.idle;
  NativeCallInfo? _lastInfo;
  bool _disposed = false;

  /// Whether the native ring for [callId] is up (the in-app ringtone stays
  /// silent then).
  bool isRingingNatively(String? callId) =>
      callId != null && _ringing.contains(callId);

  /// Starts listening and picks up calls the native layer kept across a cold
  /// start (an accept tapped before the app finished launching).
  Future<void> start() async {
    _subscription ??= _ui.events.listen(_onEvent, onError: (Object error) {
      _log?.call('[call] native event failed: $error');
    });
    try {
      for (final info in await _ui.activeCalls()) {
        if (info.callId.isEmpty) continue;
        _ringing.add(info.callId);
        if (info.accepted) {
          _acceptedNatively.add(info.callId);
          _handlers.onAccept(info.callId, info.extra);
        } else {
          _handlers.onRestored(info.extra);
        }
      }
    } catch (error) {
      _log?.call('[call] native active calls failed: $error');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _subscription?.cancel();
    _subscription = null;
  }

  // ---- native -> call ------------------------------------------------------

  void _onEvent(NativeCallEvent event) {
    if (_disposed) return;
    final callId = event.callId;
    if (callId == null || callId.isEmpty) return;
    switch (event.type) {
      case NativeCallEventType.accept:
        _acceptedNatively.add(callId);
        _handlers.onAccept(callId, event.extra);
      case NativeCallEventType.decline:
        _ringing.remove(callId);
        _handlers.onDecline(callId, event.extra);
      case NativeCallEventType.ended:
        // The echo of an end we asked for is not the user hanging up.
        if (_ending.remove(callId)) return;
        _forget(callId);
        _handlers.onEnded(callId);
      case NativeCallEventType.timeout:
        _ringing.remove(callId);
        _handlers.onTimeout(callId);
    }
  }

  void _forget(String callId) {
    _ringing.remove(callId);
    _acceptedNatively.remove(callId);
    _ongoing.remove(callId);
    _connected.remove(callId);
  }

  // ---- call -> native ------------------------------------------------------

  static String _keyOf(CallSessionState s) =>
      (s.callId ?? '').isNotEmpty ? s.callId! : 'dial-${s.startedAt ?? 0}';

  NativeCallInfo _infoOf(CallSessionState s) {
    final person = (s.callerName ?? '').isNotEmpty
        ? s.callerName!
        : ((s.roomName ?? '').isNotEmpty ? s.roomName! : '');
    return NativeCallInfo(
      callId: _keyOf(s),
      callerName: person,
      roomName: s.roomName ?? '',
      kind: s.kind,
      isGroup: s.isGroup,
      extra: <String, dynamic>{
        'callId': _keyOf(s),
        'callRoom': s.roomBareName ?? '',
        'callKind': s.kind.name,
        'mode': s.mode.name,
        'group': s.isGroup,
        'callerName': s.callerName ?? '',
        'callerXmppUsername': s.callerXmppUsername ?? s.peerXmppUsername ?? '',
        'type': 'call',
      },
    );
  }

  /// Call after every state change.
  void onStateChanged(CallSessionState next) {
    if (_disposed) return;
    final prev = _last;
    _last = next;
    final prevKey = prev.isIdle ? null : _keyOf(prev);
    final nextKey = next.isIdle ? null : _keyOf(next);

    // The call this bridge was following is over (or replaced): dismiss it.
    if (prevKey != null && prevKey != nextKey) {
      _dismiss(prevKey, _lastInfo);
    }
    if (next.isIdle) {
      _lastInfo = null;
      return;
    }
    final info = _infoOf(next);
    _lastInfo = info;

    if (next.phase == CallPhase.error) {
      _dismiss(nextKey!, info);
      return;
    }

    if (next.isRingingIncoming) {
      // Ringing while the app cannot be seen: use the native UI.
      if (!_appResumed() && !_ringing.contains(info.callId)) {
        _ringing.add(info.callId);
        _run(_ui.showIncoming(info));
      }
      return;
    }

    final inSetup =
        next.phase == CallPhase.connecting || next.phase == CallPhase.inCall;
    if (!inSetup) return;

    // The incoming UI is no longer needed once the call is being set up.
    if (_ringing.remove(info.callId) &&
        !_acceptedNatively.contains(info.callId)) {
      _ending.add(info.callId);
      _run(_ui.end(info));
    }
    // Keep the process alive (Android). A native accept already did.
    if (_ongoing.add(info.callId) && !_acceptedNatively.contains(info.callId)) {
      _run(_ui.startOngoing(info));
    }
    if (next.phase == CallPhase.inCall && _connected.add(info.callId)) {
      _run(_ui.markConnected(info));
    }
  }

  /// The app moved to the background or foreground: a call that is still
  /// ringing in-app moves to the native UI.
  void onLifecycleChanged(CallSessionState current) {
    if (current.isRingingIncoming) onStateChanged(current);
  }

  void _dismiss(String key, NativeCallInfo? info) {
    final known = _ringing.contains(key) ||
        _ongoing.contains(key) ||
        _acceptedNatively.contains(key);
    _forget(key);
    if (!known) return;
    _ending.add(key);
    final target = info != null && info.callId == key
        ? info
        : NativeCallInfo(callId: key, callerName: '', kind: CallKind.video);
    _run(_ui.end(target));
  }

  void _run(Future<void> action) {
    action.catchError((Object error) {
      _log?.call('[call] native call UI failed: $error');
    });
  }
}
