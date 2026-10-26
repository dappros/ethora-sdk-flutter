import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/chat_component_state.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_message.dart';
import '../../models/chat_room.dart';
import '../../theme/chat_theme.dart';
import 'composer.dart';
import 'message_bubble.dart';

/// Thread panel (web ThreadWrapper): the root message, its replies, a reply
/// composer and the "Also send to room" switch.
class ThreadPanel extends StatefulWidget {
  const ThreadPanel({
    super.key,
    required this.controller,
    required this.config,
    required this.state,
    required this.room,
    required this.fileToken,
    required this.readerLocale,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final ChatComponentState state;
  final ChatRoom? room;
  final String? fileToken;
  final String? readerLocale;

  @override
  State<ThreadPanel> createState() => _ThreadPanelState();
}

class _ThreadPanelState extends State<ThreadPanel> {
  final TextEditingController _text = TextEditingController();
  bool _alsoSendToRoom = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    final theme = ui.theme;
    final thread = widget.state.activeThread;
    if (thread == null) return const SizedBox.shrink();
    final root = widget.controller.messageById(thread.roomJid, thread.rootId);
    final replies =
        widget.controller.threadRepliesOf(thread.roomJid, thread.rootId);

    return Material(
      color: theme.bg,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.border)),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: ui.strings.t('action.close'),
                  onPressed: widget.controller.closeThread,
                  icon: Icon(Icons.close, color: theme.icons),
                ),
                Expanded(
                  child: Text(
                    ui.strings.t('thread.title'),
                    style: TextStyle(
                      color: theme.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: root == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _bubble(root),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Divider(color: theme.border),
                      ),
                      for (final reply in replies) _bubble(reply),
                    ],
                  ),
          ),
          ChatComposer(
            textController: _text,
            hint: ui.strings.t('thread.placeholder'),
            onTyping: (typing) =>
                widget.controller.setTyping(thread.roomJid, typing),
            onSubmit: (text) {
              _text.clear();
              widget.controller.sendThreadReply(
                text,
                alsoSendToRoom: _alsoSendToRoom,
              );
            },
            footer: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: () => setState(() => _alsoSendToRoom = !_alsoSendToRoom),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          value: _alsoSendToRoom,
                          onChanged: (v) =>
                              setState(() => _alsoSendToRoom = v ?? false),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${ui.strings.t('thread.alsoSendTo')} ${widget.room?.title ?? ''}'
                              .trim(),
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(ChatMessage message) {
    return MessageBubbleView(
      message: message,
      isMine: widget.controller.isOwnMessage(message),
      controller: widget.controller,
      config: widget.config,
      inThread: true,
      fileToken: widget.fileToken,
      readerLocale: widget.readerLocale,
    );
  }
}
