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
        mimeType = null;

  const _PendingHeapItem.media({
    required this.messageId,
    required this.roomJid,
    required this.mediaUrl,
    required this.mimeType,
  })  : kind = _HeapKind.media,
        text = null;

  final _HeapKind kind;
  final String messageId;
  final String roomJid;
  final String? text;
  final String? mediaUrl;
  final String? mimeType;
}

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
          clearSession: _store.clearSession,
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

  late final ApiClient _apiClient;
  late final AuthService _authService;
  late final RoomsService _roomsService;
  XmppClient? _xmpp;
  late final XmppClientFactory _xmppClientFactory;
  Timer? _typingStopTimer;

  final ValueNotifier<ChatComponentState> state =
      ValueNotifier<ChatComponentState>(const ChatComponentState());
  final StreamController<ChatLogEvent> _logController =
      StreamController<ChatLogEvent>.broadcast();

  Stream<ChatLogEvent> get logs => _logController.stream;

  Future<void> initialize() async {
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

      if (user == null && config.defaultLogin == true) {
        state.value = state.value.copyWith(
          isLoading: false,
          globalLoading: false,
          isInitialized: false,
          requiresLogin: true,
        );
        return;
      }

      if (user == null) {
        state.value = state.value.copyWith(
          isLoading: false,
          globalLoading: false,
          isInitialized: false,
          requiresLogin: true,
          errorMessage: 'No authentication strategy succeeded.',
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
      _emitLog(
        ChatLogEvent(
          level: ChatLogLevel.error,
          category: ChatLogCategory.system,
          message: 'Initialization failed: $e',
          timestamp: DateTime.now(),
        ),
      );
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
    xmpp.onReconnected = () {
      recoverPendingHeap();
    };
    xmpp.onMessage = _handleIncomingMessage;
    xmpp.onTyping = (roomJid, composingUsers) {
      final updatedRooms = state.value.rooms
          .map(
            (room) => room.jid == roomJid
                ? room.copyWith(composingList: composingUsers)
                : room,
          )
          .toList();
      state.value = state.value.copyWith(rooms: updatedRooms);
    };

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
    final roomJids = rooms
        .map((e) => e.jid.trim())
        .where((jid) => jid.isNotEmpty)
        .toSet()
        .toList();
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

  Future<void> sendText(String roomJid, String text) async {
    final user = state.value.user;
    if (user == null || text.trim().isEmpty) return;
    final messageId = _newMessageId();
    final pending = ChatMessage(
      id: messageId,
      roomJid: roomJid,
      text: text,
      user: user,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      pending: true,
    );
    _appendPendingMessage(pending);
    _pendingHeap.add(
      _PendingHeapItem.text(messageId: messageId, roomJid: roomJid, text: text),
    );
    _setPendingSendState(messageId, roomJid);
    promoteRoomHistory(roomJid);

    unawaited(_sendQueue.enqueue(
      id: messageId,
      roomJid: roomJid,
      task: () async {
        await _xmpp?.sendText(
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

    final messageId = _newMessageId();
    final pending = ChatMessage(
      id: messageId,
      roomJid: roomJid,
      text: '[media] $mediaUrl',
      user: user,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
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
      ),
    );
    _setPendingSendState(messageId, roomJid);
    promoteRoomHistory(roomJid);

    unawaited(_sendQueue.enqueue(
      id: messageId,
      roomJid: roomJid,
      task: () async {
        await _xmpp?.sendMedia(
          roomJid: roomJid,
          messageId: messageId,
          mediaUrl: mediaUrl,
          mimeType: mimeType,
        );
        return true;
      },
    ));
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

  Future<void> loadHistory({
    required String roomJid,
    int max = 30,
    String? beforeId,
    HistorySource source = HistorySource.normal,
  }) async {
    final epoch = _roomEpoch[roomJid] ?? 0;
    final task = HistoryTask(
      id: 'history-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(99999)}',
      roomJid: roomJid,
      source: source,
      epoch: epoch,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      run: () async {
        await _xmpp?.requestHistory(
          roomJid: roomJid,
          max: max,
          beforeId: beforeId,
        );
      },
      completer: Completer<void>(),
    );
    await _historyQueue.enqueue(task);
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
    await _privateStoreSync.write(
      _xmpp,
      roomJid: roomJid,
      timestamp: ts,
      chats: state.value.rooms.map((e) => e.jid).toList(),
    );
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
        unawaited(_sendQueue.enqueue(
          id: item.messageId,
          roomJid: item.roomJid,
          task: () async {
            await _xmpp?.sendText(
              roomJid: item.roomJid,
              messageId: item.messageId,
              text: item.text ?? '',
            );
            return true;
          },
        ));
      } else {
        unawaited(_sendQueue.enqueue(
          id: item.messageId,
          roomJid: item.roomJid,
          task: () async {
            await _xmpp?.sendMedia(
              roomJid: item.roomJid,
              messageId: item.messageId,
              mediaUrl: item.mediaUrl ?? '',
              mimeType: item.mimeType ?? 'application/octet-stream',
            );
            return true;
          },
        ));
      }
    }
  }

  Future<void> logout() async {
    _typingStopTimer?.cancel();
    await _xmpp?.disconnect();
    _xmpp = null;
    _pendingHeap.clear();
    _sendQueue.clear();
    _historyQueue.clear();
    await _store.clearSession();
    state.value = const ChatComponentState(
      isInitialized: false,
      requiresLogin: true,
      connectionState: ChatConnectionState.offline,
    );
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

    final pendingIndex = roomMessages.indexWhere(
      (m) =>
          m.pending == true &&
          (m.id == incoming.id ||
              (m.xmppId != null && m.xmppId == incoming.id) ||
              m.text == incoming.text),
    );

    ChatMessage ackedMessage = incoming;
    if (pendingIndex >= 0) {
      final pendingLocal = roomMessages[pendingIndex];
      ackedMessage = pendingLocal.copyWith(
        pending: false,
        id: incoming.id,
        timestamp: incoming.timestamp ?? incoming.createdAtMs,
      );
      roomMessages[pendingIndex] = ackedMessage;
      _pendingHeap.removeWhere((item) => item.messageId == pendingLocal.id);
      _clearPendingSendState(pendingLocal.id);
    } else {
      roomMessages.add(incoming);
    }

    final targetRoom = state.value.rooms.firstWhere(
      (room) => room.jid == incoming.roomJid,
      orElse: () => ChatRoom(jid: incoming.roomJid, title: incoming.roomJid),
    );
    final normalized = _unreadService.normalizeDelimiterPosition(
      roomMessages,
      targetRoom.lastViewedTimestamp,
      incoming.roomJid,
    );
    map[incoming.roomJid] = normalized;
    state.value = state.value.copyWith(messagesByRoom: map);
    _recalculateUnread();
    if (pendingIndex >= 0) {
      unawaited(_deliverOnMessageSent(ackedMessage));
    }
  }

  void _recalculateUnread() {
    final selectedRoomJid = state.value.selectedRoomJid;
    final user = state.value.user;
    final updatedRooms = state.value.rooms.map((room) {
      final messages =
          state.value.messagesByRoom[room.jid] ?? const <ChatMessage>[];
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

  String _newMessageId() {
    return 'flutter-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(100000)}';
  }

  void _emitLog(ChatLogEvent event) {
    _logController.add(event);
  }

  void dispose() {
    _typingStopTimer?.cancel();
    _xmpp?.disconnect();
    _sendQueue.clear();
    _historyQueue.clear();
    _logController.close();
    state.dispose();
  }
}
