// The production wiring of [CallsCoordinator]: REST through the SDK's API
// client, peer connections through flutter_webrtc, rooms through LiveKit, the
// native call UI through flutter_callkit_incoming and the ringtone through
// audioplayers.

import 'package:flutter/widgets.dart';

import '../networking/api_client.dart';
import 'audioplayers_call_tone_player.dart';
import 'call_api.dart';
import 'calls_coordinator.dart';
import 'flutter_native_call_ui.dart';
import 'livekit_room_session.dart';
import 'p2p/p2p_webrtc.dart';

CallsCoordinator createPlatformCallsCoordinator({
  required CallsHost host,
  required ApiClient api,
}) {
  final cfg = host.videoCalls;
  final on = cfg?.enabled == true;
  final coordinator = CallsCoordinator(
    host: host,
    api: RestCallApi(api, log: host.log),
    p2pDeps: ({
      required fetchIce,
      required sendSignal,
      required log,
    }) =>
        WebRtcCallDeps(
            fetchIce: fetchIce, sendSignalFn: sendSignal, logFn: log),
    livekit: LiveKitRoomSession.new,
    nativeUi: on && cfg?.nativeCallUi != false ? FlutterNativeCallUi() : null,
    tonePlayer:
        on && cfg?.ringtone != false ? AudioplayersCallTonePlayer() : null,
    appResumed: _appIsResumed,
  );
  if (on) {
    // A ring that is up when the app goes to the background moves to the
    // native call UI; coming back moves it in-app again.
    final observer = _LifecycleObserver(coordinator.onAppLifecycleChanged);
    try {
      WidgetsBinding.instance.addObserver(observer);
      coordinator.addDisposeHook(
        () => WidgetsBinding.instance.removeObserver(observer),
      );
    } catch (_) {
      // No widgets binding (a plain Dart isolate): nothing to observe.
    }
  }
  return coordinator;
}

bool _appIsResumed() {
  try {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  } catch (_) {
    return true;
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._onChanged);
  final void Function() _onChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onChanged();
}
