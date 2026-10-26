import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/chat_component_state.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_message.dart';
import '../../models/chat_room.dart';
import '../../models/media_attachment.dart';
import '../../theme/chat_theme.dart';
import 'chat_header.dart';
import 'composer.dart';
import 'message_list.dart';
import 'thread_panel.dart';

/// Jump request the list should show (communicated by the search/jump
/// module through the controller state; see ChatComponent for the wiring).
class ConversationJump {
  const ConversationJump({
    this.messages,
    this.targetId,
    this.nonce = 0,
    this.onJumpToLatest,
  });

  /// A window of archived messages shown instead of the live list.
  final List<ChatMessage>? messages;
  final String? targetId;
  final int nonce;
  final VoidCallback? onJumpToLatest;
}

/// One open conversation: header, message list, composer and the thread
/// panel (side panel on wide screens, overlay on phones).
class ConversationPane extends StatefulWidget {
  const ConversationPane({
    super.key,
    required this.controller,
    required this.config,
    required this.state,
    required this.room,
    this.onBack,
    this.onTitleTap,
    this.headerActions = const <Widget>[],
    this.jump = const ConversationJump(),
    this.onQuoteTap,
    this.beforeComposer,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final ChatComponentState state;
  final ChatRoom? room;
  final VoidCallback? onBack;
  final VoidCallback? onTitleTap;
  final List<Widget> headerActions;
  final ConversationJump jump;
  final ValueChanged<String>? onQuoteTap;

  /// Slot between the list and the composer (offline banner, etc.).
  final Widget? beforeComposer;

  @override
  State<ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends State<ConversationPane> {
  final TextEditingController _text = TextEditingController();
  String? _editingId;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final draft = widget.state.editDraft;
    if (draft != null && draft.messageId != _editingId) {
      _editingId = draft.messageId;
      _text.text = draft.text;
      _text.selection = TextSelection.collapsed(offset: draft.text.length);
    } else if (draft == null && _editingId != null) {
      _editingId = null;
      _text.clear();
    }
  }

  List<ChatMessage> _mainList(List<ChatMessage> source) {
    return source
        .where((m) => !m.isDeleted && (m.showInChannel || !m.isReply))
        .toList();
  }

  Future<void> _pickAndSend() async {
    final room = widget.room;
    if (room == null) return;
    final config = widget.config;
    final limits = config.attachments;
    final maxFiles = (limits?.maxFiles ?? kMaxAttachmentsPerMessage)
        .clamp(1, kMaxAttachmentsPerMessage);
    final sizeCapMb = limits?.maxFileSizeMb;
    final sizeCapBytes =
        sizeCapMb == null ? null : (sizeCapMb * 1024 * 1024).round();

    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    final files = picked?.files ?? const <PlatformFile>[];
    final oversized = <String>[];
    var droppedForCount = false;
    final accepted = <MediaFileInput>[];
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      if (sizeCapBytes != null && file.size > sizeCapBytes) {
        oversized.add(file.name);
        continue;
      }
      if (accepted.length >= maxFiles) {
        droppedForCount = true;
        continue;
      }
      accepted.add(
        MediaFileInput(
          bytes: bytes,
          filename: file.name,
          mimeType: _mimeByExtension(file.extension),
        ),
      );
    }

    if (!mounted) return;
    final strings = ChatUiScope.of(context).strings;
    final notices = <String>[
      if (oversized.isNotEmpty)
        strings.t('attachment.tooLarge', {
          'files': oversized.join(', '),
          'size': sizeCapMb ?? 0,
        }),
      if (droppedForCount) strings.t('attachment.limit', {'count': maxFiles}),
    ];
    if (notices.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(notices.join(' '))));
    }
    if (accepted.isEmpty) return;

    try {
      await widget.controller.sendMediaFiles(room.jid, files: accepted);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(strings.t('attachment.uploadFailed'))),
      );
    }
  }

  String _mimeByExtension(String? ext) {
    if (ext == null) return 'application/octet-stream';
    switch (ext.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'wav':
        return 'audio/wav';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    final theme = ui.theme;
    final state = widget.state;
    final room = widget.room;
    final all = room == null
        ? const <ChatMessage>[]
        : (state.messagesByRoom[room.jid] ?? const <ChatMessage>[]);
    final shown = _mainList(widget.jump.messages ?? all);
    final draft = state.editDraft;
    final editingHere = draft != null && room != null && draft.roomJid == room.jid;
    final thread = state.activeThread;
    final threadHere = thread != null && room != null && thread.roomJid == room.jid;
    final readerLocale = widget.config.translates?.readerLocale ??
        state.user?.chatLanguage ??
        widget.config.i18n?.locale;

    final conversation = Column(
      children: [
        if (widget.config.disableHeader != true)
          ChatHeaderBar(
            config: widget.config,
            room: room,
            connection: state.connectionState,
            onBack: widget.onBack,
            onTitleTap: widget.onTitleTap,
            actions: widget.headerActions,
          ),
        if ((state.errorMessage ?? '').isNotEmpty)
          Container(
            width: double.infinity,
            color: theme.danger.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              state.errorMessage!,
              style: TextStyle(color: theme.danger),
            ),
          ),
        Expanded(
          child: Container(
            color: theme.chatBg,
            child: room == null
                ? Center(
                    child: Text(
                      ui.strings.t('rooms.selectToStart'),
                      style: TextStyle(color: theme.textSecondary),
                    ),
                  )
                : Stack(
                    children: [
                      MessageListView(
                        controller: widget.controller,
                        config: widget.config,
                        room: room,
                        messages: shown,
                        allMessages: all,
                        fileToken: state.user?.fileToken,
                        readerLocale: readerLocale,
                        jumpTargetId: widget.jump.targetId,
                        jumpNonce: widget.jump.nonce,
                        onOpenThread: widget.controller.openThread,
                        onQuoteTap: widget.onQuoteTap,
                        onLoadOlder: () =>
                            widget.controller.loadOlderMessages(room.jid),
                        emptyBuilder: (_) => _EmptyRoom(),
                      ),
                      if (widget.jump.onJumpToLatest != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 8,
                          child: Center(
                            child: FilledButton.icon(
                              onPressed: widget.jump.onJumpToLatest,
                              icon: const Icon(Icons.keyboard_double_arrow_down),
                              label: Text(ui.strings.t('action.jumpToLatest')),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        if (widget.beforeComposer != null) widget.beforeComposer!,
        if (room != null)
          ChatComposer(
            textController: _text,
            onAttach: widget.config.disableMedia == true ? null : _pickAndSend,
            onTyping: (typing) => widget.controller.setTyping(room.jid, typing),
            editingLabel: editingHere ? ui.strings.t('message.editing') : null,
            onCancelEdit: widget.controller.cancelEdit,
            onSubmit: (text) {
              _text.clear();
              if (editingHere) {
                unawaited(widget.controller.submitEdit(text));
              } else {
                widget.controller.sendText(room.jid, text);
              }
            },
          ),
      ],
    );

    if (!threadHere) return conversation;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final panel = ThreadPanel(
      controller: widget.controller,
      config: widget.config,
      state: state,
      room: room,
      fileToken: state.user?.fileToken,
      readerLocale: readerLocale,
    );
    if (wide) {
      return Row(
        children: [
          Expanded(child: conversation),
          VerticalDivider(width: 1, color: theme.border),
          SizedBox(width: 380, child: panel),
        ],
      );
    }
    return Stack(children: [conversation, Positioned.fill(child: panel)]);
  }
}

class _EmptyRoom extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: ui.theme.bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ui.theme.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mark_chat_unread_outlined,
                color: ui.theme.textMuted, size: 30),
            const SizedBox(height: 10),
            Text(
              ui.strings.t('room.empty'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: ui.theme.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              ui.strings.t('room.empty.hint'),
              style: TextStyle(color: ui.theme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
