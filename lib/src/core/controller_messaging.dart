part of 'chat_component_controller.dart';

/// Reactions, threads, edit/delete and receipts of [ChatComponentController].
/// Wire formats follow the web SDK (see XmppClient.sendReaction and friends).
extension ChatControllerMessaging on ChatComponentController {
  // --- identity and language -------------------------------------------------

  /// Sender language sent with every text (`<translate source>`): the user's
  /// chat language, else the reader locale, else the UI locale.
  String? get _langSource {
    final raw = state.value.user?.chatLanguage ??
        config.translates?.readerLocale ??
        config.i18n?.locale;
    if (raw == null || raw.trim().isEmpty) return null;
    return toBaseLanguage(raw);
  }

  ChatStrings get _uiStrings => ChatStrings.resolve(
        state.value.user?.appLanguage ?? config.i18n?.locale,
        config.i18n?.strings,
      );

  /// Local part of my xmpp username as it appears on the wire (case kept).
  String get _myWireLocal {
    final user = state.value.user;
    return localPart(
      user?.xmppUsername ?? user?.walletAddress ?? user?.username ?? '',
    );
  }

  ChatMessage? messageById(String roomJid, String id) {
    final list = state.value.messagesByRoom[roomJid];
    if (list == null) return null;
    for (final m in list) {
      if (m.id == id || m.xmppId == id) return m;
    }
    return null;
  }

  // --- reactions -------------------------------------------------------------

  bool get reactionsEnabled =>
      config.disableReactions != true &&
      config.reactions?.enabled != false &&
      config.disableInteractions != true;

  /// Toggles my [emoji] (shortcode) on [messageId]: resends my FULL set
  /// without it when present, else with it, like web handleReactionMessage.
  Future<void> toggleReaction(
    String roomJid,
    String messageId,
    String emoji,
  ) async {
    if (!reactionsEnabled) return;
    final message = messageById(roomJid, messageId);
    if (message == null || message.pending || message.failed) return;
    final me = _myWireLocal.toLowerCase();
    final own = message.reactions.entries
            .where((e) => e.key.toLowerCase() == me)
            .map((e) => e.value.emoji)
            .firstOrNull ??
        const <String>[];
    final next = own.contains(emoji)
        ? own.where((e) => e != emoji).toList()
        : <String>[...own, emoji];
    await _xmpp?.sendReaction(
      roomJid: roomJid,
      messageId: message.id,
      reactions: next,
    );
  }

  void _parkReaction(ParsedReaction event) {
    final room = _parkedReactions.putIfAbsent(
      event.roomJid,
      () => <String, Map<String, ChatReaction>>{},
    );
    final byReactor = room.putIfAbsent(
      event.targetId,
      () => <String, ChatReaction>{},
    );
    final current = byReactor[event.reactor];
    if (current != null && compareReactionTs(event.reaction.ts, current.ts) < 0) {
      return;
    }
    byReactor[event.reactor] = event.reaction;
  }

  void _applyParkedReactions(String roomJid, List<ChatMessage> messages) {
    final room = _parkedReactions[roomJid];
    if (room == null || room.isEmpty) return;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final parked = room.remove(m.id) ?? room.remove(m.xmppId ?? '');
      if (parked == null) continue;
      final merged = <String, ChatReaction>{...m.reactions};
      parked.forEach((reactor, reaction) {
        final current = merged[reactor];
        if (current != null && compareReactionTs(reaction.ts, current.ts) < 0) {
          return;
        }
        merged[reactor] = reaction;
      });
      messages[i] = m.copyWith(reactions: merged);
    }
  }

  // --- edit and delete -------------------------------------------------------

  /// Web menu rules: own, non-media, delivered (has an archive id).
  bool canEditMessage(ChatMessage message) =>
      config.disableInteractions != true &&
      isOwnMessage(message) &&
      !message.isMedia &&
      !message.pending &&
      !message.failed &&
      !message.system &&
      !message.isDeleted;

  bool canDeleteMessage(ChatMessage message) =>
      config.disableInteractions != true &&
      isOwnMessage(message) &&
      !message.pending &&
      !message.failed &&
      !message.system &&
      !message.isDeleted;

  void startEdit(ChatMessage message) {
    if (!canEditMessage(message)) return;
    state.value = state.value.copyWith(
      editDraft: ChatEditDraft(
        roomJid: message.roomJid,
        messageId: message.id,
        text: message.text,
      ),
    );
  }

  void cancelEdit() {
    state.value = state.value.copyWith(clearEditDraft: true);
  }

  /// Sends the edit of the message being edited. An unchanged or empty text
  /// just closes the editor.
  Future<void> submitEdit(String text) async {
    final draft = state.value.editDraft;
    if (draft == null) return;
    final next = text.trim();
    state.value = state.value.copyWith(clearEditDraft: true);
    if (next.isEmpty || next == draft.text.trim()) return;
    await _xmpp?.sendEdit(
      roomJid: draft.roomJid,
      messageId: draft.messageId,
      text: next,
    );
    // The echo confirms it; show it at once like the optimistic bubble.
    _updateMessage(
      draft.roomJid,
      draft.messageId,
      (m) => m.copyWith(text: next, isEdited: true),
    );
  }

  Future<void> deleteMessage(ChatMessage message) async {
    if (!canDeleteMessage(message)) return;
    await _xmpp?.sendDelete(roomJid: message.roomJid, messageId: message.id);
    _updateMessage(
      message.roomJid,
      message.id,
      (m) => m.copyWith(
        isDeleted: true,
        reactions: const <String, ChatReaction>{},
      ),
    );
    _recalculateUnread();
  }

  // --- threads ---------------------------------------------------------------

  /// Opens the thread of [message]: its own thread for a root message, the
  /// parent's thread for a reply (web handleReplyMessage).
  void openThread(ChatMessage message) {
    final rootId = threadParentId(message) ?? message.id;
    openThreadById(message.roomJid, rootId);
  }

  void openThreadById(String roomJid, String rootId) {
    state.value = state.value.copyWith(
      activeThread: ChatThreadRef(roomJid: roomJid, rootId: rootId),
    );
    unawaited(loadThreadHistory());
  }

  void closeThread() {
    state.value = state.value.copyWith(clearActiveThread: true);
  }

  /// The root message of the open thread, when it is loaded.
  ChatMessage? get activeThreadRoot {
    final thread = state.value.activeThread;
    return thread == null ? null : messageById(thread.roomJid, thread.rootId);
  }

  /// Replies of [rootId] oldest first (web: isReply and parent id match).
  List<ChatMessage> threadRepliesOf(String roomJid, String rootId) {
    final list = state.value.messagesByRoom[roomJid] ?? const <ChatMessage>[];
    return list
        .where((m) => !m.isDeleted && threadParentId(m) == rootId)
        .toList();
  }

  /// Sends a reply into the open thread. [alsoSendToRoom] also posts it in
  /// the channel (`showInChannel`).
  Future<void> sendThreadReply(
    String text, {
    bool alsoSendToRoom = false,
  }) async {
    final thread = state.value.activeThread;
    final root = activeThreadRoot;
    if (thread == null || root == null) return;
    await sendText(
      thread.roomJid,
      text,
      mainMessage: createMainMessage(root, _uiStrings),
      showInChannel: alsoSendToRoom,
    );
  }

  /// Pages the archive back (15 per page, web THREAD_HISTORY_PAGE_SIZE)
  /// until the thread root is reached, so every reply is loaded.
  Future<void> loadThreadHistory() async {
    final thread = state.value.activeThread;
    if (thread == null) return;
    final key = '${thread.roomJid}\n${thread.rootId}';
    if (!_threadHistoryInFlight.add(key)) return;
    try {
      final rootCursor = BigInt.tryParse(thread.rootId);
      String? previousCursor;
      for (var page = 0; page < 40; page++) {
        final room = state.value.rooms
            .where((r) => r.jid == thread.roomJid)
            .firstOrNull;
        if (room?.historyComplete == true) break;
        final oldest = _oldestArchiveId(thread.roomJid);
        if (oldest == null || oldest == previousCursor) break;
        final cursor = BigInt.tryParse(oldest);
        if (rootCursor != null && cursor != null && cursor <= rootCursor) break;
        previousCursor = oldest;
        final result = await loadHistory(
          roomJid: thread.roomJid,
          max: 15,
          beforeId: oldest,
          source: HistorySource.active,
        );
        if (result.complete || result.error || result.timedOut) break;
        if (state.value.activeThread?.rootId != thread.rootId) break;
      }
    } finally {
      _threadHistoryInFlight.remove(key);
    }
  }

  String? _oldestArchiveId(String roomJid) {
    final list = state.value.messagesByRoom[roomJid] ?? const <ChatMessage>[];
    BigInt? best;
    String? bestId;
    for (final m in list) {
      if (m.pending || m.system || m.id == 'delimiter-new') continue;
      if (!RegExp(r'^\d+$').hasMatch(m.id)) continue;
      final value = BigInt.parse(m.id);
      if (best == null || value < best) {
        best = value;
        bestId = m.id;
      }
    }
    return bestId;
  }

  // --- receipts and read markers --------------------------------------------

  ReceiptsConfig get _receipts => config.receipts ?? const ReceiptsConfig();

  void _wireMessaging(XmppClient xmpp) {
    _deliveryBatcher?.dispose();
    _deliveryBatcher = DeliveryReceiptBatcher(
      send: (roomJid, messageId) =>
          _xmpp?.sendReceivedReceipt(roomJid: roomJid, messageId: messageId),
    );
    xmpp.onReceipt = _handleReceipt;
    xmpp.onDisplayed = _handleDisplayed;
  }

  void _handleReceipt(ParsedReceipt receipt) {
    if (receipt.fromXmppUsername.toLowerCase() == _myWireLocal.toLowerCase()) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _updateMessage(receipt.roomJid, receipt.messageId, (m) {
      if (m.receivedBy.containsKey(receipt.fromXmppUsername)) return m;
      return m.copyWith(
        receivedBy: <String, int>{
          ...m.receivedBy,
          receipt.fromXmppUsername: now,
        },
      );
    });
  }

  void _handleDisplayed(ParsedDisplayed marker) {
    if (marker.xmppUsername.toLowerCase() == _myWireLocal.toLowerCase()) {
      return;
    }
    _updateRoom(marker.roomJid, (room) {
      final current = room.lastDisplayedByUser[marker.xmppUsername];
      final currentValue = BigInt.tryParse(current ?? '');
      final nextValue = BigInt.tryParse(marker.messageId);
      if (currentValue != null &&
          nextValue != null &&
          currentValue >= nextValue) {
        return room;
      }
      return room.copyWith(
        lastDisplayedByUser: <String, String>{
          ...room.lastDisplayedByUser,
          marker.xmppUsername: marker.messageId,
        },
      );
    });
  }

  ChatRoom? _roomByJid(String roomJid) =>
      state.value.rooms.where((r) => r.jid == roomJid).firstOrNull;

  /// Live message hook: ack delivery of someone else's message and schedule
  /// the read marker when its room is open.
  void _afterIncomingMessage(ChatMessage incoming, {required bool wasOwnEcho}) {
    if (_disposed || wasOwnEcho || incoming.system) return;
    if (incoming.pending || isOwnMessage(incoming)) return;
    if (!incoming.isHistory) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (shouldSendDelivery(
        room: _roomByJid(incoming.roomJid),
        message: incoming,
        config: _receipts,
        nowMs: now,
      )) {
        _deliveryBatcher?.enqueue(
          incoming.roomJid,
          incoming.id,
          _receipts.coalesceMs,
          timestamp: now,
        );
      }
    }
    if (incoming.roomJid == state.value.selectedRoomJid) {
      _scheduleMarkRead(incoming.roomJid);
    }
  }

  /// After a reconnect catch-up: one receipt covers the whole replayed page.
  void _ackCatchUp(String roomJid, MamPage page) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final others = page.messages
        .where((m) => !m.system && !isOwnMessage(m) && m.id.isNotEmpty)
        .toList();
    if (others.isEmpty) return;
    final newest = others.last;
    if (!shouldSendDelivery(
      room: _roomByJid(roomJid),
      message: newest,
      config: _receipts,
      nowMs: now,
    )) {
      return;
    }
    _deliveryBatcher?.enqueue(
      roomJid,
      newest.id,
      _receipts.coalesceMs,
      timestamp: now,
    );
  }

  void _scheduleMarkRead(String roomJid) {
    if (config.disableLastRead == true) return;
    _markReadTimers.remove(roomJid)?.cancel();
    _markReadTimers[roomJid] = Timer(const Duration(seconds: 1), () {
      _markReadTimers.remove(roomJid);
      if (_disposed) return;
      unawaited(flushRead(roomJid));
    });
  }

  /// Marks [roomJid] viewed now: private-store read marker plus the XEP-0333
  /// displayed marker for the newest message of someone else.
  Future<void> flushRead(String roomJid) async {
    if (config.disableLastRead == true || _disposed) return;
    await markRoomViewed(roomJid);
    final list = state.value.messagesByRoom[roomJid] ?? const <ChatMessage>[];
    ChatMessage? latest;
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.pending || m.system || m.id == 'delimiter-new') continue;
      latest = m;
      break;
    }
    if (latest == null || isOwnMessage(latest)) return;
    if (!RegExp(r'^\d+$').hasMatch(latest.id)) return;
    if (!shouldSendRead(room: _roomByJid(roomJid), config: _receipts)) return;
    final throttle = _displayedThrottles.putIfAbsent(
      roomJid,
      () => DisplayedMarkerThrottle(
        send: (id) =>
            _xmpp?.sendDisplayedMarker(roomJid: roomJid, messageId: id),
      ),
    );
    throttle.mark(latest.id);
  }

  void _disposeMessagingRuntime() {
    for (final timer in _markReadTimers.values) {
      timer.cancel();
    }
    _markReadTimers.clear();
    for (final throttle in _displayedThrottles.values) {
      throttle.dispose();
    }
    _displayedThrottles.clear();
    _deliveryBatcher?.dispose();
    _deliveryBatcher = null;
    _parkedReactions.clear();
    _threadHistoryInFlight.clear();
  }
}

/// Compares two reaction timestamps (archive ids). Archive ids are 16-digit
/// microsecond counters, so digit strings compare as integers (converting to
/// ms would lose the order of two events in the same millisecond). Returns
/// 0 when either is unknown, so an event without a timestamp is accepted.
int compareReactionTs(String? a, String? b) {
  final x = BigInt.tryParse((a ?? '').trim());
  final y = BigInt.tryParse((b ?? '').trim());
  if (x != null && y != null) return x.compareTo(y);
  final tx = timestampFromUnknown(a);
  final ty = timestampFromUnknown(b);
  if (tx <= 0 || ty <= 0) return 0;
  return tx.compareTo(ty);
}
