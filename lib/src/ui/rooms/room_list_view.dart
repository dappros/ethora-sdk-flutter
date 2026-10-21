import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/chat_component_state.dart';
import '../../core/message_reference.dart';
import '../../core/my_files_model.dart';
import '../../theme/chat_theme.dart';
import '../../i18n/chat_i18n.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_message.dart';
import '../../models/chat_room.dart';
import '../../networking/message_search_service.dart';
import '../../networking/files_service.dart';
import '../files/chat_files_panel.dart';
import '../search/message_hits_list.dart';
import 'new_chat_sheet.dart';
import 'public_chats_sheet.dart';
import 'report_room_sheet.dart';
import 'room_ui.dart';

/// Width of one swipe action.
const double kRoomActionWidth = 84;

/// The chat list: avatar, title, last message, unread badge, typing or
/// sending line, muted icon; a search field (room names, and message hits
/// when message search is on); swipe actions (mute, report, leave) unless
/// `config.disableRoomSwipeActions`; a "New chat" button and the public chats
/// directory unless `config.disablePublicChatsDirectory`.
class RoomListView extends StatefulWidget {
  const RoomListView({
    super.key,
    required this.controller,
    required this.config,
    required this.selectedRoomJid,
    required this.onSelectRoom,
    this.onOpenSettings,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final String? selectedRoomJid;
  final ValueChanged<String> onSelectRoom;

  /// Shows a settings button in the header when set.
  final VoidCallback? onOpenSettings;

  @override
  State<RoomListView> createState() => _RoomListViewState();
}

class _RoomListViewState extends State<RoomListView> {
  final TextEditingController _search = TextEditingController();
  StreamSubscription<ChatRoomEvent>? _events;
  String? _swipeOpenJid;
  bool _filesTab = false;

  @override
  void initState() {
    super.initState();
    _events = widget.controller.roomEvents.listen(_onRoomEvent);
  }

  @override
  void didUpdateWidget(RoomListView old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      _events?.cancel();
      _events = widget.controller.roomEvents.listen(_onRoomEvent);
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onRoomEvent(ChatRoomEvent event) {
    if (!mounted || event.type != ChatRoomEventType.kicked) return;
    final strings = context.chatStrings;
    final name = (event.title ?? '').trim();
    showChatSnack(
      context,
      strings.t('rooms.removedFromChat',
          {'name': name.isEmpty ? event.roomJid : name}),
    );
  }

  bool get _actionsEnabled => widget.config.disableRoomSwipeActions != true;

  Map<String, String> get _titleOverrides =>
      widget.config.chatHeaderSettings?.roomTitleOverrides ??
      const <String, String>{};

  Future<void> _toggleMute(ChatRoom room) async {
    final strings = context.chatStrings;
    try {
      await widget.controller.setRoomMuted(room.jid, !room.muted);
    } catch (_) {
      if (mounted) {
        showChatSnack(
          context,
          strings.t(room.muted ? 'toast.unmuteFailed' : 'toast.muteFailed'),
        );
      }
    }
  }

  Future<void> _report(ChatRoom room) async {
    final strings = context.chatStrings;
    final result = await showReportRoomSheet(
      context,
      roomTitle: roomDisplayTitle(room, overrides: _titleOverrides),
    );
    if (result == null || !mounted) return;
    try {
      await widget.controller.reportRoom(
        room.jid,
        category: result.category,
        text: result.text,
      );
      if (mounted) showChatSnack(context, strings.t('rooms.reportSent'));
    } catch (_) {
      if (mounted) showChatSnack(context, strings.t('rooms.reportFailed'));
    }
  }

  Future<void> _leave(ChatRoom room) async {
    final strings = context.chatStrings;
    final ok = await confirmChatAction(
      context,
      title: strings.t('modal.leaveChat.title'),
      message: strings.t('modal.leaveChat.description'),
      confirmLabel: strings.t('action.leave'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await widget.controller.leaveRoom(room.jid);
    } catch (_) {
      if (mounted) showChatSnack(context, strings.t('rooms.leaveFailed'));
    }
  }

  Future<void> _newChat() async {
    final room = await showNewChatSheet(
      context,
      controller: widget.controller,
      config: widget.config,
    );
    if (room == null || !mounted) return;
    widget.onSelectRoom(room.jid);
  }

  Future<void> _discover() {
    return showPublicChatsSheet(
      context,
      controller: widget.controller,
      onOpenRoom: widget.onSelectRoom,
    );
  }

  Future<void> _actionSheet(ChatRoom room) async {
    if (!_actionsEnabled) return;
    final strings = context.chatStrings;
    final choice = await showChatSheet<String>(
      context,
      builder: (sheetContext) {
        final theme = sheetContext.chatTheme;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChatSheetTitleBar(
                title: roomDisplayTitle(room, overrides: _titleOverrides),
              ),
              ListTile(
                leading: Icon(
                  room.muted
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  color: theme.icons,
                ),
                title: Text(
                    strings.t(room.muted ? 'action.unmute' : 'action.mute')),
                onTap: () => Navigator.of(sheetContext).pop('mute'),
              ),
              ListTile(
                leading: Icon(Icons.flag_outlined, color: theme.icons),
                title: Text(strings.t('action.report')),
                onTap: () => Navigator.of(sheetContext).pop('report'),
              ),
              ListTile(
                leading: Icon(Icons.logout_rounded, color: theme.danger),
                title: Text(
                  strings.t('action.leave'),
                  style: TextStyle(color: theme.danger),
                ),
                onTap: () => Navigator.of(sheetContext).pop('leave'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    switch (choice) {
      case 'mute':
        await _toggleMute(room);
      case 'report':
        await _report(room);
      case 'leave':
        await _leave(room);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    final canDiscover = widget.config.disablePublicChatsDirectory != true;
    final canCreate = widget.config.disableNewChatButton != true;
    final files = widget.controller.myFiles;
    return ListenableBuilder(
      listenable: files,
      builder: (context, _) {
        final filesEnabled = _filesTabEnabled(files);
        final onFiles = _filesTab && filesEnabled;
        return _frame(context, theme, strings, canDiscover, canCreate,
            filesEnabled, onFiles);
      },
    );
  }

  bool _filesTabEnabled(MyFilesModel files) {
    final configured = widget.config.filesTab?.enabled;
    return configured == true ||
        (configured != false &&
            files.support != FilesEndpointSupport.unsupported);
  }

  Widget _frame(
    BuildContext context,
    ChatTheme theme,
    ChatStrings strings,
    bool canDiscover,
    bool canCreate,
    bool filesEnabled,
    bool onFiles,
  ) {
    return ColoredBox(
      color: theme.bg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strings.t('rooms.title'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: theme.text,
                    ),
                  ),
                ),
                if (canDiscover)
                  IconButton(
                    tooltip: strings.t('publicChats.title'),
                    icon: Icon(Icons.explore_outlined, color: theme.icons),
                    onPressed: _discover,
                  ),
                if (canCreate)
                  IconButton(
                    tooltip: strings.t('action.newChat'),
                    icon: Icon(Icons.edit_square, color: theme.icons),
                    onPressed: _newChat,
                  ),
                if (widget.onOpenSettings != null)
                  IconButton(
                    tooltip: strings.t('settings.menu.title'),
                    icon: Icon(Icons.settings_outlined, color: theme.icons),
                    onPressed: widget.onOpenSettings,
                  ),
              ],
            ),
          ),
          if (filesEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(strings.t('tabs.chats')),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(strings.t('tabs.files')),
                    ),
                  ],
                  selected: <bool>{onFiles},
                  onSelectionChanged: (value) =>
                      setState(() => _filesTab = value.first),
                ),
              ),
            ),
          if (onFiles)
            Expanded(
              child: ChatFilesPanel(
                controller: widget.controller,
                config: widget.config,
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: theme.bgSubtle,
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: strings.t('search.placeholder'),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: strings.t('search.clear'),
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => setState(_search.clear),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<ChatComponentState>(
                valueListenable: widget.controller.state,
                builder: (context, state, _) => _list(context, state),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _list(BuildContext context, ChatComponentState state) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    final term = _search.text.trim();
    final needle = term.toLowerCase();
    final rooms = _sorted(state).where((room) {
      if (needle.isEmpty) return true;
      final title =
          roomDisplayTitle(room, overrides: _titleOverrides).toLowerCase();
      return title.contains(needle);
    }).toList();
    final showHits = isMessageSearchEnabled(widget.config) && term.length >= 2;
    final fileToken = state.user?.fileToken;

    if (rooms.isEmpty && !showHits) {
      return Center(
        child: Text(
          strings.t('rooms.empty'),
          style: TextStyle(color: theme.textMuted),
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final room = rooms[index];
              return _RoomTile(
                key: ValueKey(room.jid),
                room: room,
                title: roomDisplayTitle(room, overrides: _titleOverrides),
                preview: _previewOf(state, room, strings),
                lastAt: _lastAt(state, room),
                selected: room.jid == widget.selectedRoomJid,
                fileToken: fileToken,
                swipe: _actionsEnabled,
                open: _swipeOpenJid == room.jid,
                onOpenChanged: (open) => setState(
                  () => _swipeOpenJid = open ? room.jid : null,
                ),
                onTap: () {
                  // A tap on an open row (or elsewhere) closes it first.
                  final wasOpen = _swipeOpenJid;
                  if (wasOpen != null) {
                    setState(() => _swipeOpenJid = null);
                    if (wasOpen == room.jid) return;
                  }
                  widget.onSelectRoom(room.jid);
                },
                onLongPress: () => _actionSheet(room),
                onMute: () => _toggleMute(room),
                onReport: () => _report(room),
                onLeave: () => _leave(room),
              );
            },
            childCount: rooms.length,
          ),
        ),
        if (showHits)
          SliverToBoxAdapter(
            child: MessageHitsList(
              controller: widget.controller,
              term: term,
              onOpenRoom: widget.onSelectRoom,
            ),
          ),
      ],
    );
  }

  /// Newest activity first; rooms with no messages keep their server order.
  List<ChatRoom> _sorted(ChatComponentState state) {
    final indexed = state.rooms.asMap().entries.toList();
    indexed.sort((a, b) {
      final byTime = _lastAt(state, b.value).compareTo(_lastAt(state, a.value));
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    return indexed.map((e) => e.value).toList();
  }

  ChatMessage? _lastMessage(ChatComponentState state, ChatRoom room) {
    final list = state.messagesByRoom[room.jid];
    if (list == null) return null;
    for (var i = list.length - 1; i >= 0; i -= 1) {
      final m = list[i];
      if (m.id == 'delimiter-new') continue;
      return m;
    }
    return null;
  }

  int _lastAt(ChatComponentState state, ChatRoom room) =>
      _lastMessage(state, room)?.createdAtMs ?? 0;

  String? _previewOf(
    ChatComponentState state,
    ChatRoom room,
    ChatStrings strings,
  ) {
    final m = _lastMessage(state, room);
    if (m == null) return null;
    if (m.isDeleted) return strings.t('message.deleted');
    if (m.isMedia) return mediaLabel(m, strings);
    final text = m.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? null : text;
  }
}

/// One row: the swipeable surface and the content on it.
class _RoomTile extends StatelessWidget {
  const _RoomTile({
    super.key,
    required this.room,
    required this.title,
    required this.preview,
    required this.lastAt,
    required this.selected,
    required this.fileToken,
    required this.swipe,
    required this.open,
    required this.onOpenChanged,
    required this.onTap,
    required this.onLongPress,
    required this.onMute,
    required this.onReport,
    required this.onLeave,
  });

  final ChatRoom room;
  final String title;
  final String? preview;
  final int lastAt;
  final bool selected;
  final String? fileToken;
  final bool swipe;
  final bool open;
  final ValueChanged<bool> onOpenChanged;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMute;
  final VoidCallback onReport;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    final typing = room.composingList.isNotEmpty;
    final String subtitle;
    var subtitleColor = theme.textMuted;
    if (typing) {
      subtitle =
          strings.t('rooms.typing', {'names': room.composingList.join(', ')});
      subtitleColor = theme.primaryText;
    } else if (room.pendingMessages > 0) {
      subtitle = strings.t('rooms.sending', {'count': room.pendingMessages});
      subtitleColor = theme.primaryText;
    } else {
      subtitle = preview ?? '';
    }
    final hasUnread = room.unreadCount > 0;

    final content = Material(
      color: selected ? theme.primarySoft : theme.bg,
      child: InkWell(
        onTap: onTap,
        onLongPress: swipe ? onLongPress : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              RoomAvatar(
                name: title,
                url: room.picture,
                fileToken: fileToken,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight:
                                  hasUnread ? FontWeight.w700 : FontWeight.w600,
                              color: theme.text,
                            ),
                          ),
                        ),
                        if (room.e2ee)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: RoomLockBadge(),
                          ),
                        if (lastAt > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              formatRoomTime(lastAt, strings: strings),
                              style: TextStyle(
                                fontSize: 12,
                                color: hasUnread && !room.muted
                                    ? theme.primaryText
                                    : theme.textMuted,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: subtitleColor,
                              fontStyle:
                                  typing ? FontStyle.italic : FontStyle.normal,
                            ),
                          ),
                        ),
                        if (room.muted)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Icon(
                              Icons.notifications_off_outlined,
                              size: 16,
                              color: theme.textMuted,
                            ),
                          ),
                        if (hasUnread)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: CountBadge(
                              text: unreadBadgeText(
                                room.unreadCount,
                                capped: room.unreadCapped,
                              ),
                              muted: room.muted,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!swipe) return content;
    return SwipeRevealRow(
      open: open,
      onOpenChanged: onOpenChanged,
      actions: [
        SwipeAction(
          key: ValueKey('room-action-mute-${localPartOf(room.jid)}'),
          icon: room.muted
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          label: strings.t(room.muted ? 'action.unmute' : 'action.mute'),
          color: theme.primary,
          onTap: () {
            onOpenChanged(false);
            onMute();
          },
        ),
        SwipeAction(
          key: ValueKey('room-action-report-${localPartOf(room.jid)}'),
          icon: Icons.flag_outlined,
          label: strings.t('action.report'),
          color: theme.textSecondary,
          onTap: () {
            onOpenChanged(false);
            onReport();
          },
        ),
        SwipeAction(
          key: ValueKey('room-action-leave-${localPartOf(room.jid)}'),
          icon: Icons.logout_rounded,
          label: strings.t('action.leave'),
          color: theme.danger,
          onTap: () {
            onOpenChanged(false);
            onLeave();
          },
        ),
      ],
      child: content,
    );
  }
}

String localPartOf(String jid) => jid.split('@').first;

/// "14:05" for today, else "3 Jul" ("3 Jul 2025" for another year).
String formatRoomTime(int ms, {DateTime? now, ChatStrings? strings}) {
  final date = DateTime.fromMillisecondsSinceEpoch(ms);
  final today = now ?? DateTime.now();
  if (date.year == today.year &&
      date.month == today.month &&
      date.day == today.day) {
    final hh = date.hour.toString().padLeft(2, '0');
    final mm = date.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
  return formatHitWhen(
    date.toUtc().toIso8601String(),
    now: today,
    strings: strings,
  );
}

/// One button behind a swiped row.
class SwipeAction {
  const SwipeAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final Key key;
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

/// A row that slides sideways to reveal [actions] ([kRoomActionWidth] wide
/// each). Dragging toward the end of the line opens it; [open] is driven by
/// the parent so only one row is open at a time. Plain Material, no package.
class SwipeRevealRow extends StatefulWidget {
  const SwipeRevealRow({
    super.key,
    required this.child,
    required this.actions,
    required this.open,
    required this.onOpenChanged,
  });

  final Widget child;
  final List<SwipeAction> actions;
  final bool open;
  final ValueChanged<bool> onOpenChanged;

  @override
  State<SwipeRevealRow> createState() => _SwipeRevealRowState();
}

class _SwipeRevealRowState extends State<SwipeRevealRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.open ? 1 : 0,
  );

  double get _extent => kRoomActionWidth * widget.actions.length;

  @override
  void didUpdateWidget(SwipeRevealRow old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) {
      _slide.animateTo(widget.open ? 1 : 0, curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // Content moves toward the start of the line to uncover the end.
    final sign = rtl ? 1.0 : -1.0;
    return Stack(
      children: [
        Positioned.fill(
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SizedBox(
              width: _extent,
              child: Row(
                children: [
                  for (final action in widget.actions)
                    SizedBox(
                      width: kRoomActionWidth,
                      child: Material(
                        key: action.key,
                        color: action.color,
                        child: InkWell(
                          onTap: action.onTap,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(action.icon, color: Colors.white, size: 22),
                              const SizedBox(height: 4),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Text(
                                  action.label,
                                  maxLines: 2,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (details) {
            _slide.value = (_slide.value + sign * details.delta.dx / _extent)
                .clamp(0.0, 1.0);
          },
          onHorizontalDragEnd: (details) {
            final velocity = sign * (details.primaryVelocity ?? 0);
            final shouldOpen =
                velocity > 300 || (velocity > -300 && _slide.value > 0.4);
            _slide.animateTo(shouldOpen ? 1 : 0, curve: Curves.easeOut);
            if (shouldOpen != widget.open) widget.onOpenChanged(shouldOpen);
          },
          child: AnimatedBuilder(
            animation: _slide,
            builder: (context, child) => Transform.translate(
              offset: Offset(sign * _slide.value * _extent, 0),
              child: child,
            ),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
