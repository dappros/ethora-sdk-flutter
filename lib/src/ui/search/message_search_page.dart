import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/message_search_session.dart';
import '../../core/room_people.dart';
import '../../core/search_filters.dart';
import '../../i18n/chat_i18n.dart';
import '../../models/chat_component_config.dart';
import '../../networking/message_search_service.dart';
import '../../networking/stanza_parser.dart';
import '../../theme/chat_theme.dart';
import '../rooms/room_ui.dart';
import 'message_hits_list.dart';

/// Opens message search as a full-screen page: scope (this chat or all),
/// sender and date filters, paged results, and a tap on a hit that opens the
/// room and jumps to the message. [roomJid] is the chat that is open (it
/// enables the "This chat" scope). [onOpenRoom] lets the host switch its
/// panes before a jump starts.
///
/// Does nothing when search is off (`isMessageSearchEnabled`).
Future<void> showMessageSearch(
  BuildContext context, {
  required ChatComponentController controller,
  required ChatComponentConfig config,
  String? roomJid,
  ValueChanged<String>? onOpenRoom,
}) async {
  if (!isMessageSearchEnabled(config)) return;
  final scope = ChatUiScope.of(context);
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ChatScopeBridge(
        scope: scope,
        child: MessageSearchScreen(
          controller: controller,
          roomJid: roomJid,
          onOpenRoom: onOpenRoom,
        ),
      ),
    ),
  );
}

/// The search screen itself, for hosts that route to it on their own.
class MessageSearchScreen extends StatefulWidget {
  const MessageSearchScreen({
    super.key,
    required this.controller,
    this.roomJid,
    this.onOpenRoom,
  });

  final ChatComponentController controller;
  final String? roomJid;
  final ValueChanged<String>? onOpenRoom;

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  late final MessageSearchSession _session;
  late final HitNameResolver _names;
  final TextEditingController _query = TextEditingController();
  final TextEditingController _since = TextEditingController();
  final TextEditingController _until = TextEditingController();
  final TextEditingController _senderQuery = TextEditingController();
  SearchScope _scope = SearchScope.all;
  bool _filtersOpen = false;
  SearchPerson? _sender;
  String? _opening;

  String? get _roomName {
    final jid = widget.roomJid;
    if (jid == null || jid.isEmpty) return null;
    return localPart(jid);
  }

  @override
  void initState() {
    super.initState();
    _scope = _roomName == null ? SearchScope.all : SearchScope.chat;
    _session = widget.controller.createMessageSearchSession()
      ..update(scope: _scope, roomName: _roomName ?? '')
      ..addListener(_changed);
    _names = HitNameResolver(widget.controller)..addListener(_changed);
  }

  @override
  void dispose() {
    _session.dispose();
    _names.dispose();
    _query.dispose();
    _since.dispose();
    _until.dispose();
    _senderQuery.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  MessageSearchFilters get _filters => MessageSearchFilters(
        fromUserId: _sender?.id,
        // an invalid typed day is no bound (the field shows it in red)
        sinceDay: isValidDay(_since.text.trim()) ? _since.text.trim() : '',
        untilDay: isValidDay(_until.text.trim()) ? _until.text.trim() : '',
      );

  void _pushFilters() => _session.update(filters: _filters);

  Iterable<SearchPerson> _senderCandidates() {
    final needle = _senderQuery.text;
    if (needle.trim().isEmpty) return const <SearchPerson>[];
    final state = widget.controller.state.value;
    final room = state.rooms.where((r) => r.jid == widget.roomJid).firstOrNull;
    final people = _scope == SearchScope.chat && room != null
        ? room.members.map((m) => SearchPerson(id: m.id, name: m.displayName))
        : collectKnownPeople(state.rooms)
            .map((p) => SearchPerson(id: p.userId, name: p.name));
    return matchPeople(people, needle);
  }

  Future<void> _pickDay(TextEditingController field) async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(field.text.trim()) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2015),
      lastDate: now.add(const Duration(days: 1)),
    );
    if (picked == null || !mounted) return;
    final mm = picked.month.toString().padLeft(2, '0');
    final dd = picked.day.toString().padLeft(2, '0');
    field.text = '${picked.year}-$mm-$dd';
    setState(_pushFilters);
  }

  Future<void> _open(MessageSearchHit hit) async {
    final strings = context.chatStrings;
    final sender = hitSenderLabel(_names, hit, strings);
    setState(() => _opening = hit.key);
    final outcome = await openSearchHit(
      controller: widget.controller,
      hit: hit,
      onOpenRoom: widget.onOpenRoom,
    );
    if (!mounted) return;
    setState(() => _opening = null);
    switch (outcome) {
      case JumpOutcome.reached:
        Navigator.of(context).pop();
      case JumpOutcome.notFound || JumpOutcome.expired:
        await showArchivedHit(context, hit: hit, sender: sender);
      case JumpOutcome.superseded || null:
        break;
    }
  }

  void _setScope(SearchScope scope) {
    setState(() {
      _scope = scope;
      _sender = null;
      _senderQuery.clear();
    });
    _session.update(scope: scope, filters: _filters);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    final filters = _filters;
    final trimmed = _query.text.trim();
    final status = _session.status;
    final items = _session.items;
    final rooms = widget.controller.state.value.rooms;
    final chatScopeAvailable = _roomName != null;

    return Scaffold(
      backgroundColor: theme.bg,
      appBar: AppBar(
        backgroundColor: theme.bg,
        foregroundColor: theme.text,
        elevation: 0,
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: (value) {
            setState(() {});
            _session.update(query: value);
          },
          decoration: InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            hintText: strings.t(_scope == SearchScope.chat
                ? 'search.messages.placeholderChat'
                : 'search.messages.placeholderAll'),
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    tooltip: strings.t('search.clear'),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _query.clear();
                      setState(() {});
                      _session.update(query: '');
                    },
                  ),
          ),
        ),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                ChoiceChip(
                  label: Text(strings.t('search.messages.scopeChat')),
                  selected: _scope == SearchScope.chat,
                  onSelected: chatScopeAvailable
                      ? (_) => _setScope(SearchScope.chat)
                      : null,
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(strings.t('search.messages.scopeAll')),
                  selected: _scope == SearchScope.all,
                  onSelected: (_) => _setScope(SearchScope.all),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: Text(
                    filters.activeCount > 0
                        ? '${strings.t('search.messages.filters')} (${filters.activeCount})'
                        : strings.t('search.messages.filters'),
                  ),
                ),
              ],
            ),
          ),
          if (_filtersOpen) _filterPanel(theme, strings, filters),
          if (!_session.searchable)
            _hint(
              theme,
              filters.backwards
                  ? strings.t('search.messages.dateOrder')
                  : trimmed.isNotEmpty
                      ? strings.t('search.messages.tooShort',
                          {'count': kMinSearchQueryLength})
                      : strings.t('search.messages.hint'),
            ),
          if (_session.searchable && status == MessageSearchStatus.loading)
            _hint(theme, strings.t('search.messages.searching')),
          if (status == MessageSearchStatus.error)
            _hint(
              theme,
              strings.t('search.messages.error'),
              action: strings.t('search.messages.retry'),
              onAction: _session.retry,
            ),
          if (_session.searchable &&
              status == MessageSearchStatus.done &&
              items.isEmpty)
            _hint(theme, strings.t('search.messages.empty')),
          if (items.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                strings.t('search.messages.count', {'count': _session.total}),
                style: TextStyle(fontSize: 12, color: theme.textMuted),
              ),
            ),
            for (final hit in items)
              Builder(builder: (context) {
                final jid = resolveHitRoomJid(hit, rooms);
                final room = rooms.where((r) => r.jid == jid).firstOrNull;
                return MessageHitTile(
                  hit: hit,
                  query: trimmed,
                  sender: hitSenderLabel(_names, hit, strings),
                  roomTitle: _scope == SearchScope.all
                      ? (room == null
                          ? strings.t('search.messages.chat')
                          : roomDisplayTitle(room))
                      : null,
                  busy: _opening == hit.key,
                  onTap: jid == null ? null : () => _open(hit),
                );
              }),
            if (_session.hasMore)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: OutlinedButton(
                    onPressed: status == MessageSearchStatus.loadingMore
                        ? null
                        : _session.loadMore,
                    child: Text(
                      status == MessageSearchStatus.loadingMore
                          ? strings.t('search.messages.searching')
                          : strings.t('search.messages.loadMore'),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _filterPanel(
    ChatTheme theme,
    ChatStrings strings,
    MessageSearchFilters filters,
  ) {
    final candidates =
        _sender == null ? _senderCandidates().toList() : <SearchPerson>[];
    InputDecoration dayDecoration(String label, TextEditingController c) {
      final text = c.text.trim();
      final bad = text.isNotEmpty && !isValidDay(text);
      return InputDecoration(
        isDense: true,
        labelText: label,
        hintText: 'YYYY-MM-DD',
        errorText: bad ? 'YYYY-MM-DD' : null,
        suffixIcon: IconButton(
          icon: const Icon(Icons.calendar_today_outlined, size: 18),
          onPressed: () => _pickDay(c),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.t('search.messages.filterSender'),
            style: TextStyle(fontSize: 12, color: theme.textMuted),
          ),
          if (_sender != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InputChip(
                label: Text(_sender!.name),
                onDeleted: () {
                  setState(() => _sender = null);
                  _pushFilters();
                },
              ),
            )
          else
            TextField(
              controller: _senderQuery,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: strings.t('search.messages.filterSenderPlaceholder'),
              ),
            ),
          for (final person in candidates)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(person.name),
              onTap: () {
                setState(() {
                  _sender = person;
                  _senderQuery.clear();
                });
                _pushFilters();
              },
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _since,
                  keyboardType: TextInputType.datetime,
                  onChanged: (_) => setState(_pushFilters),
                  decoration: dayDecoration(
                    strings.t('search.messages.filterSince'),
                    _since,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _until,
                  keyboardType: TextInputType.datetime,
                  onChanged: (_) => setState(_pushFilters),
                  decoration: dayDecoration(
                    strings.t('search.messages.filterUntil'),
                    _until,
                  ),
                ),
              ),
            ],
          ),
          if (filters.backwards)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                strings.t('search.messages.dateOrder'),
                style: TextStyle(color: theme.danger, fontSize: 12),
              ),
            ),
          if (filters.activeCount > 0 ||
              _since.text.isNotEmpty ||
              _until.text.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  setState(() {
                    _sender = null;
                    _senderQuery.clear();
                    _since.clear();
                    _until.clear();
                  });
                  _pushFilters();
                },
                child: Text(strings.t('search.messages.filterClearAll')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _hint(
    ChatTheme theme,
    String text, {
    String? action,
    VoidCallback? onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
