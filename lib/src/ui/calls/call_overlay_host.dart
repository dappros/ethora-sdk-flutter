import 'package:flutter/material.dart';

import '../../calls/call_state.dart';
import '../../calls/calls_coordinator.dart';
import '../../core/chat_component_controller.dart';
import '../../models/chat_component_config.dart';
import 'call_screens.dart';

/// Stacks the call screens over [child]: the incoming-call ring (accept /
/// decline), the outgoing "calling" screen, the active call (local and remote
/// video, mute, camera, flip, speaker, end; audio-only and group layouts) and
/// the call error card. Place it once, above the whole chat UI, so an
/// incoming call rings on any screen.
///
/// With `config.videoCalls` off (the default) it returns [child] untouched.
class CallOverlayHost extends StatelessWidget {
  const CallOverlayHost({
    super.key,
    required this.controller,
    required this.config,
    required this.child,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (config.videoCalls?.enabled != true) return child;
    final calls = controller.calls;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: child),
        Positioned.fill(
          child: ListenableBuilder(
            listenable: calls,
            builder: (context, _) {
              final state = calls.state;
              if (state.isIdle) return const SizedBox.shrink();
              return Material(
                color: Colors.black,
                child: _screenFor(calls.state, calls,
                    config.videoCalls?.showScreenShare == true),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _screenFor(
    CallSessionState state,
    CallsCoordinator calls,
    bool showScreenShare,
  ) {
    if (state.isRingingIncoming) {
      return CallRingScreen(
        state: state,
        onAccept: calls.acceptIncoming,
        onDecline: calls.declineIncoming,
      );
    }
    if (state.phase == CallPhase.error) {
      return CallRingScreen(
        state: state,
        onDismiss: calls.dismissError,
      );
    }
    final inSession =
        state.phase == CallPhase.connecting || state.phase == CallPhase.inCall;
    if (inSession) {
      final p2p = calls.p2pController;
      if (p2p != null) {
        return P2PActiveCallScreen(
          state: state,
          controller: p2p,
          onHangup: calls.hangup,
        );
      }
      final session = calls.livekitSession;
      if (session != null) {
        return LiveKitActiveCallScreen(
          state: state,
          session: session,
          onHangup: calls.hangup,
          showScreenShare: showScreenShare,
        );
      }
    }
    // Dialling, or the media runtime is not up yet.
    return CallRingScreen(
      state: state,
      onCancel: calls.hangup,
    );
  }
}
