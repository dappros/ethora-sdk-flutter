import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../i18n/chat_i18n.dart';
import '../../theme/chat_theme.dart';
import '../../networking/room_actions_service.dart';
import '../../networking/stanza_parser.dart';
import 'room_ui.dart';

/// The public chats directory ("Discover chats"): a paged list from
/// `GET /v1/chats/public` with a local filter and a Join or Open button per
/// chat. [onOpenRoom] gets the JID of the chat the reader opened or joined.
Future<void> showPublicChatsSheet(
  BuildContext context, {
  required ChatComponentController controller,
  ValueChanged<String>? onOpenRoom,
}) {
  return showChatSheet<void>(
    context,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.of(sheetContext).size.height * 0.85,
      child: PublicChatsView(controller: controller, onOpenRoom: onOpenRoom),
    ),
  );
}

enum _DirectoryStatus { loading, loadingMore, done, error }

/// The directory list on its own, for hosts that lay it out themselves.
class PublicChatsView extends StatefulWidget {
  const PublicChatsView({
    super.key,
    required this.controller,
    this.onOpenRoom,
  });

  final ChatComponentController controller;
  final ValueChanged<String>? onOpenRoom;

  @override
  State<PublicChatsView> createState() => _PublicChatsViewState();
}

class _PublicChatsViewState extends State<PublicChatsView> {
  final TextEditingController _filter = TextEditingController();
  List<PublicChat> _items = const <PublicChat>[];
  int _total = 0;
  int _nextOffset = 0;
  _DirectoryStatus _status = _DirectoryStatus.loading;
  int _request = 0;
  String? _joining;

  @override
  void initState() {
    super.initState();
    _load(0);
  }

  @override
  void dispose() {
    _request += 1;
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load(int offset) async {
    final id = ++_request;
    setState(() {
      _status =
          offset > 0 ? _DirectoryStatus.loadingMore : _DirectoryStatus.loading;
    });
    try {
      final page = await widget.controller.loadPublicChats(offset: offset);
      if (!mounted || id != _request) return;
      setState(() {
        final seen = <String>{if (offset > 0) ..._items.map((c) => c.name)};
        _items = offset > 0
            ? <PublicChat>[
                ..._items,
                ...page.items.where((c) => seen.add(c.name)),
              ]
            : page.items;
        _total = page.total;
        _nextOffset = page.nextOffset;
        _status = _DirectoryStatus.done;
      });
    } catch (_) {
      if (!mounted || id != _request) return;
      setState(() => _status = _DirectoryStatus.error);
    }
  }

  List<PublicChat> get _visible {
    final needle = _filter.text.trim().toLowerCase();
    if (needle.isEmpty) return _items;
    return _items
        .where((c) =>
            c.title.toLowerCase().contains(needle) ||
            c.description.toLowerCase().contains(needle))
        .toList();
  }

  bool get _hasMore => _nextOffset < _total;

  Future<void> _open(PublicChat chat) async {
    setState(() => _joining = chat.name);
    try {
      final room = await widget.controller.joinPublicChat(chat);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onOpenRoom?.call(room.jid);
    } catch (_) {
      if (!mounted) return;
      setState(() => _joining = null);
      showChatSnack(context, context.chatStrings.t('toast.error'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    final visible = _visible;
    final fileToken = widget.controller.state.value.user?.fileToken;
    return Column(
      children: [
        ChatSheetTitleBar(title: strings.t('publicChats.title')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _filter,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: strings.t('publicChats.filter'),
            ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: widget.controller.state,
            builder: (context, state, _) {
              final joined = state.rooms.map((r) => localPart(r.jid)).toSet();
              return _body(theme, strings, visible, joined, fileToken);
            },
          ),
        ),
      ],
    );
  }

  Widget _body(
    ChatTheme theme,
    ChatStrings strings,
    List<PublicChat> visible,
    Set<String> joined,
    String? fileToken,
  ) {
    if (_status == _DirectoryStatus.loading) {
      return _Hint(strings.t('publicChats.loading'), busy: true);
    }
    if (_status == _DirectoryStatus.error && _items.isEmpty) {
      return _Hint(
        strings.t('publicChats.error'),
        action: strings.t('search.messages.retry'),
        onAction: () => _load(_nextOffset),
      );
    }
    if (visible.isEmpty) {
      return _Hint(
        _filter.text.trim().isNotEmpty && _hasMore
            ? strings.t('publicChats.emptyFilterMore')
            : strings.t('publicChats.empty'),
        action: _filter.text.trim().isNotEmpty && _hasMore
            ? strings.t('search.messages.loadMore')
            : null,
        onAction: () => _load(_nextOffset),
      );
    }
    return ListView.builder(
      itemCount: visible.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == visible.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: OutlinedButton(
                onPressed: _status == _DirectoryStatus.loadingMore
                    ? null
                    : () => _load(_nextOffset),
                child: Text(
                  _status == _DirectoryStatus.loadingMore
                      ? strings.t('publicChats.loading')
                      : strings.t('search.messages.loadMore'),
                ),
              ),
            ),
          );
        }
        final chat = visible[index];
        final isJoined = joined.contains(chat.name);
        return ListTile(
          leading: RoomAvatar(
            name: chat.displayTitle,
            url: chat.picture,
            fileToken: fileToken,
          ),
          title: Text(
            chat.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w600, color: theme.text),
          ),
          subtitle: chat.description.isEmpty
              ? null
              : Text(
                  chat.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.textMuted),
                ),
          trailing: _joining == chat.name
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : isJoined
                  ? OutlinedButton(
                      onPressed: () => _open(chat),
                      child: Text(strings.t('publicChats.open')),
                    )
                  : FilledButton(
                      onPressed: () => _open(chat),
                      child: Text(strings.t('publicChats.join')),
                    ),
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.busy = false, this.action, this.onAction});

  final String text;
  final bool busy;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textMuted),
            ),
            if (action != null)
              TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ),
      ),
    );
  }
}
