import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/chat_component_config.dart';
import '../models/chat_message.dart';
import '../models/chat_user.dart';
import 'chat_component_log.dart';
import 'chat_component_state.dart';
import 'chat_component_store.dart';
import '../networking/api_client.dart';
import '../networking/auth_service.dart';
import '../networking/rooms_service.dart';
import '../networking/xmpp_client.dart';

typedef XmppClientFactory = XmppClient Function({
  required XmppSettings settings,
  required ChatUser user,
  required void Function(ChatLogEvent event) log,
});

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
  }

  final ChatComponentConfig config;
  final ChatComponentStore _store;
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
          isInitialized: false,
          requiresLogin: true,
        );
        return;
      }

      if (user == null) {
        state.value = state.value.copyWith(
          isLoading: false,
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
    if (user == null) {
      return;
    }

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
        isInitialized: false,
        requiresLogin: true,
        errorMessage: 'Missing XMPP credentials or xmppSettings',
      );
      return;
    }

    _xmpp?.disconnect();
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

    final rooms = await _roomsService.getRooms();
    state.value = state.value.copyWith(rooms: rooms);
    final roomJids = rooms
        .map((e) => e.jid.trim())
        .where((jid) => jid.isNotEmpty)
        .toSet()
        .toList();
    if (roomJids.isNotEmpty) {
      await xmpp.sendPresenceToRooms(roomJids);
    }

    if (roomJids.isNotEmpty) {
      final selected =
          config.disableRooms == true ? roomJids.first : roomJids.first;
      await selectRoom(selected);
    }

    state.value = state.value.copyWith(isLoading: false, isInitialized: true);
  }

  Future<void> selectRoom(String roomJid) async {
    if (roomJid.trim().isEmpty) {
      return;
    }
    state.value = state.value.copyWith(selectedRoomJid: roomJid);
    await _xmpp?.sendRoomPresence(roomJid);
    await _xmpp?.requestHistory(roomJid: roomJid, max: 30);
  }

  Future<void> sendText(String roomJid, String text) async {
    final user = state.value.user;
    if (user == null) {
      return;
    }
    final messageId = _newMessageId();
    _appendPendingMessage(
      ChatMessage(
        id: messageId,
        roomJid: roomJid,
        text: text,
        user: user,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        pending: true,
      ),
    );
    await _xmpp?.sendText(roomJid: roomJid, messageId: messageId, text: text);
  }

  Future<void> sendMedia(
    String roomJid, {
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) async {
    final user = state.value.user;
    if (user == null) {
      return;
    }
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
    _appendPendingMessage(
      ChatMessage(
        id: messageId,
        roomJid: roomJid,
        text: '[media] $mediaUrl',
        user: user,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        pending: true,
        isMedia: true,
        mediaUrl: mediaUrl,
        mimeType: mimeType,
      ),
    );
    await _xmpp?.sendMedia(
      roomJid: roomJid,
      messageId: messageId,
      mediaUrl: mediaUrl,
      mimeType: mimeType,
    );
  }

  Future<void> setTyping(String roomJid, bool isTyping) async {
    if (config.disableTypingIndicator) {
      return;
    }
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
  }) async {
    await _xmpp?.requestHistory(roomJid: roomJid, max: max, beforeId: beforeId);
  }

  Future<void> logout() async {
    _typingStopTimer?.cancel();
    await _xmpp?.disconnect();
    _xmpp = null;
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
      if (room.jid != message.roomJid) {
        return room;
      }
      return room.copyWith(pendingMessages: room.pendingMessages + 1);
    }).toList();
    state.value = state.value.copyWith(
      messagesByRoom: map,
      rooms: updatedRooms,
    );
  }

  void _handleIncomingMessage(ChatMessage incoming) {
    final map = <String, List<ChatMessage>>{...state.value.messagesByRoom};
    final roomMessages = <ChatMessage>[
      ...(map[incoming.roomJid] ?? <ChatMessage>[]),
    ];
    final pendingIndex = roomMessages.indexWhere(
      (m) => m.pending == true && m.text == incoming.text,
    );
    if (pendingIndex >= 0) {
      roomMessages[pendingIndex] = roomMessages[pendingIndex].copyWith(
        pending: false,
        id: incoming.id,
      );
    } else {
      roomMessages.add(incoming);
    }
    map[incoming.roomJid] = roomMessages;
    final updatedRooms = state.value.rooms.map((room) {
      if (room.jid != incoming.roomJid) {
        return room;
      }
      final pending = roomMessages.where((m) => m.pending).length;
      return room.copyWith(
        pendingMessages: pending,
        unreadCount: state.value.selectedRoomJid == incoming.roomJid
            ? 0
            : room.unreadCount + 1,
      );
    }).toList();
    state.value = state.value.copyWith(
      messagesByRoom: map,
      rooms: updatedRooms,
    );
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
    _logController.close();
    state.dispose();
  }
}
