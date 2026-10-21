import 'dart:async';

import 'package:flutter/material.dart';

import '../../calls/call_log.dart';
import '../../core/chat_component_controller.dart';
import '../../core/message_reference.dart';
import '../../core/receipts.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_message.dart';
import '../../models/chat_room.dart';
import '../../theme/chat_theme.dart';
import 'message_bubble.dart';
import 'ui_helpers.dart';

/// The scrolling list of one room: bubbles, day separators, system pills and
/// the "New Messages" marker. [messages] is oldest first and already filtered
/// for this view (main list or a jump window). A change of [jumpTargetId]
/// (or [jumpNonce]) scrolls to that message and highlights it.
class MessageListView extends StatefulWidget {
  const MessageListView({
    super.key,
    required this.controller,
    required this.config,
    required this.room,
    required this.messages,
    required this.allMessages,
    required this.fileToken,
    required this.readerLocale,
    required this.onOpenThread,
    required this.onLoadOlder,
    this.jumpTargetId,
    this.jumpNonce = 0,
    this.onQuoteTap,
    this.emptyBuilder,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final ChatRoom? room;
  final List<ChatMessage> messages;

  /// Every loaded message of the room (thread replies included), for the
  /// reply counters.
  final List<ChatMessage> allMessages;
  final String? fileToken;
  final String? readerLocale;
  final ValueChanged<ChatMessage> onOpenThread;
  final Future<bool> Function() onLoadOlder;
  final String? jumpTargetId;
  final int jumpNonce;
  final ValueChanged<String>? onQuoteTap;
  final WidgetBuilder? emptyBuilder;

  @override
  State<MessageListView> createState() => _MessageListViewState();
}

class _MessageListViewState extends State<MessageListView> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};
  bool _showScrollDown = false;
  String? _highlightId;
  Timer? _highlightTimer;
  int _handledNonce = -1;
  String? _handledTarget;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeJump());
  }

  @override
  void didUpdateWidget(MessageListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room?.jid != widget.room?.jid) {
      _keys.clear();
      _highlightId = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeJump());
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.offset > 400;
    if (show != _showScrollDown) setState(() => _showScrollDown = show);
  }

  void _maybeJump() {
    final target = widget.jumpTargetId;
    if (target == null) return;
    if (_handledTarget == target && _handledNonce == widget.jumpNonce) return;
    final index = widget.messages.indexWhere(
      (m) => m.id == target || m.xmppId == target,
    );
    if (index < 0) return;
    _handledTarget = target;
    _handledNonce = widget.jumpNonce;
    final id = widget.messages[index].id;
    _scrollToMessage(id, index, attempt: 0);
    final nonce = widget.jumpNonce;
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (mounted) widget.controller.acknowledgeJumpTarget(nonce);
    });
    _highlightTimer?.cancel();
    setState(() => _highlightId = id);
    _highlightTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  void _scrollToMessage(String id, int index, {required int attempt}) {
    if (!mounted || attempt > 6) return;
    final context = _keys[id]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.4,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      return;
    }
    // Not built yet (lazy list): move toward its estimated position, then
    // retry once the frame has built the neighbourhood.
    if (_scroll.hasClients) {
      final fromBottom = widget.messages.length - 1 - index;
      final estimate = (fromBottom * 84.0)
          .clamp(0.0, _scroll.position.maxScrollExtent)
          .toDouble();
      _scroll.jumpTo(estimate);
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToMessage(id, index, attempt: attempt + 1),
    );
  }

  Map<String, int> _replyCounts() {
    final counts = <String, int>{};
    for (final m in widget.allMessages) {
      if (m.isDeleted) continue;
      final parent = threadParentId(m);
      if (parent != null) counts[parent] = (counts[parent] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    final messages = widget.messages;
    if (messages.isEmpty) {
      return widget.emptyBuilder?.call(context) ?? const SizedBox.shrink();
    }
    final counts = _replyCounts();
    final me = widget.controller.state.value.user;
    final meLocal =
        (me?.xmppUsername ?? me?.username ?? '').split('@').first;

    // newest first for the reversed list: a message, then the day separator
    // that opens its day (shown above it once reversed)
    final entries = <Object>[];
    for (var i = messages.length - 1; i >= 0; i--) {
      entries.add(i);
      final current = messages[i];
      final opensDay =
          i == 0 || !sameDay(messages[i - 1].createdAtMs, current.createdAtMs);
      if (opensDay && current.id != 'delimiter-new') {
        entries.add(_Day(current.createdAtMs));
      }
    }

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.pixels >=
                    notification.metrics.maxScrollExtent - 120 &&
                widget.room?.historyComplete != true) {
              widget.onLoadOlder();
            }
            return false;
          },
          child: ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            itemCount: entries.length,
            itemBuilder: (context, position) {
              final entry = entries[position];
              if (entry is _Day) {
                return _DaySeparator(timestampMs: entry.timestampMs);
              }
              return _buildMessage(ui, entry as int, counts, meLocal);
            },
          ),
        ),
        if (_showScrollDown)
          Positioned(
            right: 14,
            bottom: 10,
            child: Material(
              color: ui.theme.bg,
              shape: const CircleBorder(),
              elevation: 3,
              child: IconButton(
                tooltip: ui.strings.t('action.scrollToBottom'),
                icon: Icon(Icons.keyboard_arrow_down, color: ui.theme.icons),
                onPressed: () => _scroll.animateTo(
                  0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMessage(
    ChatUiScope ui,
    int index,
    Map<String, int> counts,
    String meLocal,
  ) {
    final message = widget.messages[index];
    final key = _keys.putIfAbsent(message.id, GlobalKey.new);
    if (message.id == 'delimiter-new') {
      return KeyedSubtree(
        key: key,
        child: _SystemPill(text: ui.strings.t('list.newMessages')),
      );
    }
    if (message.system) {
      final log = CallLogInfo.fromMessage(
        message,
        selfXmppUsername: widget.controller.state.value.user?.xmppUsername ?? '',
      );
      return KeyedSubtree(
        key: key,
        child: _SystemPill(text: log?.label(ui.strings) ?? message.text),
      );
    }
    final isMine = widget.controller.isOwnMessage(message);
    ReceiptState? receipt;
    if (isMine && !message.pending && !message.failed) {
      receipt = computeReceiptState(
        messages: widget.messages,
        index: index,
        room: widget.room,
        me: meLocal,
      );
    }
    return KeyedSubtree(
      key: key,
      child: MessageBubbleView(
        message: message,
        isMine: isMine,
        controller: widget.controller,
        config: widget.config,
        receipt: receipt,
        highlighted: _highlightId == message.id,
        threadReplyCount: counts[message.id] ?? 0,
        fileToken: widget.fileToken,
        readerLocale: widget.readerLocale,
        onOpenThread: () => widget.onOpenThread(message),
        onQuoteTap: widget.onQuoteTap,
      ),
    );
  }
}

class _Day {
  const _Day(this.timestampMs);
  final int timestampMs;
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.timestampMs});

  final int timestampMs;

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: ui.theme.bgSubtle,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            formatDayLabel(timestampMs, ui.strings),
            style: TextStyle(fontSize: 12, color: ui.theme.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// System messages and the "New Messages" delimiter render as a centered
/// pill like web SystemMessage, never as a chat bubble.
class _SystemPill extends StatelessWidget {
  const _SystemPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.primarySoft,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: theme.primaryText),
          ),
        ),
      ),
    );
  }
}
