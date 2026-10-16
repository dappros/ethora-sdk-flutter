import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/chat_component_config.dart';
import '../models/chat_message.dart';
import '../models/chat_room.dart';
import '../models/chat_user.dart';
import 'chat_component_log.dart';
import 'chat_component_state.dart';
import 'chat_component_store.dart';
import 'config_resolver.dart';
import 'history_queue_service.dart';
import 'private_store_sync_service.dart';
import 'send_queue_service.dart';
import 'unread_service.dart';
import '../networking/api_client.dart';
import '../networking/auth_service.dart';
import '../networking/rooms_service.dart';
import '../networking/stanza_parser.dart';
import '../networking/xmpp_client.dart';

typedef XmppClientFactory = XmppClient Function({
  required XmppSettings settings,
  required ChatUser user,
  required void Function(ChatLogEvent event) log,
});

enum _HeapKind { text, media }

class _PendingHeapItem {
  const _PendingHeapItem.text({
    required this.messageId,
    required this.roomJid,
    required this.text,
  })  : kind = _HeapKind.text,
        mediaUrl = null,
        mimeType = null,
        file = null;

  const _PendingHeapItem.media({
    required this.messageId,
    required this.roomJid,
    required this.mediaUrl,
    required this.mimeType,
    required this.file,
  })  : kind = _HeapKind.media,
        text = null;

  final _HeapKind kind;
  final String messageId;
  final String roomJid;
  final String? text;
  final String? mediaUrl;
  final String? mimeType;
  final Map<String, dynamic>? file;
}

/// Pending text turns into "failed" after this long without a server echo
/// (web PENDING_WATCHDOG_MS / MEDIA_PENDING_WATCHDOG_MS).
const Duration kTextPendingWatchdog = Duration(seconds: 10);
const Duration kMediaPendingWatchdog = Duration(seconds: 30);

/// A typer is dropped if no "paused" arrives within this window.
const Duration kTypingExpiry = Duration(seconds: 8);

class ChatComponentController {
  ChatComponentController({
    required this.config,
    ChatComponentStore? store,
    ApiClient? apiClient,
    AuthService? authService,
    RoomsService? roomsService,
    XmppClientFactory? xmppClientFactory,
  }) : _store = store ?? ChatComponentStore() {
    _apiClient = apiClient ??
        ApiClient(
          config: config,
          readAccessToken: _store.getToken,
          readRefreshToken: _store.getRefreshToken,
          writeTokens: (accessToken, refreshToken) async {
            await _store.setToken(accessToken);
            if (refreshToken != null && refreshToken.isNotEmpty) {
              await _store.setRefreshToken(refreshToken);
            }
          },
          clearSession: _onSessionExpired,
          log: _emitLog,
        );
    _authService = authService ??
        AuthService(apiClient: _apiClient, config: config, log: _emitLog);
    _roomsService = roomsService ??
        RoomsService(apiClient: _apiClient, config: config, log: _emitLog);
    _xmppClientFactory = xmppClientFactory ?? XmppClient.new;
    _sendQueue.bindConnectivity(
      () => _xmpp?.state == ChatConnectionState.online,
    );
  }

  final ChatComponentConfig config;
  final ChatComponentStore _store;
  final ConfigResolver _configResolver = const ConfigResolver();
  final UnreadService _unreadService = const UnreadService();
  final SendQueueService _sendQueue = SendQueueService();
  final HistoryQueueService _historyQueue = HistoryQueueService();
  final PrivateStoreSyncService _privateStoreSync = PrivateStoreSyncService();
  final List<_PendingHeapItem> _pendingHeap = <_PendingHeapItem>[];
  final Set<String> _sentCallbackDeliveredFor = <String>{};
  final Map<String, int> _roomEpoch = <String, int>{};
  final Map<String, Timer> _pendingWatchdogs = <String, Timer>{};
  final Map<String, Map<String, (String, Timer)>> _typers =
      <String, Map<String, (String, Timer)>>{};
  final Set<String> _historyInFlight = <String>{};

  late final ApiClient _apiClient;
  late final AuthService _authService;
  late final RoomsService _roomsService;
  XmppClient? _xmpp;
  late final XmppClientFactory _xmppClientFactory;
  Timer? _typingStopTimer;
  Future<void>? _initializing;
  bool _disposed = false;

  final ValueNotifier<ChatComponentState> state =
      ValueNotifier<ChatComponentState>(const ChatComponentState());
  final StreamController<ChatLogEvent> _logController =
      StreamController<ChatLogEvent>.broadcast();

  Stream<ChatLogEvent> get logs => _logController.stream;

  /// Safe to call more than once: concurrent calls share one run, and a
  /// finished run is not repeated until [logout].
  Future<void> initialize() {
    if (state.value.isInitialized) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    state.value = state.value.copyWith(
      isLoading: true,
      globalLoading: true,
      clearErrorMessage: true,
      requiresLogin: false,
    );

    try {
      ChatUser? user;
      if (config.userLogin?.enabled == true && config.userLogin?.user != null) {
        user = config.userLogin!.user;
      }
      user ??= await _store.getUser();

      if (user == null && config.jwtLogin?.enabled == true) {
        user = await loginJwt(config.jwtLogin!.token, initializeAfter: false);
      }

      if (user == null && config.customLogin?.enabled == true) {
        user = await config.customLogin!.loginFunction();
      }

      if (user == null) {
        state.value = state.value.copyWith(
          isLoading: false,
          globalLoading: false,
          isInitialized: false,
          requiresLogin: true,
          errorMessage: config.defaultLogin == true
              ? null
              : 'No authentication strategy succeeded.',
        );
        return;
      }

      await _applyLoggedInUser(user);
      await _initializeRuntime();
    } catch (e) {
      state.value = state.value.copyWith(
        isLoading: false,
        globalLoading: false,
        isInitialized: false,
        errorMessage: e.toString(),
      );
      _log(ChatLogLevel.error, ChatLogCategory.system,
          'Initialization failed: $e');
    }
  }

  Future<ChatUser> loginEmail(
    String email,
    String password, {
    bool initializeAfter = true,
  }) async {
    final user = await _authService.loginWithEmail(
      email: email,
      password: password,
    );
    await _applyLoggedInUser(user);
    if (initializeAfter) {
      await _initializeRuntime();
    }
    return user;
  }

  Future<ChatUser> loginJwt(
    String jwtToken, {
    bool initializeAfter = true,
  }) async {
    final user = await _authService.loginWithJwt(jwtToken);
    await _applyLoggedInUser(user);
    if (initializeAfter) {
      await _initializeRuntime();
    }
    return user;
  }

  Future<void> _applyLoggedInUser(ChatUser user) async {
    await _store.setUser(user);
    if ((user.token ?? '').isNotEmpty) {
      await _store.setToken(user.token!);
    }
    if ((user.refreshToken ?? '').isNotEmpty) {
      await _store.setRefreshToken(user.refreshToken!);
    }
    state.value = state.value.copyWith(user: user, requiresLogin: false);
  }

  String get _myLocal {
    final user = state.value.user;
    return localPart(
      user?.xmppUsername ?? user?.walletAddress ?? user?.username ?? '',
    ).toLowerCase();
  }

  /// True when [message] was written by the signed-in user. Matches web:
  /// the MUC nick (occupant resource) or `<data senderJID>` localpart.
  bool isOwnMessage(ChatMessage message) {
    final me = _myLocal;
    if (me.isEmpty) return false;
    final sender = localPart(
      message.user.xmppUsername ?? message.user.id ?? '',
    ).toLowerCase();
    if (sender == me) return true;
    final senderJid = localPart(message.data['senderJID']).toLowerCase();
    return senderJid.isNotEmpty && senderJid == me;
  }

  Future<void> _initializeRuntime() async {
    final user = state.value.user;
    if (user == null) return;

    final xmppUsername =
        user.xmppUsername ?? user.walletAddress ?? user.username;
    final xmppPassword = user.xmppPassword;
    final xmppSettings = config.xmppSettings;
    if (xmppUsername == null ||
        xmppUsername.isEmpty ||
        xmppPassword == null ||
        xmppPassword.isEmpty ||
        xmppSettings == null) {
      state.value = state.value.copyWith(
        isLoading: false,
        globalLoading: false,
        isInitialized: false,
        requiresLogin: true,
        errorMessage: 'Missing XMPP credentials or xmppSettings',
      );
      return;
    }

    await _xmpp?.disconnect();
    final xmpp = _xmppClientFactory(
      settings: xmppSettings,
      user: user.copyWith(
        xmppUsername: xmppUsername,
        xmppPassword: xmppPassword,
      ),
      log: _emitLog,
    );
    _xmpp = xmpp;
    xmpp.onConnectionChanged = (connection) {
      state.value = state.value.copyWith(connectionState: connection);
      if (connection == ChatConnectionState.online) {
        _sendQueue.resume();
        _historyQueue.resume();
      }
    };
    xmpp.onReconnected = () => unawaited(_onReconnected());
    xmpp.onAuthFailed = (error) {
      state.value = state.value.copyWith(errorMessage: error.toString());
      _log(ChatLogLevel.error, ChatLogCategory.xmpp, error.toString());
    };
    xmpp.onMessage = _handleIncomingMessage;
    xmpp.onEdit = _handleEdit;
    xmpp.onDelete = _handleDelete;
    xmpp.onReaction = _handleReaction;
    xmpp.onTyping = _handleTyping;

    await xmpp.connect();

    final resolved = _configResolver.resolve(config);
    var rooms = await _roomsService.getRooms();
    if (resolved.forcedRoomJid != null &&
        rooms.every((room) => room.jid != resolved.forcedRoomJid)) {
      rooms = <ChatRoom>[
        ...rooms,
        ChatRoom(jid: resolved.forcedRoomJid!, title: resolved.forcedRoomJid),
      ];
    }

    state.value = state.value.copyWith(rooms: rooms);
    final roomJids = _roomJids();
    if (roomJids.isNotEmpty) {
      await xmpp.sendPresenceToRooms(roomJids);
    }

    await syncPrivateStoreTimestamps();

    if (roomJids.isNotEmpty) {
      final selected = resolved.forcedRoomJid ?? roomJids.first;
      await selectRoom(selected);
    }

    state.value = state.value.copyWith(
      isLoading: false,
      globalLoading: false,
      isInitialized: true,
    );
  }

  List<String> _roomJids() => state.value.rooms
      .map((e) => e.jid.trim())
      .where((jid) => jid.isNotEmpty)
      .toSet()
      .toList();

  /// After a dropped socket: re-join every room, catch up the newest page
  /// of each (selected room first) and re-send what was still pending.
  Future<void> _onReconnected() async {
    final xmpp = _xmpp;
    if (xmpp == null) return;
    final roomJids = _roomJids();
    await xmpp.sendPresenceToRooms(roomJids);
    final selected = state.value.selectedRoomJid;
    if (selected != null) {
      await loadHistory(roomJid: selected, source: HistorySource.active);
    }
    for (final jid in roomJids.where((jid) => jid != selected)) {
      unawaited(loadHistory(roomJid: jid, source: HistorySource.background));
    }
    await recoverPendingHeap();
  }

  Future<void> selectRoom(String roomJid) async {
    final normalized = roomJid.trim();
    if (normalized.isEmpty) return;

    state.value = state.value.copyWith(selectedRoomJid: normalized);
    promoteRoomHistory(normalized);
    await _xmpp?.sendRoomPresence(normalized);
    await loadHistory(
      roomJid: normalized,
      max: 30,
      source: HistorySource.active,
    );
    await markRoomViewed(normalized);
    _recalculateUnread();
  }

  String _newMessageId(String prefix) {
    final rnd = Random();
    final suffix = List<String>.generate(
      4,
      (_) => rnd.nextInt(1 << 16).toRadixString(16).padLeft(4, '0'),
    ).join();
    return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$suffix';
  }

  Future<void> sendText(String roomJid, String text) async {
    final user = state.value.user;
    if (user == null || text.trim().isEmpty) return;
    final messageId = _newMessageId('send-text-message');
    final now = DateTime.now().millisecondsSinceEpoch;
    final pending = ChatMessage(
      id: messageId,
      xmppId: messageId,
      roomJid: roomJid,
      text: text,
      user: user,
      createdAtMs: now,
      timestamp: now,
      pending: true,
    );
    _appendPendingMessage(pending);
    _pendingHeap.add(
      _PendingHeapItem.text(messageId: messageId, roomJid: roomJid, text: text),
    );
    _setPendingSendState(messageId, roomJid);
    _armWatchdog(messageId, roomJid, kTextPendingWatchdog);
    promoteRoomHistory(roomJid);
    _enqueueText(messageId, roomJid, text);
  }

  void _enqueueText(String messageId, String roomJid, String text) {
    unawaited(_sendQueue.enqueue(
      id: messageId,
      roomJid: roomJid,
      task: () async {
        final xmpp = _xmpp;
        if (xmpp == null) return false;
        await xmpp.sendText(
          roomJid: roomJid,
          messageId: messageId,
          text: text,
        );
        return true;
      },
    ));
  }

  Future<void> sendMedia(
    String roomJid, {
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) async {
    if (config.disableMedia == true) {
      return;
    }
    final user = state.value.user;
    if (user == null) return;

    final uploadResponse = await _apiClient.upload(
      '/files/',
      bytes: bytes,
      filename: filename,
      mimeType: mimeType,
    );
    final results =
        (uploadResponse['data'] as Map<String, dynamic>?)?['results'] as List?;
    final fileData = (results?.isNotEmpty == true
            ? results!.first as Map<String, dynamic>
            : null) ??
        <String, dynamic>{};
    final mediaUrl = fileData['location']?.toString() ?? '';
    if (mediaUrl.isEmpty) {
      throw Exception('Media upload returned empty location');
    }

    final messageId = _newMessageId('send-media-message');
    final now = DateTime.now().millisecondsSinceEpoch;
    final pending = ChatMessage(
      id: messageId,
      xmppId: messageId,
      roomJid: roomJid,
      text: 'media',
      user: user,
      createdAtMs: now,
      timestamp: now,
      pending: true,
      isMedia: true,
      mediaUrl: mediaUrl,
      mimeType: mimeType,
    );
    _appendPendingMessage(pending);
    _pendingHeap.add(
      _PendingHeapItem.media(
        messageId: messageId,
        roomJid: roomJid,
        mediaUrl: mediaUrl,
        mimeType: mimeType,
        file: fileData,
      ),
    );
    _setPendingSendState(messageId, roomJid);
    _armWatchdog(messageId, roomJid, kMediaPendingWatchdog);
    promoteRoomHistory(roomJid);
    _enqueueMedia(messageId, roomJid, mediaUrl, mimeType, fileData);
  }

  void _enqueueMedia(
    String messageId,
    String roomJid,
    String mediaUrl,
    String mimeType,
    Map<String, dynamic> file,
  ) {
    unawaited(_sendQueue.enqueue(
      id: messageId,
      roomJid: roomJid,
      task: () async {
        final xmpp = _xmpp;
        if (xmpp == null) return false;
        await xmpp.sendMedia(
          roomJid: roomJid,
          messageId: messageId,
          mediaUrl: mediaUrl,
          mimeType: mimeType,
          file: file,
        );
        return true;
      },
    ));
  }

  /// Re-sends a failed message with the same id, like web resendMessage
  /// with reuseId, so a late echo of the first attempt still reconciles.
  Future<void> retryMessage(String roomJid, String messageId) async {
    final item = _pendingHeap
        .where((e) => e.messageId == messageId && e.roomJid == roomJid)
        .firstOrNull;
    if (item == null) return;
    _updateMessage(
        roomJid, messageId, (m) => m.copyWith(failed: false, pending: true));
    _armWatchdog(
      messageId,
      roomJid,
      item.kind == _HeapKind.text
          ? kTextPendingWatchdog
          : kMediaPendingWatchdog,
    );
    if (item.kind == _HeapKind.text) {
      _enqueueText(messageId, roomJid, item.text ?? '');
    } else {
      _enqueueMedia(
        messageId,
        roomJid,
        item.mediaUrl ?? '',
        item.mimeType ?? 'application/octet-stream',
        item.file ?? const <String, dynamic>{},
      );
    }
  }

  void _armWatchdog(String messageId, String roomJid, Duration timeout) {
    _pendingWatchdogs.remove(messageId)?.cancel();
    _pendingWatchdogs[messageId] = Timer(timeout, () {
      _pendingWatchdogs.remove(messageId);
      _updateMessage(roomJid, messageId, (m) {
        if (!m.pending) return m;
        return m.copyWith(pending: false, failed: true);
      });
      _recalculateUnread();
    });
  }

  Future<void> setTyping(String roomJid, bool isTyping) async {
    if (config.disableTypingIndicator) return;
    await _xmpp?.sendTyping(roomJid: roomJid, isTyping: isTyping);
    _typingStopTimer?.cancel();
    if (isTyping) {
      _typingStopTimer = Timer(const Duration(milliseconds: 800), () {
        _xmpp?.sendTyping(roomJid: roomJid, isTyping: false);
      });
    }
  }

  /// Loads one MAM page. Without [beforeId] it fetches the newest page.
  Future<MamPage> loadHistory({
    required String roomJid,
    int max = 30,
    String? beforeId,
    HistorySource source = HistorySource.normal,
  }) async {
    final epoch = _roomEpoch[roomJid] ?? 0;
    var page = const MamPage();
    final task = HistoryTask(
      id: 'history-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(99999)}',
      roomJid: roomJid,
      source: source,
      epoch: epoch,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      run: () async {
        final xmpp = _xmpp;
        if (xmpp == null) return;
        page = await xmpp.requestHistory(
          roomJid: roomJid,
          max: max,
          beforeId: beforeId,
        );
      },
      completer: Completer<void>(),
    );
    await _historyQueue.enqueue(task);
    if (beforeId != null && page.complete) {
      _updateRoom(roomJid, (room) => room.copyWith(historyComplete: true));
    }
    return page;
  }

  /// Loads the page before the oldest archived message of [roomJid]
  /// (scroll-to-top). Returns false when the archive is exhausted or a load
  /// is already running.
  Future<bool> loadOlderMessages(String roomJid, {int max = 30}) async {
    final room = state.value.rooms.where((r) => r.jid == roomJid).firstOrNull;
    if (room?.historyComplete == true) return false;
    if (!_historyInFlight.add(roomJid)) return false;
    try {
      final oldest =
          (state.value.messagesByRoom[roomJid] ?? const <ChatMessage>[])
              .where((m) => !m.pending && !m.system && m.id != 'delimiter-new')
              .map((m) => m.id)
              .where((id) => RegExp(r'^\d+$').hasMatch(id))
              .fold<String?>(null, (min, id) {
        if (min == null) return id;
        return (BigInt.tryParse(id) ?? BigInt.zero) <
                (BigInt.tryParse(min) ?? BigInt.zero)
            ? id
            : min;
      });
      final page = await loadHistory(
        roomJid: roomJid,
        max: max,
        beforeId: oldest,
        source: HistorySource.active,
      );
      if (oldest == null && page.complete) {
        _updateRoom(roomJid, (r) => r.copyWith(historyComplete: true));
      }
      return !page.complete && !page.error;
    } finally {
      _historyInFlight.remove(roomJid);
    }
  }

  Future<void> markRoomViewed(String roomJid, {int? timestampMs}) async {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final map = <String, List<ChatMessage>>{...state.value.messagesByRoom};
    final roomMessages = map[roomJid] ?? const <ChatMessage>[];
    map[roomJid] = _unreadService.normalizeDelimiterPosition(
      roomMessages,
      ts,
      roomJid,
    );

    final updatedRooms = state.value.rooms.map((room) {
      if (room.jid != roomJid) return room;
      return room.copyWith(
        lastViewedTimestamp: ts,
        unreadCount: 0,
        unreadCapped: false,
      );
    }).toList();

    state.value = state.value.copyWith(
      messagesByRoom: map,
      rooms: updatedRooms,
    );
    await _privateStoreSync.write(_xmpp, roomJid: roomJid, timestamp: ts);
  }

  void promoteRoomHistory(String roomJid) {
    _roomEpoch[roomJid] = (_roomEpoch[roomJid] ?? 0) + 1;
    _historyQueue.promoteRoom(roomJid);
    state.value = state.value.copyWith(
      roomEpoch: Map<String, int>.from(_roomEpoch),
    );
  }

  Future<void> syncPrivateStoreTimestamps() async {
    final timestamps = await _privateStoreSync.read(_xmpp);
    if (timestamps.isEmpty) return;
    final updatedRooms = state.value.rooms.map((room) {
      final ts = timestamps[room.jid];
      if (ts == null || ts <= 0) return room;
      return room.copyWith(lastViewedTimestamp: ts);
    }).toList();
    state.value = state.value.copyWith(rooms: updatedRooms);
    _recalculateUnread();
  }

  Future<void> recoverPendingHeap() async {
    final snapshot = List<_PendingHeapItem>.from(_pendingHeap);
    for (final item in snapshot) {
      if (item.kind == _HeapKind.text) {
        _enqueueText(item.messageId, item.roomJid, item.text ?? '');
      } else {
        _enqueueMedia(
          item.messageId,
          item.roomJid,
          item.mediaUrl ?? '',
          item.mimeType ?? 'application/octet-stream',
          item.file ?? const <String, dynamic>{},
        );
      }
    }
  }

  Future<void> logout() async {
    _typingStopTimer?.cancel();
    await _xmpp?.disconnect();
    _xmpp = null;
    _resetRuntimeState();
    await _store.clearSession();
    state.value = const ChatComponentState(
      isInitialized: false,
      requiresLogin: true,
      connectionState: ChatConnectionState.offline,
    );
  }

  /// Called by [ApiClient] when a token refresh failed for good: the
  /// session is gone, so the UI must show the login state.
  Future<void> _onSessionExpired() async {
    await _store.clearSession();
    if (_disposed) return;
    await _xmpp?.disconnect();
    _xmpp = null;
    _resetRuntimeState();
    state.value = const ChatComponentState(
      isInitialized: false,
      requiresLogin: true,
      connectionState: ChatConnectionState.offline,
      errorMessage: 'Session expired. Please sign in again.',
    );
  }

  void _resetRuntimeState() {
    _pendingHeap.clear();
    _sendQueue.clear();
    _historyQueue.clear();
    for (final t in _pendingWatchdogs.values) {
      t.cancel();
    }
    _pendingWatchdogs.clear();
    for (final room in _typers.values) {
      for (final entry in room.values) {
        entry.$2.cancel();
      }
    }
    _typers.clear();
    _historyInFlight.clear();
  }

  void _appendPendingMessage(ChatMessage message) {
    final map = <String, List<ChatMessage>>{...state.value.messagesByRoom};
    final existing = map[message.roomJid] ?? <ChatMessage>[];
    map[message.roomJid] = <ChatMessage>[...existing, message];
    final updatedRooms = state.value.rooms.map((room) {
      if (room.jid != message.roomJid) return room;
      return room.copyWith(pendingMessages: room.pendingMessages + 1);
    }).toList();
    state.value = state.value.copyWith(
      messagesByRoom: map,
      rooms: updatedRooms,
    );
  }

  void _setPendingSendState(String messageId, String roomJid) {
    final pending = <String, String>{...state.value.pendingSendById};
    pending[messageId] = roomJid;
    state.value = state.value.copyWith(pendingSendById: pending);
  }

  void _clearPendingSendState(String messageId) {
    final pending = <String, String>{...state.value.pendingSendById};
    pending.remove(messageId);
    state.value = state.value.copyWith(pendingSendById: pending);
  }

  Future<void> _deliverOnMessageSent(ChatMessage message) async {
    if (_sentCallbackDeliveredFor.contains(message.id)) return;
    _sentCallbackDeliveredFor.add(message.id);
    final callback = config.eventHandlers?.onMessageSent;
    if (callback == null) return;
    await callback(
      ChatMessageSentEvent(
        message: message,
        roomJid: message.roomJid,
        messageId: message.id,
        sentAt: DateTime.now(),
      ),
    );
  }

  void _handleIncomingMessage(ChatMessage incoming) {
    final map = <String, List<ChatMessage>>{...state.value.messagesByRoom};
    final roomMessages = <ChatMessage>[
      ...(map[incoming.roomJid] ?? <ChatMessage>[]),
    ];

    // The echo of our own send carries our outer id as xmppId.
    final pendingIndex = incoming.xmppId == null
        ? -1
        : roomMessages.indexWhere(
            (m) => m.xmppId == incoming.xmppId && (m.pending || m.failed),
          );

    ChatMessage? acked;
    if (pendingIndex >= 0) {
      final local = roomMessages[pendingIndex];
      acked = incoming.copyWith(user: local.user);
      roomMessages[pendingIndex] = acked;
      _pendingHeap.removeWhere((item) => item.messageId == local.xmppId);
      _pendingWatchdogs.remove(local.xmppId)?.cancel();
      _clearPendingSendState(local.xmppId!);
    } else {
      final dupIndex = roomMessages.indexWhere(
        (m) =>
            m.id == incoming.id ||
            (incoming.xmppId != null &&
                m.xmppId == incoming.xmppId &&
                !m.pending),
      );
      if (dupIndex >= 0) {
        final existing = roomMessages[dupIndex];
        roomMessages[dupIndex] = incoming.copyWith(
          reactions: existing.reactions.isNotEmpty ? existing.reactions : null,
          isEdited: existing.isEdited ? true : null,
          text: existing.isEdited ? existing.text : null,
        );
      } else {
        roomMessages.add(incoming);
      }
    }
    roomMessages.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));

    final targetRoom = state.value.rooms.firstWhere(
      (room) => room.jid == incoming.roomJid,
      orElse: () => ChatRoom(jid: incoming.roomJid, title: incoming.roomJid),
    );
    map[incoming.roomJid] = _unreadService.normalizeDelimiterPosition(
      roomMessages,
      targetRoom.lastViewedTimestamp,
      incoming.roomJid,
    );
    state.value = state.value.copyWith(messagesByRoom: map);
    _recalculateUnread();
    if (acked != null) {
      unawaited(_deliverOnMessageSent(acked));
    }
  }

  void _handleEdit(ParsedEdit edit) {
    _updateMessage(
      edit.roomJid,
      edit.targetId,
      (m) => m.copyWith(text: edit.text, isEdited: true),
    );
  }

  void _handleDelete(ParsedDelete delete) {
    _updateMessage(
      delete.roomJid,
      delete.targetId,
      (m) => m
          .copyWith(isDeleted: true, reactions: const <String, ChatReaction>{}),
    );
    _recalculateUnread();
  }

  void _handleReaction(ParsedReaction event) {
    _updateMessage(event.roomJid, event.targetId, (m) {
      final current = m.reactions[event.reactor];
      final currentTs = timestampFromUnknown(current?.ts);
      final nextTs = timestampFromUnknown(event.reaction.ts);
      if (current != null &&
          currentTs > 0 &&
          nextTs > 0 &&
          nextTs < currentTs) {
        return m;
      }
      return m.copyWith(
        reactions: <String, ChatReaction>{
          ...m.reactions,
          event.reactor: event.reaction,
        },
      );
    });
  }

  void _handleTyping(ParsedTyping event) {
    final me = _myLocal;
    if (me.isNotEmpty &&
        (event.nick.toLowerCase() == me ||
            localPart(event.senderJid).toLowerCase() == me)) {
      return;
    }
    final room =
        _typers.putIfAbsent(event.roomJid, () => <String, (String, Timer)>{});
    room.remove(event.nick)?.$2.cancel();
    if (event.composing) {
      final name = event.fullName.trim().split(' ').first;
      room[event.nick] = (
        name.isEmpty ? event.nick : name,
        Timer(kTypingExpiry, () {
          room.remove(event.nick);
          _publishTypers(event.roomJid);
        }),
      );
    }
    _publishTypers(event.roomJid);
  }

  void _publishTypers(String roomJid) {
    final names = (_typers[roomJid] ?? const <String, (String, Timer)>{})
        .values
        .map((e) => e.$1)
        .toList();
    _updateRoom(roomJid, (room) => room.copyWith(composingList: names));
  }

  void _updateRoom(String roomJid, ChatRoom Function(ChatRoom room) update) {
    if (_disposed) return;
    state.value = state.value.copyWith(
      rooms: state.value.rooms
          .map((room) => room.jid == roomJid ? update(room) : room)
          .toList(),
    );
  }

  void _updateMessage(
    String roomJid,
    String messageId,
    ChatMessage Function(ChatMessage message) update,
  ) {
    if (_disposed) return;
    final list = state.value.messagesByRoom[roomJid];
    if (list == null) return;
    var changed = false;
    final next = list.map((m) {
      if (m.id == messageId || m.xmppId == messageId) {
        changed = true;
        return update(m);
      }
      return m;
    }).toList();
    if (!changed) return;
    state.value = state.value.copyWith(
      messagesByRoom: <String, List<ChatMessage>>{
        ...state.value.messagesByRoom,
        roomJid: next,
      },
    );
  }

  void _recalculateUnread() {
    if (_disposed) return;
    final selectedRoomJid = state.value.selectedRoomJid;
    final user = state.value.user;
    final updatedRooms = state.value.rooms.map((room) {
      final messages =
          (state.value.messagesByRoom[room.jid] ?? const <ChatMessage>[])
              .where((m) => !m.isDeleted)
              .toList();
      final unread = _unreadService.computeUnreadForRoom(
        room: room,
        messages: messages,
        activeRoomJid: selectedRoomJid,
        currentUser: user,
      );
      return room.copyWith(
        unreadCount: unread.unread,
        unreadCapped: unread.unreadCapped,
        pendingMessages: messages.where((m) => m.pending).length,
      );
    }).toList();
    state.value = state.value.copyWith(rooms: updatedRooms);
  }

  void _log(ChatLogLevel level, ChatLogCategory category, String message) {
    _emitLog(
      ChatLogEvent(
        level: level,
        category: category,
        message: message,
        timestamp: DateTime.now(),
      ),
    );
  }

  void _emitLog(ChatLogEvent event) {
    if (_logController.isClosed) return;
    _logController.add(event);
  }

  void dispose() {
    _disposed = true;
    _typingStopTimer?.cancel();
    _xmpp?.disconnect();
    _resetRuntimeState();
    _logController.close();
    state.dispose();
  }
}
