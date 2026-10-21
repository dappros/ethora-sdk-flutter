import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/message_search_session.dart';
import '../../core/search_filters.dart';
import '../../i18n/chat_i18n.dart';
import '../../models/chat_room.dart';
import '../../networking/message_search_service.dart';
import '../../networking/stanza_parser.dart';
import '../../theme/chat_theme.dart';
import '../rooms/room_ui.dart';

/// The JID of the room a hit belongs to, or null when this device does not
/// know the room (such a hit cannot be opened).
String? resolveHitRoomJid(MessageSearchHit hit, List<ChatRoom> rooms) {
  for (final room in rooms) {
    if (room.jid == hit.room) return room.jid;
  }
  for (final room in rooms) {
    if (localPart(room.jid) == hit.chatId) return room.jid;
  }
  return null;
}

/// Who sent a hit, resolved from what is already loaded (members first, then
/// loaded messages) and, failing that, asked from the API once.
class HitNameResolver extends ChangeNotifier {
  HitNameResolver(this.controller);

  final ChatComponentController controller;
  final Map<String, String> _asked = <String, String>{};
  final Set<String> _requested = <String>{};
  bool _disposed = false;

  /// Display name of the sender, empty while unknown. `isSelf` is true for me.
  ({String name, bool isSelf}) resolve(MessageSearchHit hit) {
    final state = controller.state.value;
    final from = localPart(hit.from).toLowerCase();
    final me = localPart(state.user?.xmppUsername).toLowerCase();
    if (from.isNotEmpty && from == me) return (name: '', isSelf: true);

    final room = state.rooms
        .where((r) => r.jid == resolveHitRoomJid(hit, state.rooms))
        .firstOrNull;
    for (final member in room?.members ?? const <ChatRoomMember>[]) {
      final byId = hit.fromUserId.isNotEmpty && member.id == hit.fromUserId;
      final byName = localPart(member.xmppUsername).toLowerCase() == from;
      if ((byId || byName) && member.displayName != member.xmppUsername) {
        return (name: member.displayName, isSelf: false);
      }
    }
    final cached = _asked[from];
    if (cached != null) return (name: cached, isSelf: false);
    for (final m in state.messagesByRoom[room?.jid] ?? const []) {
      if (localPart(m.user.xmppUsername).toLowerCase() == from &&
          m.user.displayName != 'Unknown') {
        return (name: m.user.displayName, isSelf: false);
      }
    }
    // Search hits can come from senders nobody has loaded (big rooms ship
    // only the first members): ask once; the name appears on the next build.
    if (from.isNotEmpty && _requested.add(from)) {
      controller.lookupUserProfile(from).then((profile) {
        if (_disposed || profile == null) return;
        _asked[from] = profile.displayName;
        notifyListeners();
      });
    }
    return (name: '', isSelf: false);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A hit's sender as text: "You", the name, or "Someone".
String hitSenderLabel(
  HitNameResolver resolver,
  MessageSearchHit hit,
  ChatStrings strings,
) {
  final sender = resolver.resolve(hit);
  if (sender.isSelf) return strings.t('search.messages.you');
  return sender.name.isEmpty
      ? strings.t('search.messages.someone')
      : sender.name;
}

/// Short date for a hit: day and month, with the year when it is not this one.
String formatHitWhen(String iso, {DateTime? now, ChatStrings? strings}) {
  final date = DateTime.tryParse(iso)?.toLocal();
  if (date == null) return '';
  const months = <String>[
    'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];
  final key = months[date.month - 1];
  final name = (strings ?? ChatStrings.resolve(null, null))
      .t('date.monthShort.$key');
  final base = '${date.day} $name';
  return date.year == (now ?? DateTime.now()).year
      ? base
      : '$base ${date.year}';
}

/// Opens the room of [hit] and takes the reader to the message. Returns null
/// when the room is not known here, else how the jump ended. [onOpenRoom]
/// lets the host switch its panes before the jump starts.
Future<JumpOutcome?> openSearchHit({
  required ChatComponentController controller,
  required MessageSearchHit hit,
  ValueChanged<String>? onOpenRoom,
}) async {
  final jid = resolveHitRoomJid(hit, controller.state.value.rooms);
  if (jid == null) return null;
  onOpenRoom?.call(jid);
  return controller.jumpToMessage(
    roomJid: jid,
    ids: <String>[hit.stanzaId, hit.messageId],
    createdAt: hit.createdAtDate?.millisecondsSinceEpoch,
    body: hit.body,
  );
}

/// What a tap on a hit that could not be reached shows: the hit itself, so a
/// tap always ends with the message in front of the reader.
Future<void> showArchivedHit(
  BuildContext context, {
  required MessageSearchHit hit,
  required String sender,
}) {
  return showChatDialog<void>(
    context,
    builder: (dialogContext) {
      final strings = dialogContext.chatStrings;
      final theme = dialogContext.chatTheme;
      return AlertDialog(
        backgroundColor: theme.bg,
        title: Text(strings.t('search.messages.archivedTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$sender  ${formatHitWhen(hit.createdAt, strings: strings)}',
              style: TextStyle(color: theme.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(hit.body, style: TextStyle(color: theme.text)),
            const SizedBox(height: 12),
            Text(
              strings.t('search.messages.archivedNote'),
              style: TextStyle(color: theme.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.t('action.close')),
          ),
        ],
      );
    },
  );
}

/// One search hit: who, when, and the text with the match emphasised.
class MessageHitTile extends StatelessWidget {
  const MessageHitTile({
    super.key,
    required this.hit,
    required this.query,
    required this.sender,
    required this.onTap,
    this.roomTitle,
    this.busy = false,
  });

  final MessageSearchHit hit;
  final String query;
  final String sender;

  /// Prefixes the sender with the chat's title (search across chats).
  final String? roomTitle;

  /// Null makes the tile inert (the room is not known here).
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final head = roomTitle == null ? sender : '$roomTitle · $sender';
    final parts = buildSnippet(hit.body, query);
    return Opacity(
      opacity: onTap == null ? 0.6 : 1,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            head,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: theme.textSecondary,
                            ),
                          ),
                        ),
                        Text(
                          formatHitWhen(hit.createdAt,
                              strings: context.chatStrings),
                          style:
                              TextStyle(fontSize: 12, color: theme.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text.rich(
                      TextSpan(
                        children: [
                          for (final part in parts)
                            TextSpan(
                              text: part.text,
                              style: part.match
                                  ? TextStyle(
                                      backgroundColor: theme.primarySoft,
                                      color: theme.primaryText,
                                      fontWeight: FontWeight.w600,
                                    )
                                  : null,
                            ),
                        ],
                      ),
                      style: TextStyle(fontSize: 14, color: theme.text),
                    ),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(left: 8, top: 2),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Message hits under the room list (chat-list search): shown when search is
/// on and the term has at least two characters. Lists the first few with a
/// "Show more" and "Retry".
class MessageHitsList extends StatefulWidget {
  const MessageHitsList({
    super.key,
    required this.controller,
    required this.term,
    this.onOpenRoom,
    this.initialCount = 5,
  });

  final ChatComponentController controller;

  /// What the reader typed in the room search field.
  final String term;

  /// Lets the host switch its panes before the jump starts.
  final ValueChanged<String>? onOpenRoom;
  final int initialCount;

  @override
  State<MessageHitsList> createState() => _MessageHitsListState();
}

class _MessageHitsListState extends State<MessageHitsList>
    with AutomaticKeepAliveClientMixin {
  late final MessageSearchSession _session;
  late final HitNameResolver _names;
  int _shown = 0;
  String? _opening;

  @override
  void initState() {
    super.initState();
    _shown = widget.initialCount;
    _session = widget.controller.createMessageSearchSession()
      ..update(query: widget.term, scope: SearchScope.all)
      ..addListener(_changed);
    _names = HitNameResolver(widget.controller)..addListener(_changed);
  }

  @override
  void didUpdateWidget(MessageHitsList old) {
    super.didUpdateWidget(old);
    if (old.term != widget.term) {
      _shown = widget.initialCount;
      _session.update(query: widget.term);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.dispose();
    _names.dispose();
    super.dispose();
  }

  Future<void> _open(MessageSearchHit hit) async {
    setState(() => _opening = hit.key);
    final sender = hitSenderLabel(_names, hit, context.chatStrings);
    final outcome = await openSearchHit(
      controller: widget.controller,
      hit: hit,
      onOpenRoom: widget.onOpenRoom,
    );
    if (!mounted) return;
    setState(() => _opening = null);
    if (outcome == JumpOutcome.notFound || outcome == JumpOutcome.expired) {
      await showArchivedHit(context, hit: hit, sender: sender);
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    if (!_session.searchable) return const SizedBox.shrink();
    final items = _session.items;
    final status = _session.status;
    final rooms = widget.controller.state.value.rooms;

    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                strings.t('search.messages.title').toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: theme.textMuted,
                ),
              ),
            ),
            if (items.isNotEmpty)
              Text(
                strings.t('search.messages.count', {'count': _session.total}),
                style: TextStyle(fontSize: 12, color: theme.textMuted),
              ),
          ],
        ),
      ),
    ];

    if (status == MessageSearchStatus.loading && items.isEmpty) {
      children.add(_note(theme, strings.t('search.messages.searching')));
    }
    if (status == MessageSearchStatus.error) {
      children.add(_note(
        theme,
        strings.t('search.messages.error'),
        action: strings.t('search.messages.retry'),
        onAction: _session.retry,
      ));
    }
    if (status == MessageSearchStatus.done && items.isEmpty) {
      children.add(_note(theme, strings.t('search.messages.empty')));
    }
    for (final hit in items.take(_shown)) {
      final jid = resolveHitRoomJid(hit, rooms);
      final room = rooms.where((r) => r.jid == jid).firstOrNull;
      children.add(MessageHitTile(
        hit: hit,
        query: _session.query.trim(),
        sender: hitSenderLabel(_names, hit, strings),
        roomTitle: room == null
            ? strings.t('search.messages.chat')
            : roomDisplayTitle(room),
        busy: _opening == hit.key,
        onTap: jid == null ? null : () => _open(hit),
      ));
    }
    final canShowMore = items.length > _shown || _session.hasMore;
    if (items.isNotEmpty && canShowMore) {
      children.add(Center(
        child: TextButton(
          onPressed: status == MessageSearchStatus.loadingMore
              ? null
              : () {
                  setState(() => _shown += widget.initialCount);
                  if (items.length < _shown + widget.initialCount) {
                    _session.loadMore();
                  }
                },
          child: Text(
            status == MessageSearchStatus.loadingMore
                ? strings.t('search.messages.searching')
                : strings.t('search.messages.loadMore'),
          ),
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _note(ChatTheme theme, String text,
      {String? action, VoidCallback? onAction}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Flexible(
            child: Text(text, style: TextStyle(color: theme.textMuted)),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }
}
