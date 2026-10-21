import 'package:flutter/material.dart';

import '../../calls/call_mode.dart';
import '../../core/chat_component_controller.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_room.dart';
import '../../theme/chat_theme.dart';

/// The video (and, when `videoCalls.enableAudioCalls` is on, audio) call
/// buttons for a chat header. Renders nothing when calls are off or the
/// room type is not allowed (`videoCalls.allowedRoomTypes`, default private
/// and group chats). While another call is running, or the LiveKit URL is
/// missing, the buttons are disabled and say why in their tooltip.
class CallHeaderButtons extends StatelessWidget {
  const CallHeaderButtons({
    super.key,
    required this.controller,
    required this.config,
    required this.room,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final ChatRoom room;

  @override
  Widget build(BuildContext context) {
    final cfg = config.videoCalls;
    if (cfg == null ||
        !cfg.enabled ||
        !isCallRoomTypeAllowed(room.type, cfg.allowedRoomTypes)) {
      return const SizedBox.shrink();
    }
    final calls = controller.calls;
    final scope = ChatUiScope.of(context);
    final strings = scope.strings;
    final iconColor = scope.theme.icons;

    return ListenableBuilder(
      listenable: calls,
      builder: (context, _) {
        final String? disabledReason = !cfg.hasLivekitUrl
            ? strings.t('call.disabled.noLivekit')
            : calls.isBusy
                ? strings.t('call.disabled.busy')
                : null;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: disabledReason ?? strings.t('action.videoCall'),
              icon: Icon(Icons.videocam_outlined, color: iconColor),
              disabledColor: scope.theme.textMuted,
              onPressed: disabledReason != null
                  ? null
                  : () => calls.startCall(room, CallKind.video),
            ),
            if (cfg.enableAudioCalls)
              IconButton(
                tooltip: disabledReason ?? strings.t('action.audioCall'),
                icon: Icon(Icons.call_outlined, color: iconColor),
                disabledColor: scope.theme.textMuted,
                onPressed: disabledReason != null
                    ? null
                    : () => calls.startCall(room, CallKind.audio),
              ),
          ],
        );
      },
    );
  }
}
