import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/emoji.dart';
import '../../core/message_reference.dart';
import '../../core/receipts.dart';
import '../../core/translation.dart';
import '../../i18n/chat_i18n.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_message.dart';
import '../../models/media_attachment.dart';
import '../../theme/chat_theme.dart';
import '../media/message_attachments.dart';
import 'message_menu.dart';
import 'ui_helpers.dart';

/// One chat bubble: avatar, name, quote, body (text, translation or media),
/// time, edited label, delivery ticks, reaction chips and the thread pill.
class MessageBubbleView extends StatefulWidget {
  const MessageBubbleView({
    super.key,
    required this.message,
    required this.isMine,
    required this.controller,
    required this.config,
    this.receipt,
    this.highlighted = false,
    this.threadReplyCount = 0,
    this.fileToken,
    this.readerLocale,
    this.inThread = false,
    this.onOpenThread,
    this.onQuoteTap,
  });

  final ChatMessage message;
  final bool isMine;
  final ChatComponentController controller;
  final ChatComponentConfig config;
  final ReceiptState? receipt;
  final bool highlighted;
  final int threadReplyCount;
  final String? fileToken;
  final String? readerLocale;

  /// True inside the thread panel (no thread pill, no quote).
  final bool inThread;
  final VoidCallback? onOpenThread;
  final ValueChanged<String>? onQuoteTap;

  @override
  State<MessageBubbleView> createState() => _MessageBubbleViewState();
}

class _MessageBubbleViewState extends State<MessageBubbleView> {
  bool _showOriginal = false;
  bool _manualRevealed = false;
  bool _translating = false;
  bool _translateFailed = false;
  String? _manualText;

  ChatMessage get message => widget.message;

  Future<void> _revealManually(ResolvedMessageTranslation resolved) async {
    final translates = widget.config.translates;
    final hook = translates?.onTranslate;
    if (hook != null) {
      setState(() {
        _translating = true;
        _translateFailed = false;
      });
      try {
        final text = await hook(
          message.text,
          ChatTranslateContext(
            sourceLocale: message.langSource,
            targetLocale: widget.readerLocale ?? 'en',
            messageId: message.id,
          ),
        );
        if (!mounted) return;
        setState(() {
          _manualText = text;
          _manualRevealed = text.trim().isNotEmpty;
          _translateFailed = text.trim().isEmpty;
          _translating = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _translating = false;
          _translateFailed = true;
        });
      }
      return;
    }
    setState(() {
      _manualText = resolved.displayText;
      _manualRevealed = resolved.hasTranslation;
      _translateFailed = !resolved.hasTranslation;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    final theme = ui.theme;
    final strings = ui.strings;
    final isMine = widget.isMine;
    final bg = widget.highlighted
        ? theme.primarySoft
        : (isMine ? theme.ownMessageBackground : theme.otherMessageBackground);
    final reactions = _groupReactions();
    final quote = (!widget.inThread && message.isReply && message.showInChannel)
        ? parseMessageReference(message.mainMessage)
        : null;

    final bubble = Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMine ? 16 : 4),
          bottomRight: Radius.circular(isMine ? 4 : 16),
        ),
        border: Border.all(
          color: widget.highlighted ? theme.primary : theme.border,
          width: widget.highlighted ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMine)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                message.user.displayName,
                style: TextStyle(
                  color: theme.primaryText,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          if (quote != null) _buildQuote(theme, quote),
          _buildBody(theme, strings),
          const SizedBox(height: 4),
          _buildFooter(theme, strings),
        ],
      ),
    );

    final interactive = widget.config.disableInteractions != true;
    final tappable = GestureDetector(
      onLongPress: interactive
          ? () => showMessageMenu(
                context,
                controller: widget.controller,
                config: widget.config,
                message: message,
              )
          : null,
      child: bubble,
    );

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(context).width * 0.82).clamp(220, 580),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isMine) ...[
                ChatAvatar(user: message.user),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment:
                      isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    tappable,
                    if (reactions.isNotEmpty) _buildReactions(theme, strings, reactions),
                    if (!widget.inThread &&
                        !message.isReply &&
                        widget.threadReplyCount > 0)
                      _buildThreadPill(theme, strings),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuote(ChatTheme theme, MessageReference ref) {
    return GestureDetector(
      onTap: ref.id == null ? null : () => widget.onQuoteTap?.call(ref.id!),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: theme.bgSubtle,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: theme.primary, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((ref.userName ?? '').isNotEmpty)
              Text(
                ref.userName!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: theme.primaryText,
                ),
              ),
            Text(
              ref.text ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: theme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ChatTheme theme, ChatStrings strings) {
    if (message.isMedia) {
      final caption = (message.data['caption'] ?? '').trim();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MessageAttachments(
            attachments: messageAttachments(message),
            fileToken: widget.fileToken,
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(caption, style: TextStyle(color: theme.text)),
            ),
        ],
      );
    }

    final translates = widget.config.translates;
    final translatable = translates?.enabled == true && !widget.isMine;
    final resolved = translatable
        ? resolveMessageTranslation(message, widget.readerLocale)
        : null;
    var text = message.text;
    Widget? link;
    if (resolved != null) {
      final manual = translates!.mode == 'manual';
      if (!manual) {
        if (resolved.hasTranslation) {
          text = _showOriginal ? resolved.originalText : resolved.displayText;
          link = _linkText(
            theme,
            _showOriginal
                ? strings.t('action.translate')
                : strings.t('action.showOriginal'),
            () => setState(() => _showOriginal = !_showOriginal),
          );
        }
      } else {
        final show = translates.showTranslateForMessage != null
            ? translates.showTranslateForMessage!(message)
            : resolved.needsTranslation &&
                (resolved.hasTranslation || translates.onTranslate != null);
        if (show) {
          if (_manualRevealed && !_showOriginal) {
            text = _manualText ?? text;
            link = _linkText(
              theme,
              strings.t('action.showOriginal'),
              () => setState(() => _showOriginal = true),
            );
          } else if (_manualRevealed && _showOriginal) {
            link = _linkText(
              theme,
              strings.t('action.translate'),
              () => setState(() => _showOriginal = false),
            );
          } else if (_translating) {
            link = _linkText(theme, strings.t('translation.translating'), null);
          } else {
            link = _linkText(
              theme,
              _translateFailed
                  ? strings.t('translation.failed')
                  : strings.t('action.translate'),
              () => _revealManually(resolved),
            );
          }
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: TextStyle(color: theme.text, fontSize: 15)),
        if (link != null) link,
      ],
    );
  }

  Widget _linkText(ChatTheme theme, String label, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          label,
          style: TextStyle(
            color: theme.primaryText,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ChatTheme theme, ChatStrings strings) {
    final muted = theme.textMuted;
    final children = <Widget>[
      Text(
        formatClock(message.createdAtMs),
        style: TextStyle(fontSize: 10, color: muted),
      ),
    ];
    if (message.isEdited) {
      children.add(const SizedBox(width: 6));
      children.add(
        Text(
          '(${strings.t('message.edited')})',
          style: TextStyle(fontSize: 10, color: muted),
        ),
      );
    }
    if (message.failed) {
      children.add(const SizedBox(width: 6));
      children.add(
        GestureDetector(
          onTap: () => widget.controller
              .retryMessage(message.roomJid, message.id),
          child: Text(
            strings.t('message.failedTapToRetry'),
            style: TextStyle(
              fontSize: 10,
              color: theme.danger,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    } else if (message.pending) {
      children.add(const SizedBox(width: 6));
      children.add(
        Text(
          strings.t('message.sending'),
          style: TextStyle(
            fontSize: 10,
            color: muted,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    } else if (widget.isMine && !message.system) {
      children.add(const SizedBox(width: 4));
      children.add(_tick(theme, strings));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _tick(ChatTheme theme, ChatStrings strings) {
    final receipt = widget.receipt;
    final seen = receipt?.seen ?? false;
    final delivered = receipt?.delivered ?? false;
    final label = seen
        ? strings.t('message.receipt.read')
        : delivered
            ? strings.t('message.receipt.delivered')
            : strings.t('message.receipt.sent');
    return Tooltip(
      message: label,
      child: Icon(
        delivered || seen ? Icons.done_all : Icons.done,
        size: 14,
        color: seen ? theme.primary : theme.textMuted,
      ),
    );
  }

  /// emoji shortcode -> reactors (key, reaction), in arrival order.
  Map<String, List<MapEntry<String, ChatReaction>>> _groupReactions() {
    final grouped = <String, List<MapEntry<String, ChatReaction>>>{};
    for (final entry in message.reactions.entries) {
      for (final emoji in entry.value.emoji) {
        if (emoji.isEmpty) continue;
        grouped
            .putIfAbsent(emoji, () => <MapEntry<String, ChatReaction>>[])
            .add(entry);
      }
    }
    return grouped;
  }

  String _reactorName(MapEntry<String, ChatReaction> entry) {
    final name = [entry.value.senderFirstName, entry.value.senderLastName]
        .where((e) => (e ?? '').isNotEmpty)
        .join(' ');
    return name.isEmpty ? entry.key : name;
  }

  Widget _buildReactions(
    ChatTheme theme,
    ChatStrings strings,
    Map<String, List<MapEntry<String, ChatReaction>>> grouped,
  ) {
    final me = widget.controller.state.value.user?.xmppUsername ?? '';
    final meLocal = me.split('@').first.toLowerCase();
    final interactive = widget.controller.reactionsEnabled;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final item in grouped.entries)
            _chip(
              theme,
              strings,
              emoji: item.key,
              reactors: item.value,
              mine: item.value.any((e) => e.key.toLowerCase() == meLocal),
              interactive: interactive,
            ),
        ],
      ),
    );
  }

  Widget _chip(
    ChatTheme theme,
    ChatStrings strings, {
    required String emoji,
    required List<MapEntry<String, ChatReaction>> reactors,
    required bool mine,
    required bool interactive,
  }) {
    return GestureDetector(
      onTap: interactive
          ? () => widget.controller
              .toggleReaction(message.roomJid, message.id, emoji)
          : null,
      onLongPress: () => _showReactors(strings, emoji, reactors),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: mine ? theme.primarySoft : theme.bgSubtle,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mine ? theme.primary : theme.border,
          ),
        ),
        child: Text(
          '${emojiGlyph(emoji)} ${reactors.length}',
          style: TextStyle(fontSize: 13, color: theme.text),
        ),
      ),
    );
  }

  void _showReactors(
    ChatStrings strings,
    String emoji,
    List<MapEntry<String, ChatReaction>> reactors,
  ) {
    final names = reactors.map(_reactorName).toList();
    final glyph = emojiGlyph(emoji);
    final String text;
    if (names.length == 1) {
      text = strings.t('reaction.tooltip.one', {'name': names[0], 'emoji': glyph});
    } else if (names.length == 2) {
      text = strings.t('reaction.tooltip.two',
          {'first': names[0], 'second': names[1], 'emoji': glyph});
    } else {
      final others = names.length - 2;
      text = strings.t(
        others == 1 ? 'reaction.tooltip.other' : 'reaction.tooltip.others',
        {'first': names[0], 'second': names[1], 'count': others, 'emoji': glyph},
      );
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  Widget _buildThreadPill(ChatTheme theme, ChatStrings strings) {
    final count = widget.threadReplyCount;
    final label = count == 1
        ? strings.t('message.replyCountOne')
        : strings.t('message.replyCountOther', {'count': count});
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: GestureDetector(
        onTap: widget.onOpenThread,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: theme.bgSubtle,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined, size: 14, color: theme.primaryText),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.primaryText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
