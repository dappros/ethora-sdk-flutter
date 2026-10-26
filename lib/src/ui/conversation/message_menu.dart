import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/chat_component_controller.dart';
import '../../core/emoji.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_message.dart';
import '../../theme/chat_theme.dart';
import 'emoji_picker.dart';

/// Long-press menu of a message (web MessageInteractions): quick reaction
/// bar with the full picker, then Reply, Edit, Copy, Retry and Delete as the
/// config and the web rules allow.
Future<void> showMessageMenu(
  BuildContext context, {
  required ChatComponentController controller,
  required ChatComponentConfig config,
  required ChatMessage message,
}) async {
  if (config.disableInteractions == true) return;
  final ui = ChatUiScope.of(context);
  final theme = ui.theme;
  final strings = ui.strings;
  final reactionsOn = controller.reactionsEnabled &&
      !message.pending &&
      !message.failed &&
      !message.system;
  final quick = resolveQuickReactions(config.reactions?.quickReactions);
  final showPicker = config.reactions?.picker != false;
  final canReply = config.disableReplies != true &&
      !message.pending &&
      !message.failed &&
      !message.system;
  final canEdit = controller.canEditMessage(message);
  final canDelete = controller.canDeleteMessage(message);
  final canCopy = !message.isMedia && message.text.trim().isNotEmpty;
  final canRetry = message.failed && controller.isOwnMessage(message);

  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    backgroundColor: theme.bg,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reactionsOn)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  children: [
                    for (final id in quick)
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.of(sheetContext).pop('react:$id'),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            emojiGlyph(id),
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                      ),
                    if (showPicker)
                      IconButton(
                        tooltip: strings.t('message.menu.react'),
                        onPressed: () =>
                            Navigator.of(sheetContext).pop('picker'),
                        icon: Icon(Icons.add_reaction_outlined,
                            color: theme.icons),
                      ),
                  ],
                ),
              ),
            if (canReply)
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: Text(strings.t('message.menu.reply')),
                onTap: () => Navigator.of(sheetContext).pop('reply'),
              ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(strings.t('message.menu.edit')),
                onTap: () => Navigator.of(sheetContext).pop('edit'),
              ),
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: Text(strings.t('message.menu.copy')),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
            if (canRetry)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: Text(strings.t('message.retry')),
                onTap: () => Navigator.of(sheetContext).pop('retry'),
              ),
            if (canDelete)
              ListTile(
                leading: Icon(Icons.delete_outline, color: theme.danger),
                title: Text(
                  strings.t('action.delete'),
                  style: TextStyle(color: theme.danger),
                ),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
          ],
        ),
      );
    },
  );
  if (action == null || !context.mounted) return;

  if (action.startsWith('react:')) {
    await controller.toggleReaction(
      message.roomJid,
      message.id,
      action.substring(6),
    );
    return;
  }
  switch (action) {
    case 'picker':
      final picked = await showEmojiPicker(context);
      if (picked != null) {
        await controller.toggleReaction(message.roomJid, message.id, picked);
      }
    case 'reply':
      controller.openThread(message);
    case 'edit':
      controller.startEdit(message);
    case 'copy':
      await Clipboard.setData(ClipboardData(text: message.text));
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(strings.t('message.copied')),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    case 'retry':
      await controller.retryMessage(message.roomJid, message.id);
    case 'delete':
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: Text(strings.t('message.deleteConfirm')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.t('action.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                strings.t('action.delete'),
                style: TextStyle(color: theme.danger),
              ),
            ),
          ],
        ),
      );
      if (ok == true) await controller.deleteMessage(message);
  }
}
