part of 'chat_component_controller.dart';

/// What happened to the room list that the user did not ask for directly.
enum ChatRoomEventType {
  /// The room owner removed me from the room (presence 110 and 321).
  kicked,

  /// I left the room.
  left,

  /// I deleted the room.
  deleted,

  /// A room I created is in the list.
  created,

  /// I joined a room (public directory).
  joined,
}

class ChatRoomEvent {
  const ChatRoomEvent(this.type, this.roomJid, {this.title});

  final ChatRoomEventType type;
  final String roomJid;

  /// The room's title at the time, for a message to the user.
  final String? title;
}

class _RoomsRuntime {
  RoomActionsService? actions;
  EthoraEventRouter? router;
  final StreamController<ChatRoomEvent> events =
      StreamController<ChatRoomEvent>.broadcast();

  /// Called with a room JID after this session joined or created a room
  /// (push registration and similar per-room work hook in here).
  final List<void Function(String roomJid)> joinedHooks =
      <void Function(String roomJid)>[];

  /// The caller's files (Files panel and room profile share it).
  MyFilesModel? files;

  void reset() {
    router?.dispose();
    router = null;
    files?.dispose();
    files = null;
  }
}

/// Room management and server events of [ChatComponentController]: mute,
/// report, leave, members, delete, create, the public directory, and the
/// `ethora-event`, membership and kicked pushes.
extension ChatControllerRooms on ChatComponentController {
  /// REST calls for rooms (mute, report, members, directory...).
  RoomActionsService get roomActions => _rooms.actions ??=
      RoomActionsService(apiClient: _apiClient, config: config, log: _emitLog);

  /// The caller's uploaded files, paged. Created on first use and shared;
  /// call `ensureLoaded()` when a view opens.
  MyFilesModel get myFiles => _rooms.files ??=
      MyFilesModel(service: FilesService(apiClient: _apiClient));

  /// Deletes an uploaded file. Once the backend confirms, the chat messages
  /// that carry it are retracted too (locally and for the room), so no broken
  /// picture is left behind. A failed delete changes nothing and rethrows.
  Future<void> deleteMyFile(ApiFile file) async {
    final matches = findMessagesForFile(state.value.messagesByRoom, file);
    await myFiles.remove(file.id);
    for (final match in matches) {
      await _xmpp?.sendDelete(
        roomJid: match.roomJid,
        messageId: match.messageId,
      );
      _updateMessage(
        match.roomJid,
        match.messageId,
        (m) => m.copyWith(
          isDeleted: true,
          reactions: const <String, ChatReaction>{},
        ),
      );
    }
    if (matches.isNotEmpty) _recalculateUnread();
  }

  /// Uploads [file] as the picture of [roomJid] (web: upload, `PATCH` the
  /// chat's picture, then the XMPP room profile). The REST step is what
  /// survives a reload, but a failure of it is not fatal: the picture still
  /// shows for this session. Returns the picture URL.
  Future<String> setRoomPicture(String roomJid, MediaFileInput file) async {
    final result = await _mediaUploads.uploadFile(
      roomJid: roomJid,
      bytes: file.bytes,
      filename: file.filename,
      mimeType: file.mimeType,
    );
    final location = result['location']?.toString() ?? '';
    if (location.isEmpty) throw StateError('room_picture_upload_empty');
    try {
      await roomActions.patchRoom(localPart(roomJid), picture: location);
    } catch (e) {
      _log(ChatLogLevel.warn, ChatLogCategory.rooms,
          'Room picture was not saved on the server: $e');
    }
    _xmpp?.sendRoomImage(roomJid: roomJid, thumbnail: location);
    _updateRoom(roomJid, (room) => room.copyWith(picture: location));
    return location;
  }

  /// Clears the picture of [roomJid].
  Future<void> removeRoomPicture(String roomJid) async {
    await roomActions.patchRoom(localPart(roomJid), picture: '');
    _xmpp?.sendRoomImage(roomJid: roomJid, thumbnail: '');
    _updateRoom(roomJid, (room) => room.copyWith(picture: ''));
  }

  /// Room list changes that happen outside a UI action (kicked, left...).
  Stream<ChatRoomEvent> get roomEvents => _rooms.events.stream;

  /// Callbacks run with the JID after this session joined or created a room.
  /// Push subscription hooks in here: `controller.onRoomJoined.add(...)`.
  List<void Function(String roomJid)> get onRoomJoined => _rooms.joinedHooks;

  String get _sessionAppId =>
      (config.appId ?? state.value.user?.appId ?? '').trim();

  String get _conferenceHost {
    final configured = config.xmppSettings?.conference ?? '';
    if (configured.isNotEmpty) return configured;
    final host = config.xmppSettings?.host ?? '';
    return host.isEmpty ? '' : 'conference.$host';
  }

  ChatRoom? _roomByJid(String roomJid) =>
      state.value.rooms.where((r) => r.jid == roomJid).firstOrNull;

  ChatRoom? _roomByChatName(String chatName) =>
      state.value.rooms.where((r) => localPart(r.jid) == chatName).firstOrNull;

  // --- server pushes --------------------------------------------------------

  void _wireRoomEvents(XmppClient xmpp) {
    _rooms.router?.dispose();
    final router = EthoraEventRouter(
      holdsRoom: (chatName) => _roomByChatName(chatName) != null,
      refreshRoom: _refreshRoomMeta,
      refreshUser: (username) => unawaited(_refreshUserProfile(username)),
    );
    _rooms.router = router;
    xmpp.onEthoraEvent = (event) => router.handle(
          event,
          ownDomain: xmpp.ownDomain,
          appId: _sessionAppId,
          trustedSenders: config.trustedEventSenders,
        );
    xmpp.onMembership = _handleMembership;
    xmpp.onPresence = _handleRoomPresence;
  }

  void _handleMembership(ParsedMembership change) {
    final room = _roomByJid(change.roomJid);
    if (room == null) return;
    final next = applyMembershipChange(room, change);
    if (identical(next, room)) return;
    _updateRoom(change.roomJid, (_) => next);
  }

  void _handleRoomPresence(ParsedPresence presence) {
    // My own join echo (status 110) says what I may do in the room.
    if (!presence.unavailable && presence.statusCodes.contains('110')) {
      final role = roleFromAffiliation(presence.affiliation);
      final held = _roomByJid(presence.roomJid);
      if (role.isNotEmpty && held != null && held.role != role) {
        _updateRoom(presence.roomJid, (room) => room.copyWith(role: role));
      }
      return;
    }
    if (!presence.isKicked) return;
    final room = _roomByJid(presence.roomJid);
    if (room == null) return;
    _removeRoomLocally(presence.roomJid);
    _rooms.events.add(ChatRoomEvent(
      ChatRoomEventType.kicked,
      presence.roomJid,
      title: room.title,
    ));
  }

  /// `chat-meta-updated`: re-reads one room and applies title, description,
  /// picture, type and the user count (never lowered). Throws on failure so
  /// the router backs off.
  Future<void> _refreshRoomMeta(String chatName) async {
    final room = _roomByChatName(chatName);
    if (room == null) return;
    final api = _unwrapRoom(await roomActions.roomByName(chatName));
    if (_disposed) return;
    _updateRoom(
      room.jid,
      (current) => applyChatMeta(current, api, myLocal: _myLocal),
    );
  }

  Map<String, dynamic> _unwrapRoom(Map<String, dynamic> body) {
    final result = body['result'];
    return result is Map ? Map<String, dynamic>.from(result) : body;
  }

  /// `user-profile-updated`: re-reads one user and refreshes the name and
  /// photo in every loaded message, member list and (for me) the session user.
  Future<void> _refreshUserProfile(String xmppUsername) async {
    final result = await roomActions.lookupUser(xmppUsername);
    final profile = result.user;
    if (_disposed || result.status != UserLookupStatus.ok || profile == null) {
      return;
    }
    final wanted = localPart(xmppUsername).toLowerCase();

    ChatUser refreshed(ChatUser user) => user.copyWith(
          firstName: profile.firstName.isEmpty ? null : profile.firstName,
          lastName: profile.lastName.isEmpty ? null : profile.lastName,
          photoUrl: profile.profileImage.isEmpty ? null : profile.profileImage,
        );
    bool isThem(ChatUser user) =>
        localPart(user.xmppUsername ?? user.id).toLowerCase() == wanted;

    Map<String, List<ChatMessage>> remap(Map<String, List<ChatMessage>> all) {
      return all.map((room, list) {
        if (!list.any((m) => isThem(m.user))) return MapEntry(room, list);
        return MapEntry(
          room,
          [
            for (final m in list)
              isThem(m.user) ? m.copyWith(user: refreshed(m.user)) : m,
          ],
        );
      });
    }

    final current = state.value;
    final me = current.user;
    state.value = current.copyWith(
      user: me != null && isThem(me) ? refreshed(me) : null,
      messagesByRoom: remap(current.messagesByRoom),
      jumpWindowByRoom: remap(current.jumpWindowByRoom),
      rooms: [
        for (final room in current.rooms)
          room.members
                  .any((m) => localPart(m.xmppUsername).toLowerCase() == wanted)
              ? room.copyWith(members: [
                  for (final m in room.members)
                    localPart(m.xmppUsername).toLowerCase() == wanted
                        ? ChatRoomMember(
                            id: m.id.isEmpty ? profile.id : m.id,
                            xmppUsername: m.xmppUsername,
                            firstName: profile.firstName,
                            lastName: profile.lastName,
                          )
                        : m,
                ])
              : room,
      ],
    );
  }

  // --- local list -----------------------------------------------------------

  /// Takes a room out of this session's lists (leave, delete, kicked).
  void _removeRoomLocally(String roomJid) {
    _roomEpoch.remove(roomJid);
    _typers.remove(roomJid)?.values.forEach((entry) => entry.$2.cancel());
    _jump.windows.remove(roomJid);
    _jump.historyCursors.remove(roomJid);
    final current = state.value;
    final wasSelected = current.selectedRoomJid == roomJid;
    state.value = current.copyWith(
      rooms: current.rooms.where((r) => r.jid != roomJid).toList(),
      messagesByRoom: <String, List<ChatMessage>>{...current.messagesByRoom}
        ..remove(roomJid),
      jumpWindowByRoom: <String, List<ChatMessage>>{...current.jumpWindowByRoom}
        ..remove(roomJid),
      clearSelectedRoom: wasSelected,
      clearJumpTarget: current.jumpTarget?.roomJid == roomJid,
      clearActiveThread: current.activeThread?.roomJid == roomJid,
    );
  }

  void _fireRoomJoined(String roomJid) {
    for (final hook in List<void Function(String)>.of(_rooms.joinedHooks)) {
      try {
        hook(roomJid);
      } catch (e) {
        _log(ChatLogLevel.warn, ChatLogCategory.rooms,
            'onRoomJoined hook failed: $e');
      }
    }
  }

  /// Adds a room created or joined by this session to the list, joins its
  /// MUC and runs the [onRoomJoined] hooks.
  Future<ChatRoom> _adoptRoom(
    ChatRoom room, {
    required ChatRoomEventType event,
  }) async {
    final exists = _roomByJid(room.jid) != null;
    state.value = state.value.copyWith(
      rooms: exists
          ? state.value.rooms.map((r) => r.jid == room.jid ? room : r).toList()
          : <ChatRoom>[room, ...state.value.rooms],
    );
    await _xmpp?.sendRoomPresence(room.jid);
    _fireRoomJoined(room.jid);
    _rooms.events.add(ChatRoomEvent(event, room.jid, title: room.title));
    return room;
  }

  ChatRoom _roomFromApiResult(Map<String, dynamic> result) {
    final room = chatRoomFromApi(
      result,
      conference: _conferenceHost,
      myLocal: _myLocal,
    );
    if (room.jid.isEmpty) throw StateError('room_jid_missing');
    return room;
  }

  // --- actions --------------------------------------------------------------

  /// Mutes or unmutes the room for me. Throws on failure; the room keeps its
  /// previous state then.
  Future<void> setRoomMuted(String roomJid, bool muted) async {
    final now = await roomActions.setMuted(localPart(roomJid), muted);
    _updateRoom(roomJid, (room) => room.copyWith(muted: now));
  }

  /// Reports a chat. [category] is one of the `report.category.*` ids.
  Future<void> reportRoom(
    String roomJid, {
    required String category,
    String text = '',
  }) {
    return roomActions.reportRoom(
      localPart(roomJid),
      category: category,
      text: text,
    );
  }

  /// Leaves a room: removes my membership (a 404 counts as already gone),
  /// leaves the MUC for this session, then drops the room locally. On a
  /// failure the chat stays and the error is rethrown.
  Future<void> leaveRoom(String roomJid) async {
    final room = _roomByJid(roomJid);
    await roomActions.leaveRoom(localPart(roomJid), _myWireLocal);
    _xmpp?.sendRoomLeave(roomJid);
    _removeRoomLocally(roomJid);
    _rooms.events.add(ChatRoomEvent(
      ChatRoomEventType.left,
      roomJid,
      title: room?.title,
    ));
  }

  /// Deletes a room for everyone, then drops it locally.
  Future<void> deleteRoom(String roomJid) async {
    final room = _roomByJid(roomJid);
    await roomActions.deleteRoom(localPart(roomJid));
    _removeRoomLocally(roomJid);
    _rooms.events.add(ChatRoomEvent(
      ChatRoomEventType.deleted,
      roomJid,
      title: room?.title,
    ));
  }

  /// Adds members by xmpp username: REST first, then a direct MUC invite for
  /// each, then a refresh of the member list. Returns the per-member results.
  Future<List<Map<String, dynamic>>> addRoomMembers(
    String roomJid,
    List<String> xmppUsernames,
  ) async {
    final results =
        await roomActions.addMembers(localPart(roomJid), xmppUsernames);
    for (final username in xmppUsernames) {
      _xmpp?.sendRoomInvite(roomJid: roomJid, username: localPart(username));
    }
    try {
      await refreshRoomMembers(roomJid);
    } catch (_) {
      // The add worked; the list refreshes with the next server push.
    }
    return results;
  }

  /// Removes members by xmpp username and updates the room's list and count.
  Future<void> removeRoomMembers(
    String roomJid,
    List<String> xmppUsernames,
  ) async {
    await roomActions.removeMembers(localPart(roomJid), xmppUsernames);
    final gone = xmppUsernames.map((u) => localPart(u).toLowerCase()).toSet();
    _updateRoom(roomJid, (room) {
      final next = room.members
          .where((m) => !gone.contains(localPart(m.xmppUsername).toLowerCase()))
          .toList();
      final removed = room.members.length - next.length;
      return room.copyWith(
        members: next,
        usersCnt: adjustUsersCnt(room, -removed, next.length),
      );
    });
  }

  /// Re-reads a room's member list and total from the API.
  Future<void> refreshRoomMembers(String roomJid) async {
    final api = _unwrapRoom(await roomActions.roomByName(localPart(roomJid)));
    final fresh = ChatRoom.fromApi(<String, dynamic>{...api, 'jid': roomJid});
    _updateRoom(roomJid, (room) {
      final total = fresh.usersCnt > fresh.members.length
          ? fresh.usersCnt
          : fresh.members.length;
      return room.copyWith(
        members: fresh.members.isEmpty ? null : fresh.members,
        usersCnt: total,
      );
    });
  }

  /// Profile of a user by xmpp username, or null (unknown, not allowed, or
  /// the lookup failed).
  Future<UserProfile?> lookupUserProfile(String xmppUsername) async {
    final result = await roomActions.lookupUser(xmppUsername);
    return result.status == UserLookupStatus.ok ? result.user : null;
  }

  /// Opens (or creates) the 1:1 chat with [username] and joins it.
  Future<ChatRoom> createPrivateChat(
    String username, {
    bool e2ee = false,
  }) async {
    final result = await roomActions.createPrivateRoom(username, e2ee: e2ee);
    return _adoptRoom(
      _roomFromApiResult(result),
      event: ChatRoomEventType.created,
    );
  }

  /// Creates a group (`type: group`, members only) or public chat.
  Future<ChatRoom> createGroupChat({
    required String title,
    String description = '',
    String picture = '',
    String type = 'group',
    List<String> members = const <String>[],
    MediaFileInput? avatar,
  }) async {
    final result = await roomActions.createRoom(
      title: title,
      description: description,
      picture: picture,
      type: type,
      members: members,
    );
    final room = await _adoptRoom(
      _roomFromApiResult(result),
      event: ChatRoomEventType.created,
    );
    if (avatar == null) return room;
    // The room exists now, which is what an upload scoped to it needs. A
    // failed picture must not undo the room.
    try {
      await setRoomPicture(room.jid, avatar);
    } catch (e) {
      _log(ChatLogLevel.warn, ChatLogCategory.rooms,
          'Room picture upload failed: $e');
    }
    return _roomByJid(room.jid) ?? room;
  }

  /// One page of the public directory.
  Future<PublicChatsPage> loadPublicChats({
    int offset = 0,
    int limit = kPublicChatsPageSize,
  }) {
    return roomActions.publicChats(offset: offset, limit: limit);
  }

  /// Joins a public chat by MUC presence (there is no REST call for it) and
  /// opens it. The server registers the membership a few seconds later, so
  /// the member list is refreshed then.
  Future<ChatRoom> joinPublicChat(PublicChat chat) async {
    final jid = '${chat.name}@$_conferenceHost';
    final existing = _roomByJid(jid);
    if (existing != null) {
      await selectRoom(jid);
      return existing;
    }
    final room = await _adoptRoom(
      ChatRoom(
        jid: jid,
        title: chat.displayTitle,
        description: chat.description,
        picture: chat.picture,
        type: 'public',
        e2ee: chat.e2ee,
      ),
      event: ChatRoomEventType.joined,
    );
    await selectRoom(jid);
    unawaited(Future<void>.delayed(const Duration(seconds: 3), () async {
      if (_disposed || _roomByJid(jid) == null) return;
      try {
        await _refreshRoomMeta(chat.name);
        await refreshRoomMembers(jid);
      } catch (_) {
        // Best effort: the next /chats/my brings the same data.
      }
    }));
    return room;
  }

  void _disposeRoomsRuntime() {
    _rooms.reset();
    if (_disposed) _rooms.events.close();
  }

  void _disposeJumpRuntime() => _jump.reset();
}
