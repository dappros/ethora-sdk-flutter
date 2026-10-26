import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../i18n/chat_i18n.dart';
import '../../models/chat_room.dart';
import '../../models/media_attachment.dart';
import '../../networking/secure_file_url.dart';
import '../../theme/chat_theme.dart';

/// Theme and strings of the SDK scope above a context.
extension ChatUiContext on BuildContext {
  ChatTheme get chatTheme => ChatUiScope.of(this).theme;
  ChatStrings get chatStrings => ChatUiScope.of(this).strings;
}

/// Carries a [ChatUiScope] (and the matching Material theme) into a route
/// that was pushed on the host's navigator, where the scope of the widget
/// that opened it is not an ancestor.
class ChatScopeBridge extends StatelessWidget {
  const ChatScopeBridge({super.key, required this.scope, required this.child});

  final ChatUiScope scope;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ChatUiScope(
      theme: scope.theme,
      strings: scope.strings,
      child: Theme(
        data: scope.theme.toThemeData(),
        child: Builder(
          builder: (context) => scope.theme.scopeText(context, child),
        ),
      ),
    );
  }
}

/// A modal bottom sheet in the SDK's theme and language. [builder] gets a
/// context that sees the scope.
Future<T?> showChatSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool fullHeight = false,
}) {
  final scope = ChatUiScope.of(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: scope.theme.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    constraints: fullHeight
        ? BoxConstraints(maxHeight: MediaQuery.of(context).size.height)
        : null,
    builder: (sheetContext) => ChatScopeBridge(
      scope: scope,
      child: Builder(
        builder: (inner) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(inner).viewInsets.bottom,
          ),
          child: Builder(builder: builder),
        ),
      ),
    ),
  );
}

/// A dialog in the SDK's theme and language.
Future<T?> showChatDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final scope = ChatUiScope.of(context);
  return showDialog<T>(
    context: context,
    builder: (_) => ChatScopeBridge(
      scope: scope,
      child: Builder(builder: builder),
    ),
  );
}

/// Asks for a yes or no. [destructive] paints the confirm button as danger.
Future<bool> confirmChatAction(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final answer = await showChatDialog<bool>(
    context,
    builder: (dialogContext) {
      final theme = dialogContext.chatTheme;
      final strings = dialogContext.chatStrings;
      return AlertDialog(
        backgroundColor: theme.bg,
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.t('action.cancel')),
          ),
          TextButton(
            style: destructive
                ? TextButton.styleFrom(foregroundColor: theme.danger)
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return answer == true;
}

/// A short message on the nearest scaffold messenger, if there is one.
void showChatSnack(BuildContext context, String text) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// The title row of a sheet: [title], and a close button.
class ChatSheetTitleBar extends StatelessWidget {
  const ChatSheetTitleBar({
    super.key,
    required this.title,
    this.leading,
    this.actions = const <Widget>[],
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 8),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 4)],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: theme.text,
              ),
            ),
          ),
          ...actions,
          IconButton(
            tooltip: strings.t('action.close'),
            icon: Icon(Icons.close_rounded, color: theme.textSecondary),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

/// The initials of a name: first letters of its first two words.
String roomInitials(String name) {
  final words =
      name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '#';
  final first = String.fromCharCode(words.first.runes.first).toUpperCase();
  if (words.length == 1) return first;
  final second = String.fromCharCode(words[1].runes.first).toUpperCase();
  return '$first$second';
}

/// A round avatar: the picture when there is one, else initials.
class RoomAvatar extends StatelessWidget {
  const RoomAvatar({
    super.key,
    required this.name,
    this.url,
    this.fileToken,
    this.size = 44,
    this.icon,
  });

  final String name;
  final String? url;
  final String? fileToken;
  final double size;

  /// Shown instead of the initials when there is no picture.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.primarySoft,
        shape: BoxShape.circle,
      ),
      child: icon != null
          ? Icon(icon, size: size * 0.5, color: theme.primaryText)
          : Text(
              roomInitials(name),
              style: TextStyle(
                color: theme.primaryText,
                fontWeight: FontWeight.w600,
                fontSize: size * 0.36,
              ),
            ),
    );
    final src = appendFileToken(url, fileToken);
    if (src.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        src,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

/// Title shown for a room: a host override, else the room's title, else its JID.
String roomDisplayTitle(
  ChatRoom room, {
  Map<String, String> overrides = const <String, String>{},
}) {
  final override = overrides[room.jid];
  if (override != null && override.trim().isNotEmpty) return override;
  final title = room.title?.trim() ?? '';
  return title.isEmpty ? room.jid : title;
}

/// Unread count as a badge shows it: `+` when the count is only a floor.
String unreadBadgeText(int count, {required bool capped}) =>
    capped ? '$count+' : '$count';

/// A small round count badge.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.text, this.muted = false});

  final String text;

  /// A muted room's badge is grey: it still counts, but does not call.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? theme.textMuted : theme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: theme.textOnPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Lets the reader pick a picture for a room. Null when they cancel or the
/// platform gave no bytes. [picker] is for tests.
Future<MediaFileInput?> pickRoomImage({
  Future<FilePickerResult?> Function()? picker,
}) async {
  final result = await (picker?.call() ??
      FilePicker.platform.pickFiles(type: FileType.image, withData: true));
  final files = result?.files ?? const <PlatformFile>[];
  if (files.isEmpty) return null;
  final file = files.first;
  final bytes = file.bytes;
  if (bytes == null) return null;
  final mime = mimeTypeForFilename(file.name);
  return MediaFileInput(
    bytes: bytes,
    filename: file.name,
    mimeType: mime == 'application/octet-stream' ? 'image/jpeg' : mime,
  );
}

/// The padlock of an end-to-end encrypted room.
class RoomLockBadge extends StatelessWidget {
  const RoomLockBadge({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    return Tooltip(
      message: context.chatStrings.t('e2ee.roomEncrypted'),
      child:
          Icon(Icons.lock_outline_rounded, size: size, color: theme.textMuted),
    );
  }
}
