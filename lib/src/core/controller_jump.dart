part of 'chat_component_controller.dart';

/// How a [ChatComponentController.jumpToMessage] request ended.
enum JumpOutcome {
  /// The message is in the live list or in the jump window, and
  /// `state.jumpTarget` names it.
  reached,

  /// The server answered and the message is not in the archive, or it could
  /// not be located.
  notFound,

  /// The request outlived [kJumpTtl].
  expired,

  /// A newer jump or a dispose replaced it.
  superseded,
}

/// Window requests that could not be asked yet (connection or room still
/// coming up) are repeated this many times (web MAX_WINDOW_RETRIES).
const int _kMaxWindowRetries = 6;

class _JumpRuntime {
  int nonce = 0;
  bool paging = false;

  /// The cursors of each room's jump window (the state holds only messages).
  final Map<String, JumpWindow> windows = <String, JumpWindow>{};

  /// Older-history cursor per room: the server's own `<first>`.
  final Map<String, String> historyCursors = <String, String>{};
  MessageSearchService? search;

  void reset() {
    nonce += 1;
    paging = false;
    windows.clear();
    historyCursors.clear();
    search = null;
  }
}

/// Message search, jump to message and MAM cursor handling of
/// [ChatComponentController].
extension ChatControllerSearchJump on ChatComponentController {
  // --- search ---------------------------------------------------------------

  /// True when message search is on (opt-in, needs an appId).
  bool get isMessageSearchAvailable => isMessageSearchEnabled(config);

  /// A fresh debounced search session wired to the archive API. The caller
  /// owns it and calls `dispose()`.
  MessageSearchSession createMessageSearchSession() {
    final service = _jump.search ??=
        MessageSearchService(apiClient: _apiClient, config: config);
    return MessageSearchSession(
      search: ({
        required String q,
        String? chatId,
        String? fromUserId,
        String? since,
        String? until,
        required int offset,
        required int limit,
      }) =>
          service.search(
        q: q,
        chatId: chatId,
        fromUserId: fromUserId,
        since: since,
        until: until,
        offset: offset,
        limit: limit,
      ),
    );
  }

  // --- history cursor -------------------------------------------------------

  bool _roomHasArchivedMessages(String roomJid) {
    final list = state.value.messagesByRoom[roomJid];
    if (list == null) return false;
    return list.any((m) => !m.pending && !m.system && m.id != 'delimiter-new');
  }

  /// Applies the cursor rules after a MAM page answered: the older-paging
  /// cursor from `<first>`, and `historyComplete` from `<fin complete>`.
  void _applyHistoryPage(
    String roomJid,
    MamPage page, {
    required String? beforeId,
    required bool hadMessages,
  }) {
    final next = nextHistoryCursor(
      known: _jump.historyCursors[roomJid],
      pageFirst: page.first,
      olderPage: beforeId != null,
      roomHadMessages: hadMessages,
    );
    if (next != null) _jump.historyCursors[roomJid] = next;
    if (page.complete && !page.error && !page.timedOut) {
      _updateRoom(roomJid, (room) => room.copyWith(historyComplete: true));
    }
  }

  /// The id to ask the next older page `before`: the older of the server's
  /// cursor and the oldest archived message loaded.
  String? _olderAnchor(String roomJid) {
    String? oldest;
    for (final m
        in state.value.messagesByRoom[roomJid] ?? const <ChatMessage>[]) {
      if (m.pending || m.system || m.id == 'delimiter-new') continue;
      final n = int.tryParse(m.id);
      if (n == null || !isArchiveCursor(m.id)) continue;
      if (oldest == null || n < int.parse(oldest)) oldest = m.id;
    }
    return olderPageAnchor(
      cursor: _jump.historyCursors[roomJid],
      oldestLoaded: oldest,
    );
  }

  // --- jump window ----------------------------------------------------------

  Future<HistoryWindowPage> _fetchHistoryWindow(
    String roomJid,
    int max, {
    int? before,
    int? after,
    String? start,
    String? end,
  }) async {
    final xmpp = _xmpp;
    if (xmpp == null) return const HistoryWindowPage();
    final page = await xmpp.requestHistory(
      roomJid: roomJid,
      max: max,
      beforeId: before?.toString(),
      afterId: after?.toString(),
      start: start,
      end: end,
      deliver: false,
    );
    if (page.error || page.timedOut) return const HistoryWindowPage();
    return HistoryWindowPage(
      ok: true,
      messages: sortByArchive(page.messages),
      complete: page.complete,
      first: int.tryParse(page.first ?? ''),
      last: int.tryParse(page.last ?? ''),
      modifiers: page.modifiers,
    );
  }

  /// Takes the reader to a message, opening its room first.
  ///
  /// The target can be in three places, tried in this order: the live list
  /// (within [kNearLiveMessages] of the newest message the list is scrolled);
  /// a window of the archive fetched around it (10 messages before and after,
  /// shown INSTEAD of the live list in `state.jumpWindowByRoom`); or, when
  /// the window cannot be asked, older history paged into the live list.
  /// A hit with no archive id is located by its time and text. The result is
  /// in `state.jumpTarget`; a request lives [kJumpTtl].
  Future<JumpOutcome> jumpToMessage({
    required String roomJid,
    required List<String> ids,
    int? createdAt,
    String? body,
  }) async {
    final jump = _jump;
    final startedAt = DateTime.now();
    final nonce = ++jump.nonce;
    final cleanIds = <String>{
      for (final id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    }.toList();
    final content = JumpContent(createdAtMs: createdAt, body: body);
    if (roomJid.isEmpty || (cleanIds.isEmpty && !content.usable)) {
      return JumpOutcome.notFound;
    }

    bool superseded() => _disposed || jump.nonce != nonce;
    bool expired() => DateTime.now().difference(startedAt) > kJumpTtl;
    List<ChatMessage> live() =>
        state.value.messagesByRoom[roomJid] ?? const <ChatMessage>[];

    // Open the room. A room that is still opening gets a grace period for its
    // live list; then the archive is asked directly.
    if (state.value.selectedRoomJid != roomJid) {
      await selectRoom(roomJid).timeout(kRoomOpeningGrace, onTimeout: () {});
    } else {
      while (live().isEmpty &&
          _xmpp?.state != ChatConnectionState.online &&
          DateTime.now().difference(startedAt) < kRoomOpeningGrace &&
          !superseded()) {
        await Future<void>.delayed(kRoomOpeningPoll);
      }
    }
    if (superseded()) return JumpOutcome.superseded;

    // Already inside the window on screen.
    final onScreen = state.value.jumpWindowByRoom[roomJid];
    if (onScreen != null && onScreen.isNotEmpty) {
      final i = findMessageIndex(onScreen, cleanIds, content: content);
      if (i >= 0) {
        return _publishJump(roomJid, onScreen[i], nonce, keepWindow: true);
      }
    }

    var list = live();
    var index = findMessageIndex(list, cleanIds, content: content);
    if (index >= 0 && list.length - index <= kNearLiveMessages) {
      return _publishJump(roomJid, list[index], nonce);
    }

    // Far or not loaded: fetch a small window around it instead of paging
    // the whole stretch of history between it and the live tail.
    final windowIds = <String>[
      if (index >= 0) list[index].id,
      ...cleanIds,
    ];
    JumpWindowResult result = const JumpWindowUnavailable();
    for (var attempt = 0; attempt <= _kMaxWindowRetries; attempt += 1) {
      if (superseded()) return JumpOutcome.superseded;
      if (expired()) return JumpOutcome.expired;
      result = await loadJumpWindow(
        _fetchHistoryWindow,
        roomJid,
        windowIds,
        content: content,
      );
      final notReady = result is JumpWindowUnavailable &&
          (live().isEmpty || _xmpp?.state != ChatConnectionState.online) &&
          attempt < _kMaxWindowRetries &&
          DateTime.now().difference(startedAt) < kJumpTtl;
      if (!notReady) break;
      await Future<void>.delayed(kRoomOpeningPoll);
    }
    if (superseded()) return JumpOutcome.superseded;
    if (result is JumpWindowFound) {
      final window = result.window;
      final i = window.messages.indexWhere((m) => m.id == window.targetId);
      if (i >= 0) {
        return _publishJump(
          roomJid,
          window.messages[i],
          nonce,
          window: window,
        );
      }
    }
    list = live();
    index = findMessageIndex(list, cleanIds, content: content);
    if (index >= 0) return _publishJump(roomJid, list[index], nonce);
    if (result is JumpWindowMissing) return JumpOutcome.notFound;

    // The window could not be asked: page older history into the live list by
    // the server's own cursor until the target shows up.
    var failures = 0;
    for (var page = 0; page < kMaxHistoryPages; page += 1) {
      if (superseded()) return JumpOutcome.superseded;
      if (expired()) return JumpOutcome.expired;
      final anchor = _olderAnchor(roomJid);
      final answer = await loadHistory(
        roomJid: roomJid,
        max: kJumpPageSize,
        beforeId: anchor,
        source: HistorySource.active,
      );
      if (answer.error || answer.timedOut) {
        failures += 1;
        if (failures >= kMaxPageFailures) break;
        continue;
      }
      failures = 0;
      list = live();
      index = findMessageIndex(list, cleanIds, content: content);
      if (index >= 0) return _publishJump(roomJid, list[index], nonce);
      if (answer.complete) break;
      if (anchor != null &&
          !historyPageProgressed(anchor: anchor, first: answer.first)) {
        break;
      }
    }
    return JumpOutcome.notFound;
  }

  /// Puts [target] in `state.jumpTarget`. With [window] the room shows that
  /// slice instead of the live list; with [keepWindow] the one on screen
  /// stays. A thread-only reply names its root in `threadRootId`, and the
  /// root is made available (in the window) when it is not loaded.
  Future<JumpOutcome> _publishJump(
    String roomJid,
    ChatMessage target,
    int nonce, {
    JumpWindow? window,
    bool keepWindow = false,
  }) async {
    final jump = _jump;
    var shown = window;
    final rootId = replyParentId(target);
    if (rootId != null) {
      final known = <ChatMessage>[
        ...(state.value.messagesByRoom[roomJid] ?? const <ChatMessage>[]),
        ...(keepWindow
            ? (state.value.jumpWindowByRoom[roomJid] ?? const <ChatMessage>[])
            : (window?.messages ?? const <ChatMessage>[])),
      ];
      final rootKnown = known.any((m) => m.id == rootId || m.xmppId == rootId);
      if (!rootKnown) {
        final found = await loadJumpWindow(
          _fetchHistoryWindow,
          roomJid,
          <String>[rootId],
        );
        if (_disposed || jump.nonce != nonce) return JumpOutcome.superseded;
        if (found is JumpWindowFound) {
          final base = keepWindow ? jump.windows[roomJid] : window;
          shown = _windowWithTarget(
            base == null ? found.window : _mergeWindows(base, found.window),
            target,
          );
          keepWindow = false;
        }
      }
    }
    if (_disposed || jump.nonce != nonce) return JumpOutcome.superseded;

    final windows = <String, List<ChatMessage>>{
      ...state.value.jumpWindowByRoom,
    };
    if (shown != null) {
      jump.windows[roomJid] = shown;
      windows[roomJid] = shown.messages;
    } else if (!keepWindow) {
      jump.windows.remove(roomJid);
      windows.remove(roomJid);
    }
    state.value = state.value.copyWith(
      jumpWindowByRoom: windows,
      jumpTarget: ChatJumpTarget(
        roomJid: roomJid,
        messageId: target.id,
        nonce: nonce,
        threadRootId: rootId,
      ),
    );
    return JumpOutcome.reached;
  }

  JumpWindow _windowWithTarget(JumpWindow window, ChatMessage target) {
    return JumpWindow(
      roomJid: window.roomJid,
      messages: mergeWindowMessages(window.messages, <ChatMessage>[target]),
      targetId: target.id,
      olderCursor: window.olderCursor,
      hasOlder: window.hasOlder,
      newerCursor: window.newerCursor,
      hasNewer: window.hasNewer,
    );
  }

  JumpWindow _mergeWindows(JumpWindow a, JumpWindow b) {
    int? lower(int? x, int? y) =>
        x == null ? y : (y == null ? x : (x < y ? x : y));
    int? upper(int? x, int? y) =>
        x == null ? y : (y == null ? x : (x > y ? x : y));
    return JumpWindow(
      roomJid: a.roomJid,
      messages: mergeWindowMessages(a.messages, b.messages),
      targetId: a.targetId,
      olderCursor: lower(a.olderCursor, b.olderCursor),
      hasOlder: a.hasOlder || b.hasOlder,
      newerCursor: upper(a.newerCursor, b.newerCursor),
      hasNewer: a.hasNewer || b.hasNewer,
    );
  }

  /// Leaves the jump window of [roomJid] and shows the live list again (the
  /// "Jump to latest" button). Also called when a message is sent.
  void clearJumpWindow(String roomJid) {
    _jump.windows.remove(roomJid);
    final current = state.value;
    if (!current.jumpWindowByRoom.containsKey(roomJid) &&
        current.jumpTarget?.roomJid != roomJid) {
      return;
    }
    final windows = <String, List<ChatMessage>>{...current.jumpWindowByRoom}
      ..remove(roomJid);
    state.value = current.copyWith(
      jumpWindowByRoom: windows,
      clearJumpTarget: current.jumpTarget?.roomJid == roomJid,
    );
  }

  /// The UI scrolled to and flashed the target: forget it, so the same
  /// target does not fire again when the list rebuilds.
  void acknowledgeJumpTarget(int nonce) {
    if (state.value.jumpTarget?.nonce != nonce) return;
    state.value = state.value.copyWith(clearJumpTarget: true);
  }

  /// True while [roomJid] shows a jump window with older rows to load.
  bool jumpWindowHasOlder(String roomJid) =>
      _jump.windows[roomJid]?.hasOlder ?? false;

  /// True while [roomJid] shows a jump window with newer rows to load.
  bool jumpWindowHasNewer(String roomJid) =>
      _jump.windows[roomJid]?.hasNewer ?? false;

  /// Loads the page above the window of [roomJid]. Returns false when there
  /// is nothing more or the request failed.
  Future<bool> loadJumpWindowOlder(String roomJid) =>
      _pageJumpWindow(roomJid, older: true);

  /// Loads the page below the window of [roomJid].
  Future<bool> loadJumpWindowNewer(String roomJid) =>
      _pageJumpWindow(roomJid, older: false);

  Future<bool> _pageJumpWindow(String roomJid, {required bool older}) async {
    final jump = _jump;
    final window = jump.windows[roomJid];
    if (window == null || jump.paging) return false;
    if (older ? !window.hasOlder : !window.hasNewer) return false;
    jump.paging = true;
    try {
      final next = older
          ? await loadOlderWindowPage(_fetchHistoryWindow, window)
          : await loadNewerWindowPage(_fetchHistoryWindow, window);
      // The reader left the window (or a newer jump replaced it) meanwhile.
      if (next == null ||
          _disposed ||
          !identical(jump.windows[roomJid], window)) {
        return false;
      }
      jump.windows[roomJid] = next;
      state.value = state.value.copyWith(
        jumpWindowByRoom: <String, List<ChatMessage>>{
          ...state.value.jumpWindowByRoom,
          roomJid: next.messages,
        },
      );
      return older ? next.hasOlder : next.hasNewer;
    } finally {
      jump.paging = false;
    }
  }
}
