import 'package:flutter/material.dart';

import '../../core/chat_component_state.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_room.dart';
import '../../models/chat_user.dart';
import '../../theme/chat_theme.dart';
import 'ui_helpers.dart';

/// Conversation header: back, avatar, title with a status line (typing, user
/// count, connection) and the action buttons given by the host layout.
class ChatHeaderBar extends StatelessWidget {
  const ChatHeaderBar({
    super.key,
    required this.config,
    required this.room,
    required this.connection,
    this.onBack,
    this.onTitleTap,
    this.actions = const <Widget>[],
  });

  final ChatComponentConfig config;
  final ChatRoom? room;
  final ChatConnectionState connection;
  final VoidCallback? onBack;
  final VoidCallback? onTitleTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    final theme = ui.theme;
    final strings = ui.strings;
    final title = (room == null
            ? null
            : config.chatHeaderSettings?.roomTitleOverrides[room!.jid]) ??
        room?.title ??
        strings.t('room.noSelected');

    final String status;
    if (room != null && room!.composingList.isNotEmpty) {
      status = strings.t('rooms.typing', {'names': room!.composingList.join(', ')});
    } else if (connection != ChatConnectionState.online) {
      status = strings.t(switch (connection) {
        ChatConnectionState.connecting => 'connection.connecting',
        ChatConnectionState.error => 'connection.error',
        _ => 'connection.offline',
      });
    } else if (room != null &&
        config.disableUserCount != true &&
        room!.displayUserCount > 0) {
      final count = room!.displayUserCount;
      status = strings.t(
        count == 1 ? 'header.userCountSingular' : 'header.userCountPlural',
        {'count': count},
      );
    } else {
      status = strings.t('connection.online');
    }
    final statusColor = room != null && room!.composingList.isNotEmpty
        ? theme.primaryText
        : switch (connection) {
            ChatConnectionState.online => theme.textMuted,
            ChatConnectionState.connecting => theme.textMuted,
            ChatConnectionState.error => theme.danger,
            ChatConnectionState.offline => theme.danger,
          };

    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      decoration: BoxDecoration(
        color: theme.bg,
        border: Border(bottom: BorderSide(color: theme.border)),
      ),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              tooltip: strings.t('header.action.back'),
              onPressed: onBack,
              icon: Icon(Icons.arrow_back, color: theme.icons),
            )
          else
            const SizedBox(width: 8),
          if (room != null) ...[
            ChatAvatar(
              user: ChatUser(photoUrl: room!.picture),
              nameOverride: title,
              radius: 18,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: InkWell(
              onTap: onTitleTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: statusColor, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
