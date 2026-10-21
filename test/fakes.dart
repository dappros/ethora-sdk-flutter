import 'dart:async';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/networking/stanza_parser.dart';

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
  ChatConnectionState get state => ChatConnectionState.online;

  @override
  Future<void> connect() async {
    onConnectionChanged?.call(ChatConnectionState.online);
  }

  @override
  Future<void> disconnect() async {
    onConnectionChanged?.call(ChatConnectionState.offline);
  }

  @override
  Future<void> sendPresenceToRooms(List<String> roomJids) async {
    joinedRooms.addAll(roomJids);
  }

  @override
  Future<void> sendRoomPresence(String roomJid) async {}

  final List<String> sentTextIds = <String>[];
  final List<String> joinedRooms = <String>[];

  @override
  Future<MamPage> requestHistory({
    required String roomJid,
    int max = 30,
    String? beforeId,
    String? afterId,
    String? start,
    String? end,
    bool deliver = true,
  }) async =>
      const MamPage(complete: true);

  @override
  Future<void> sendText({
    required String roomJid,
    required String messageId,
    required String text,
    bool isReply = false,
    bool showInChannel = false,
    String mainMessage = '',
    String langSource = 'en',
  }) async {
    sentTextIds.add(messageId);
    sentTexts.add(<String, Object?>{
      'roomJid': roomJid,
      'messageId': messageId,
      'text': text,
      'isReply': isReply,
      'showInChannel': showInChannel,
      'mainMessage': mainMessage,
      'langSource': langSource,
    });
  }

  final List<Map<String, Object?>> sentTexts = <Map<String, Object?>>[];
  final List<(String, String, List<String>)> sentReactions =
      <(String, String, List<String>)>[];
  final List<(String, String, String)> sentEdits = <(String, String, String)>[];
  final List<(String, String)> sentDeletes = <(String, String)>[];
  final List<(String, String)> sentReceipts = <(String, String)>[];
  final List<(String, String)> sentMarkers = <(String, String)>[];

  @override
  Future<void> sendReaction({
    required String roomJid,
    required String messageId,
    required List<String> reactions,
  }) async {
    sentReactions.add((roomJid, messageId, reactions));
  }

  @override
  Future<void> sendEdit({
    required String roomJid,
    required String messageId,
    required String text,
  }) async {
    sentEdits.add((roomJid, messageId, text));
  }

  @override
  Future<void> sendDelete({
    required String roomJid,
    required String messageId,
  }) async {
    sentDeletes.add((roomJid, messageId));
  }

  @override
  void sendReceivedReceipt({
    required String roomJid,
    required String messageId,
  }) {
    sentReceipts.add((roomJid, messageId));
  }

  @override
  void sendDisplayedMarker({
    required String roomJid,
    required String messageId,
  }) {
    sentMarkers.add((roomJid, messageId));
  }

  void emitReaction(ParsedReaction reaction) => onReaction?.call(reaction);
  void emitReceipt(ParsedReceipt receipt) => onReceipt?.call(receipt);
  void emitDisplayed(ParsedDisplayed marker) => onDisplayed?.call(marker);
  void emitEdit(ParsedEdit edit) => onEdit?.call(edit);
  void emitDelete(ParsedDelete delete) => onDelete?.call(delete);

  @override
  Future<Map<String, int>> getChatsPrivateStore() async => <String, int>{};

  @override
  Future<void> setTimestampToPrivateStore({
    required String chatId,
    required int timestamp,
  }) async {}

  void reconnect() => onReconnected?.call();

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
