import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/room_people.dart';
import '../../i18n/chat_i18n.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_room.dart';
import '../../networking/room_actions_service.dart';
import '../../networking/stanza_parser.dart';
import '../files/chat_files_panel.dart';
import 'room_ui.dart';

/// Members shown before "Show more".
const int kRoomInfoMemberStep = 20;

/// Members beyond this count get a search field.
const int kRoomInfoSearchFrom = 8;

/// The room profile sheet: title, description, type, notifications, the
/// member list (add and remove where the reader may), leave and delete.
///
/// Leaving or deleting closes the sheet; the room is gone from
/// `controller.state` then and the conversation falls back to no selection.
Future<void> showRoomInfo(
  BuildContext context, {
  required ChatComponentController controller,
  required ChatComponentConfig config,
  required String roomJid,
}) {
  return showChatSheet<void>(
    context,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.of(sheetContext).size.height * 0.9,
      child: RoomInfoView(
        controller: controller,
        config: config,
        roomJid: roomJid,
      ),
    ),
  );
}

/// The room profile on its own, for hosts that lay it out themselves.
class RoomInfoView extends StatefulWidget {
  const RoomInfoView({
    super.key,
    required this.controller,
    required this.config,
    required this.roomJid,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final String roomJid;

  @override
  State<RoomInfoView> createState() => _RoomInfoViewState();
}

class _RoomInfoViewState extends State<RoomInfoView> {
  final TextEditingController _search = TextEditingController();
  final Map<String, UserProfile> _profiles = <String, UserProfile>{};
  final Set<String> _asked = <String>{};
  int _visible = kRoomInfoMemberStep;
  bool _busy = false;
  bool _closing = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ChatRoom? _room(List<ChatRoom> rooms) {
    for (final room in rooms) {
      if (room.jid == widget.roomJid) return room;
    }
    return null;
  }

  /// Members the membership push added carry no name: ask the API once each.
  void _resolveNames(List<ChatRoomMember> members) {
    for (final member in members.take(_visible)) {
      final username = member.xmppUsername;
      if (username.isEmpty ||
          '${member.firstName}${member.lastName}'.trim().isNotEmpty ||
          !_asked.add(username)) {
        continue;
      }
      widget.controller.lookupUserProfile(username).then((profile) {
        if (!mounted || profile == null) return;
        setState(() => _profiles[username] = profile);
      });
    }
  }

  String _nameOf(ChatRoomMember member) {
    final name = member.displayName;
    if (name != member.xmppUsername) return name;
    return _profiles[member.xmppUsername]?.displayName ?? name;
  }

  Future<void> _toggleMute(ChatRoom room) async {
    final strings = context.chatStrings;
    setState(() => _busy = true);
    try {
      await widget.controller.setRoomMuted(room.jid, !room.muted);
    } catch (_) {
      if (mounted) {
        showChatSnack(
          context,
          strings.t(room.muted ? 'toast.unmuteFailed' : 'toast.muteFailed'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
    setState(() => _busy = true);
    try {
      await widget.controller.leaveRoom(room.jid);
      _close();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      showChatSnack(context, strings.t('rooms.leaveFailed'));
    }
  }

  Future<void> _delete(ChatRoom room) async {
    final strings = context.chatStrings;
    final ok = await confirmChatAction(
      context,
      title: strings.t('modal.deleteChat.title'),
      confirmLabel: strings.t('action.delete'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.deleteRoom(room.jid);
      _close();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      showChatSnack(context, strings.t('rooms.deleteFailed'));
    }
  }

  Future<void> _removeMember(ChatRoom room, ChatRoomMember member) async {
    final strings = context.chatStrings;
    final name = _nameOf(member);
    final ok = await confirmChatAction(
      context,
      title: strings.t('rooms.members.remove'),
      message: name,
      confirmLabel: strings.t('action.delete'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await widget.controller
          .removeRoomMembers(room.jid, <String>[member.xmppUsername]);
      if (mounted) {
        showChatSnack(
          context,
          strings.t('toast.userRemovedFromRoom', {'userId': name}),
        );
      }
    } catch (_) {
      if (mounted) {
        showChatSnack(context, strings.t('toast.failedToDeleteUser'));
      }
    }
  }

  Future<void> _addMembers(ChatRoom room) async {
    final strings = context.chatStrings;
    final people = await showChatSheet<List<RoomPerson>>(
      context,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.8,
        child: _AddMembersView(controller: widget.controller, room: room),
      ),
    );
    if (people == null || people.isEmpty || !mounted) return;
    try {
      await widget.controller.addRoomMembers(
        room.jid,
        people.map((p) => p.xmppUsername).toList(),
      );
      if (mounted) {
        showChatSnack(
          context,
          people.length == 1
              ? strings
                  .t('toast.userAddedToRoom', {'userName': people.first.name})
              : strings.t('toast.usersAddedSuccess'),
        );
      }
    } catch (_) {
      if (mounted) showChatSnack(context, strings.t('toast.failedToAddUser'));
    }
  }

  Future<void> _pickPicture(ChatRoom room) async {
    final strings = context.chatStrings;
    final file = await pickRoomImage();
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.setRoomPicture(room.jid, file);
    } catch (_) {
      if (mounted) showChatSnack(context, strings.t('rooms.pictureFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removePicture(ChatRoom room) async {
    final strings = context.chatStrings;
    setState(() => _busy = true);
    try {
      await widget.controller.removeRoomPicture(room.jid);
    } catch (_) {
      if (mounted) showChatSnack(context, strings.t('rooms.pictureFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    return ValueListenableBuilder(
      valueListenable: widget.controller.state,
      builder: (context, state, _) {
        final room = _room(state.rooms);
        if (room == null) {
          // The room went away (left elsewhere, or removed by the owner).
          WidgetsBinding.instance.addPostFrameCallback((_) => _close());
          return const SizedBox.shrink();
        }
        final me =
            (state.user?.xmppUsername ?? '').split('@').first.toLowerCase();
        final readOnly = widget.config.disableRoomConfig == true;
        final isPrivate = room.type == 'private';
        final canManage = room.canManage && !isPrivate && !readOnly;
        final needle = _search.text.trim().toLowerCase();
        final members = needle.isEmpty
            ? room.members
            : room.members
                .where((m) => _nameOf(m).toLowerCase().contains(needle))
                .toList();
        _resolveNames(members);
        final shown = members.take(_visible).toList();
        final count = room.displayUserCount;
        final fileToken = state.user?.fileToken;
        final title = roomDisplayTitle(
          room,
          overrides: widget.config.chatHeaderSettings?.roomTitleOverrides ??
              const <String, String>{},
        );
        final description = (room.description ?? '').trim();

        return Column(
          children: [
            ChatSheetTitleBar(title: strings.t('modal.chatProfile.title')),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  _Hero(
                    title: title,
                    picture: room.picture,
                    fileToken: fileToken,
                    locked: room.e2ee,
                    onPick:
                        canManage && !_busy ? () => _pickPicture(room) : null,
                    onRemove:
                        canManage && !_busy && (room.picture ?? '').isNotEmpty
                            ? () => _removePicture(room)
                            : null,
                    subtitle: count == 1
                        ? strings.t('modal.chatProfile.memberCountSingular',
                            {'count': count})
                        : strings.t('modal.chatProfile.memberCountPlural',
                            {'count': count}),
                  ),
                  _SectionTitle(strings.t('modal.chatProfile.aboutSection')),
                  if (description.isNotEmpty && description != 'No description')
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        description,
                        style: TextStyle(color: theme.text),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        Text(
                          '${strings.t('modal.chatProfile.chatType')}: ',
                          style: TextStyle(color: theme.textMuted),
                        ),
                        Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(_typeLabel(strings, room.type)),
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    value: !room.muted,
                    title: Text(strings.t('modal.chatProfile.notifications')),
                    secondary: Icon(
                      room.muted
                          ? Icons.notifications_off_outlined
                          : Icons.notifications_none_rounded,
                      color: theme.icons,
                    ),
                    onChanged: _busy ? null : (_) => _toggleMute(room),
                  ),
                  if (!isPrivate) ...[
                    _SectionTitle(
                      strings.t('modal.chatProfile.membersSection'),
                      trailing: canManage
                          ? TextButton.icon(
                              onPressed: _busy ? null : () => _addMembers(room),
                              icon: const Icon(Icons.person_add_alt_1_rounded),
                              label: Text(strings.t('action.addMembers')),
                            )
                          : null,
                    ),
                    if (room.members.length > kRoomInfoSearchFrom)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) =>
                              setState(() => _visible = kRoomInfoMemberStep),
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: const Icon(Icons.search_rounded),
                            hintText:
                                strings.t('modal.chatProfile.searchMembers'),
                          ),
                        ),
                      ),
                    for (final member in shown)
                      _MemberRow(
                        name: _nameOf(member),
                        isMe:
                            localPart(member.xmppUsername).toLowerCase() == me,
                        youLabel: strings.t('search.messages.you'),
                        onRemove: canManage &&
                                localPart(member.xmppUsername).toLowerCase() !=
                                    me
                            ? () => _removeMember(room, member)
                            : null,
                        removeLabel: strings.t('rooms.members.remove'),
                      ),
                    if (members.length > shown.length)
                      TextButton(
                        onPressed: () => setState(
                          () => _visible += kRoomInfoMemberStep,
                        ),
                        child: Text(strings.t(
                          'modal.chatProfile.membersShowMore',
                          {'count': members.length - shown.length},
                        )),
                      ),
                  ],
                  RoomFilesSection(
                    controller: widget.controller,
                    roomJid: room.jid,
                    readOnly: readOnly,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    enabled: !_busy,
                    leading: Icon(Icons.logout_rounded, color: theme.danger),
                    title: Text(
                      strings.t('action.leave'),
                      style: TextStyle(color: theme.danger),
                    ),
                    onTap: () => _leave(room),
                  ),
                  if (canManage)
                    ListTile(
                      enabled: !_busy,
                      leading: Icon(Icons.delete_outline_rounded,
                          color: theme.danger),
                      title: Text(
                        strings.t('action.deleteChat'),
                        style: TextStyle(color: theme.danger),
                      ),
                      onTap: () => _delete(room),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _typeLabel(ChatStrings strings, String? type) {
    switch (type) {
      case 'public':
        return strings.t('modal.chatProfile.typePublic');
      case 'private':
        return strings.t('modal.chatProfile.typePrivate');
      default:
        return strings.t('modal.chatProfile.typeGroup');
    }
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.title,
    required this.subtitle,
    this.picture,
    this.fileToken,
    this.locked = false,
    this.onPick,
    this.onRemove,
  });

  final String title;
  final String subtitle;
  final String? picture;
  final String? fileToken;
  final bool locked;

  /// Set when the reader may change the picture.
  final VoidCallback? onPick;

  /// Set when there is a picture the reader may clear.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              RoomAvatar(
                name: title,
                url: picture,
                fileToken: fileToken,
                size: 88,
              ),
              if (onPick != null)
                PositionedDirectional(
                  end: -6,
                  bottom: -6,
                  child: Material(
                    color: theme.primary,
                    shape: const CircleBorder(),
                    child: IconButton(
                      key: const ValueKey('room-picture-pick'),
                      tooltip: strings.t('rooms.picture.change'),
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.photo_camera_outlined,
                          color: theme.textOnPrimary),
                      onPressed: onPick,
                    ),
                  ),
                ),
            ],
          ),
          if (onRemove != null)
            TextButton(
              key: const ValueKey('room-picture-remove'),
              onPressed: onRemove,
              child: Text(strings.t('rooms.picture.remove')),
            ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: theme.text,
                  ),
                ),
              ),
              if (locked)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: RoomLockBadge(size: 16),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(color: theme.textMuted)),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: theme.textMuted,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.name,
    required this.isMe,
    required this.youLabel,
    required this.removeLabel,
    this.onRemove,
  });

  final String name;
  final bool isMe;
  final String youLabel;
  final String removeLabel;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    return ListTile(
      dense: true,
      leading: RoomAvatar(name: name, size: 36),
      title: Text(
        isMe ? '$name ($youLabel)' : name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: theme.text),
      ),
      trailing: onRemove == null
          ? null
          : IconButton(
              tooltip: removeLabel,
              icon: Icon(Icons.person_remove_alt_1_outlined,
                  color: theme.textSecondary),
              onPressed: onRemove,
            ),
    );
  }
}

/// Pick people to add: known people not in the room yet, and a typed
/// username.
class _AddMembersView extends StatefulWidget {
  const _AddMembersView({required this.controller, required this.room});

  final ChatComponentController controller;
  final ChatRoom room;

  @override
  State<_AddMembersView> createState() => _AddMembersViewState();
}

class _AddMembersViewState extends State<_AddMembersView> {
  final TextEditingController _search = TextEditingController();
  final List<RoomPerson> _picked = <RoomPerson>[];
  late final List<RoomPerson> _known;

  @override
  void initState() {
    super.initState();
    final state = widget.controller.state.value;
    final inRoom = widget.room.members
        .map((m) => localPart(m.xmppUsername).toLowerCase())
        .toSet();
    _known = collectKnownPeople(
      state.rooms,
      myLocal: (state.user?.xmppUsername ?? '').split('@').first,
    )
        .where((p) => !inRoom.contains(localPart(p.xmppUsername).toLowerCase()))
        .toList();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _addTyped() {
    final username = _search.text.trim();
    if (username.isEmpty) return;
    if (_picked.any((p) => p.xmppUsername == username)) return;
    setState(() {
      _picked
          .add(RoomPerson(xmppUsername: username, userId: '', name: username));
      _search.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    final matches = filterPeople(
      _known
          .where((p) => !_picked.any((x) => x.xmppUsername == p.xmppUsername))
          .toList(),
      _search.text,
      limit: 30,
    );
    return Column(
      children: [
        ChatSheetTitleBar(title: strings.t('modal.addMembers.title')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _addTyped(),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: strings.t('modal.addMembers.userIdPlaceholder'),
              suffixIcon: IconButton(
                tooltip: strings.t('action.add'),
                icon: const Icon(Icons.add_rounded),
                onPressed: _addTyped,
              ),
            ),
          ),
        ),
        if (_picked.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
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
                      dense: true,
                      leading: RoomAvatar(name: person.name, size: 36),
                      title: Text(person.name),
                      trailing: const Icon(Icons.add_rounded),
                      onTap: () => setState(() => _picked.add(person)),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _picked.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_picked),
              child: Text(strings.t(
                'action.addUsersCount',
                {'count': _picked.length},
              )),
            ),
          ),
        ),
      ],
    );
  }
}
