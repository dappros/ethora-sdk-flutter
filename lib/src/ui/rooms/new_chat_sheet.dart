import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/room_people.dart';
import '../../i18n/chat_i18n.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_room.dart';
import '../../models/media_attachment.dart';
import '../../networking/api_client.dart';
import '../../theme/chat_theme.dart';
import 'room_ui.dart';

/// Starts a chat: a private chat with one person, or a new group or public
/// chat. Resolves with the room that was created, or null when dismissed.
Future<ChatRoom?> showNewChatSheet(
  BuildContext context, {
  required ChatComponentController controller,
  required ChatComponentConfig config,
}) {
  return showChatSheet<ChatRoom>(
    context,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.of(sheetContext).size.height * 0.85,
      child: NewChatView(controller: controller, config: config),
    ),
  );
}

enum _NewChatMode { person, group }

/// The new chat form on its own, for hosts that lay it out themselves. Pops
/// its route with the created [ChatRoom].
class NewChatView extends StatefulWidget {
  const NewChatView(
      {super.key, required this.controller, required this.config});

  final ChatComponentController controller;
  final ChatComponentConfig config;

  @override
  State<NewChatView> createState() => _NewChatViewState();
}

class _NewChatViewState extends State<NewChatView> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _description = TextEditingController();
  _NewChatMode _mode = _NewChatMode.person;
  bool _public = false;
  bool _busy = false;
  bool _e2ee = false;
  MediaFileInput? _avatar;
  final List<RoomPerson> _picked = <RoomPerson>[];
  late final List<RoomPerson> _known;

  @override
  void initState() {
    super.initState();
    final state = widget.controller.state.value;
    final me = state.user?.xmppUsername ?? state.user?.username ?? '';
    _known = collectKnownPeople(
      state.rooms,
      myLocal: me.split('@').first,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  /// An encrypted chat is only offered when the host turned e2ee on.
  bool get _e2eeOffered => widget.config.e2ee?.enabled == true;

  bool get _titleValid => _title.text.trim().length >= 3;

  Future<void> _startPrivate(String username) async {
    final name = username.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final room = await widget.controller.createPrivateChat(
        name,
        e2ee: _e2eeOffered && _e2ee,
      );
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      _fail('toast.failedToCreatePrivateChat', e);
    }
  }

  Future<void> _createGroup() async {
    if (!_titleValid || _busy) return;
    setState(() => _busy = true);
    try {
      final description = _description.text.trim();
      final room = await widget.controller.createGroupChat(
        title: _title.text.trim(),
        description: description.isEmpty ? 'No description' : description,
        type: _public ? 'public' : 'group',
        members: _picked.map((p) => p.xmppUsername).toList(),
        avatar: _avatar,
      );
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      _fail('rooms.createFailed', e);
    }
  }

  Future<void> _pickAvatar() async {
    final file = await pickRoomImage();
    if (file == null || !mounted) return;
    setState(() => _avatar = file);
  }

  void _fail(String key, Object error) {
    if (!mounted) return;
    setState(() => _busy = false);
    final reason = error is ApiException ? error.reason : null;
    final text = context.chatStrings.t(key);
    showChatSnack(context, reason == null ? text : '$text $reason');
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    return Column(
      children: [
        ChatSheetTitleBar(title: strings.t('action.newChat')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SegmentedButton<_NewChatMode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: _NewChatMode.person,
                icon: const Icon(Icons.person_outline_rounded),
                label: Text(strings.t('rooms.newChat.person')),
              ),
              ButtonSegment(
                value: _NewChatMode.group,
                icon: const Icon(Icons.groups_2_outlined),
                label: Text(strings.t('rooms.newChat.group')),
              ),
            ],
            selected: <_NewChatMode>{_mode},
            onSelectionChanged: (value) => setState(() {
              _mode = value.first;
              _search.clear();
            }),
          ),
        ),
        Expanded(
          child: _mode == _NewChatMode.person
              ? _person(theme, strings)
              : _group(theme, strings),
        ),
      ],
    );
  }

  Widget _person(ChatTheme theme, ChatStrings strings) {
    final matches = filterPeople(_known, _search.text);
    final typed = _search.text.trim();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _search,
            autofocus: false,
            onChanged: (_) => setState(() {}),
            onSubmitted: _startPrivate,
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: strings.t('rooms.newChat.username'),
            ),
          ),
        ),
        if (_e2eeOffered)
          SwitchListTile(
            key: const ValueKey('new-chat-e2ee'),
            dense: true,
            value: _e2ee,
            secondary: Icon(Icons.lock_outline_rounded, color: theme.icons),
            title: Text(strings.t('e2ee.roomEncrypted')),
            onChanged: _busy ? null : (value) => setState(() => _e2ee = value),
          ),
        Expanded(
          child: matches.isEmpty
              ? Center(
                  child: Text(
                    strings.t('modal.selectUsers.empty'),
                    style: TextStyle(color: theme.textMuted),
                  ),
                )
              : ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final person = matches[index];
                    return ListTile(
                      enabled: !_busy,
                      leading: RoomAvatar(name: person.name, size: 40),
                      title: Text(person.name),
                      onTap: () => _startPrivate(person.xmppUsername),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed:
                  typed.isEmpty || _busy ? null : () => _startPrivate(typed),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(strings.t('rooms.newChat.start')),
            ),
          ),
        ),
      ],
    );
  }

  Widget _group(ChatTheme theme, ChatStrings strings) {
    final candidates = filterPeople(
      _known
          .where((p) => !_picked.any((x) => x.xmppUsername == p.xmppUsername))
          .toList(),
      _search.text,
      limit: 20,
    );
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Row(
                children: [
                  GestureDetector(
                    key: const ValueKey('new-chat-avatar'),
                    onTap: _busy ? null : _pickAvatar,
                    child: _avatar == null
                        ? RoomAvatar(
                            name: _title.text,
                            size: 56,
                            icon: Icons.add_a_photo_outlined,
                          )
                        : ClipOval(
                            child: Image.memory(
                              Uint8List.fromList(_avatar!.bytes),
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _avatar?.filename ?? strings.t('rooms.picture.change'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.textMuted),
                    ),
                  ),
                  if (_avatar != null)
                    IconButton(
                      tooltip: strings.t('rooms.picture.remove'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() => _avatar = null),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: strings.t('modal.newChat.roomNamePlaceholder'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _description,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: strings.t('modal.chatProfile.description'),
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.lock_outline_rounded),
                    label: Text(strings.t('modal.newChat.typePrivate')),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.public_rounded),
                    label: Text(strings.t('modal.newChat.typePublic')),
                  ),
                ],
                selected: <bool>{_public},
                onSelectionChanged: (value) =>
                    setState(() => _public = value.first),
              ),
              const SizedBox(height: 12),
              if (_picked.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final person in _picked)
                      InputChip(
                        label: Text(person.name),
                        onDeleted: () => setState(() => _picked.remove(person)),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Text(
                strings.t('modal.newChat.selectUsersTitle'),
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: strings.t('modal.selectUsers.searchPlaceholder'),
                ),
              ),
              for (final person in candidates)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: RoomAvatar(name: person.name, size: 36),
                  title: Text(person.name),
                  trailing: const Icon(Icons.add_rounded),
                  onTap: () => setState(() => _picked.add(person)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _titleValid && !_busy ? _createGroup : null,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(strings.t('action.create')),
            ),
          ),
        ),
      ],
    );
  }
}
