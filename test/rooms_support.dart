import 'dart:convert';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

const kSupportSettings = XmppSettings(
  xmppServerUrl: 'wss://xmpp.test/ws',
  host: 'xmpp.test',
  conference: 'conference.xmpp.test',
);

const kMe = ChatUser(
  id: 'u1',
  username: 'tester',
  token: 'token',
  refreshToken: 'refresh',
  xmppUsername: 'app_me',
  xmppPassword: 'pass',
);

/// archive id for the n-th message of a room.
int archiveId(int n) => 1700000000000000 + n * 1000000;

ChatMessage archiveMessage(
  String roomJid,
  int n, {
  String? text,
  bool isReply = false,
  String? mainMessage,
  String sender = 'bob',
}) {
  return ChatMessage(
    id: '${archiveId(n)}',
    roomJid: roomJid,
    text: text ?? 'message $n',
    user: ChatUser(xmppUsername: sender),
    createdAtMs: 1700000000000 + n * 1000,
    isReply: isReply,
    showInChannel: !isReply,
    mainMessage: mainMessage,
    isHistory: true,
  );
}

/// A server archive for one room with the MAM paging semantics.
class FakeArchive {
  FakeArchive(this.roomJid, this.rows);

  final String roomJid;
  final List<ChatMessage> rows;
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  /// Fails every silent (window) query.
  bool failWindows = false;

  MamPage answer({
    required int max,
    String? beforeId,
    String? afterId,
    String? start,
    String? end,
    required bool deliver,
  }) {
    calls.add(<String, Object?>{
      'max': max,
      'before': beforeId,
      'after': afterId,
      'start': start,
      'end': end,
      'deliver': deliver,
    });
    if (!deliver && failWindows) return const MamPage(error: true);
    var pool = rows;
    if (start != null || end != null) {
      final s =
          start == null ? 0 : DateTime.parse(start).millisecondsSinceEpoch;
      final e =
          end == null ? 1 << 62 : DateTime.parse(end).millisecondsSinceEpoch;
      pool =
          pool.where((m) => m.createdAtMs >= s && m.createdAtMs <= e).toList();
    }
    int idOf(ChatMessage m) => int.parse(m.id);
    List<ChatMessage> page;
    bool complete;
    if (afterId != null) {
      final rest = pool.where((m) => idOf(m) > int.parse(afterId)).toList();
      page = rest.take(max).toList();
      complete = page.length == rest.length;
    } else if (beforeId != null) {
      final rest = pool.where((m) => idOf(m) < int.parse(beforeId)).toList();
      page = rest.length > max ? rest.sublist(rest.length - max) : rest;
      complete = page.length == rest.length;
    } else if (start != null || end != null) {
      page = pool.take(max).toList();
      complete = page.length == pool.length;
    } else {
      page = pool.length > max ? pool.sublist(pool.length - max) : pool;
      complete = page.length == pool.length;
    }
    return MamPage(
      complete: complete,
      first: page.isEmpty ? null : page.first.id,
      last: page.isEmpty ? null : page.last.id,
      count: page.length,
      messages: page,
    );
  }
}

/// An XMPP client with no socket: answers MAM from [archives] and records
/// what the controller sends.
class ScriptedXmpp extends XmppClient {
  ScriptedXmpp() : super(settings: kSupportSettings, user: kMe, log: (_) {});

  final Map<String, FakeArchive> archives = <String, FakeArchive>{};
  final List<String> presences = <String>[];
  final List<String> leaves = <String>[];
  final List<(String, String)> invites = <(String, String)>[];
  final List<(String, String)> images = <(String, String)>[];
  final List<(String, String)> deletes = <(String, String)>[];

  @override
  ChatConnectionState get state => ChatConnectionState.online;

  @override
  Future<void> connect() async {
    onConnectionChanged?.call(ChatConnectionState.online);
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendRoomPresence(String roomJid) async {
    presences.add(roomJid);
  }

  @override
  Future<void> sendPresenceToRooms(List<String> roomJids) async {
    presences.addAll(roomJids);
  }

  @override
  void sendRoomLeave(String roomJid) => leaves.add(roomJid);

  @override
  void sendRoomInvite({required String roomJid, required String username}) {
    invites.add((roomJid, username));
  }

  @override
  void sendRoomImage({
    required String roomJid,
    required String thumbnail,
    String background = 'none',
  }) {
    images.add((roomJid, thumbnail));
  }

  @override
  Future<void> sendDelete({
    required String roomJid,
    required String messageId,
  }) async {
    deletes.add((roomJid, messageId));
  }

  @override
  Future<Map<String, int>> getChatsPrivateStore() async => <String, int>{};

  @override
  Future<void> setTimestampToPrivateStore({
    required String chatId,
    required int timestamp,
  }) async {}

  @override
  Future<MamPage> requestHistory({
    required String roomJid,
    int max = 30,
    String? beforeId,
    String? afterId,
    String? start,
    String? end,
    bool deliver = true,
  }) async {
    final archive = archives[roomJid];
    if (archive == null) return const MamPage(complete: true);
    final page = archive.answer(
      max: max,
      beforeId: beforeId,
      afterId: afterId,
      start: start,
      end: end,
      deliver: deliver,
    );
    if (deliver) {
      for (final message in page.messages) {
        onMessage?.call(message);
      }
    }
    return page;
  }
}

Object? _decode(String body) {
  if (body.isEmpty) return null;
  try {
    return jsonDecode(body);
  } catch (_) {
    return body; // a multipart upload
  }
}

class RecordedRequest {
  RecordedRequest(this.method, this.url, this.body);

  final String method;
  final Uri url;
  final Object? body;

  String get path => url.path;
  Map<String, dynamic> get json => body is Map<String, dynamic>
      ? body! as Map<String, dynamic>
      : <String, dynamic>{};

  @override
  String toString() => '$method $url $body';
}

typedef ApiHandler = http.Response? Function(RecordedRequest request);

/// A controller on a [ScriptedXmpp] with the REST API answered by [handler].
class RoomsHarness {
  RoomsHarness({
    ChatComponentConfig? config,
    List<ChatRoom> rooms = const <ChatRoom>[],
    this.handler,
  }) {
    final cfg = config ??
        const ChatComponentConfig(
          appId: 'app',
          baseUrl: 'https://api.test',
          xmppSettings: kSupportSettings,
        );
    mockClient = MockClient((request) async {
      final recorded = RecordedRequest(
        request.method,
        request.url,
        _decode(request.body),
      );
      requests.add(recorded);
      final response = handler?.call(recorded);
      return response ?? http.Response('{}', 200);
    });
    final api = ApiClient(
      config: cfg,
      readAccessToken: () async => 'token',
      readRefreshToken: () async => null,
      writeTokens: (_, __) async {},
      clearSession: () async {},
      log: (_) {},
      httpClient: mockClient,
    );
    xmpp = ScriptedXmpp();
    store = InMemoryStore()..user = kMe;
    controller = ChatComponentController(
      config: cfg,
      store: store,
      apiClient: api,
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(rooms: rooms),
      xmppClientFactory: ({required settings, required user, required log}) =>
          xmpp,
    );
  }

  late final MockClient mockClient;
  late final ScriptedXmpp xmpp;
  late final InMemoryStore store;
  late final ChatComponentController controller;
  final List<RecordedRequest> requests = <RecordedRequest>[];
  ApiHandler? handler;

  Future<void> start() => controller.initialize();

  List<RecordedRequest> where(String method, String pathPart) => requests
      .where((r) => r.method == method && r.path.contains(pathPart))
      .toList();

  void dispose() => controller.dispose();
}

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: <String, String>{'content-type': 'application/json'});
