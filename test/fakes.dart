import 'dart:async';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';

class InMemoryStore extends ChatComponentStore {
  ChatUser? user;
  String? token;
  String? refreshToken;

  @override
  Future<void> clearSession() async {
    user = null;
    token = null;
    refreshToken = null;
  }

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<String?> getToken() async => token;

  @override
  Future<ChatUser?> getUser() async => user;

  @override
  Future<void> setRefreshToken(String refreshToken) async {
    this.refreshToken = refreshToken;
  }

  @override
  Future<void> setToken(String token) async {
    this.token = token;
  }

  @override
  Future<void> setUser(ChatUser user) async {
    this.user = user;
  }

  @override
  Future<void> clearUser() async {
    user = null;
  }
}

class _NoopApiClient extends ApiClient {
  _NoopApiClient(ChatComponentConfig config)
      : super(
          config: config,
          readAccessToken: () async => null,
          readRefreshToken: () async => null,
          writeTokens: (_, __) async {},
          clearSession: () async {},
          log: (_) {},
        );
}

class FakeAuthService extends AuthService {
  FakeAuthService()
      : super(
          apiClient: _NoopApiClient(const ChatComponentConfig()),
          config: const ChatComponentConfig(),
          log: (_) {},
        );

  ChatUser? emailUser;
  ChatUser? jwtUser;

  @override
  Future<ChatUser> loginWithEmail({
    required String email,
    required String password,
  }) async {
    return emailUser ??
        const ChatUser(
          id: 'u-email',
          username: 'email-user',
          token: 'token',
          refreshToken: 'refresh',
          xmppUsername: 'email-user',
          xmppPassword: 'pass',
        );
  }

  @override
  Future<ChatUser> loginWithJwt(String jwtToken) async {
    return jwtUser ??
        const ChatUser(
          id: 'u-jwt',
          username: 'jwt-user',
          token: 'token',
          refreshToken: 'refresh',
          xmppUsername: 'jwt-user',
          xmppPassword: 'pass',
        );
  }
}

class FakeRoomsService extends RoomsService {
  FakeRoomsService({this.rooms = const <ChatRoom>[]})
      : super(
          apiClient: _NoopApiClient(const ChatComponentConfig()),
          config: const ChatComponentConfig(),
          log: (_) {},
        );

  final List<ChatRoom> rooms;

  @override
  Future<List<ChatRoom>> getRooms() async => rooms;
}

class FakeXmppClient extends XmppClient {
  FakeXmppClient({
    required super.settings,
    required super.user,
    required super.log,
  });

  final List<(String, bool)> typingCalls = <(String, bool)>[];

  @override
  Future<void> connect() async {
    onConnectionChanged?.call(ChatConnectionState.online);
  }

  @override
  Future<void> disconnect() async {
    onConnectionChanged?.call(ChatConnectionState.offline);
  }

  @override
  Future<void> sendPresenceToRooms(List<String> roomJids) async {}

  @override
  Future<void> sendRoomPresence(String roomJid) async {}

  @override
  Future<void> requestHistory({
    required String roomJid,
    int max = 30,
    String? beforeId,
  }) async {}

  @override
  Future<void> sendText({
    required String roomJid,
    required String messageId,
    required String text,
  }) async {}

  @override
  Future<void> sendTyping({
    required String roomJid,
    required bool isTyping,
  }) async {
    typingCalls.add((roomJid, isTyping));
  }

  void emitIncoming(ChatMessage message) {
    onMessage?.call(message);
  }
}
