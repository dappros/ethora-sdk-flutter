import '../models/chat_component_config.dart';
import 'api_client.dart';

/// The single rule for message search (web `isMessageSearchEnabled`). It is
/// opt-in: the host sets `enableMessageSearch` AND provides an `appId` (the
/// archive endpoint is scoped by app). `disableMessageSearch` still wins as a
/// hard off. Every entry point goes through this function.
bool isMessageSearchEnabled(ChatComponentConfig? config) {
  if (config == null) return false;
  return config.enableMessageSearch == true &&
      config.disableMessageSearch != true &&
      (config.appId ?? '').trim().isNotEmpty;
}

/// Rows asked for per page.
const int kMessageSearchPageSize = 20;

/// One match of `GET /v2/apps/{appId}/messages/search`.
class MessageSearchHit {
  const MessageSearchHit({
    required this.id,
    required this.chatId,
    required this.chatType,
    required this.room,
    required this.from,
    required this.fromUserId,
    required this.body,
    required this.messageId,
    required this.stanzaId,
    required this.createdAt,
  });

  /// The archive row's own id, the only identifier every hit is guaranteed
  /// to have.
  final String id;

  /// Room name, the local part of the room JID.
  final String chatId;
  final String chatType;

  /// Full room JID.
  final String room;

  /// Sender's full JID with the host: `appId_userId@xmpp.host`.
  final String from;
  final String fromUserId;
  final String body;
  final String messageId;
  final String stanzaId;

  /// ISO 8601 instant as the server sent it.
  final String createdAt;

  DateTime? get createdAtDate => DateTime.tryParse(createdAt);

  /// A key that is unique per hit. `stanzaId` and `messageId` are NOT: whole
  /// pages of older hits come back with both empty (web `hitKey`).
  String get key {
    if (id.isNotEmpty) return id;
    final head = body.length > 24 ? body.substring(0, 24) : body;
    return '$chatId:$stanzaId:$messageId:$createdAt:$head';
  }
}

class MessageSearchPage {
  const MessageSearchPage({
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
    required this.nextOffset,
  });

  final List<MessageSearchHit> items;

  /// Total matches on the server, not the size of this page.
  final int total;
  final int offset;
  final int limit;

  /// Where the next page starts, counted in SERVER rows: deleted messages
  /// are dropped from [items], and paging by the filtered count would
  /// re-request rows already seen.
  final int nextOffset;
}

/// Query string of the search call. Optional filters are left out when empty.
Map<String, String> buildMessageSearchQuery({
  required String q,
  String? chatId,
  String? fromUserId,
  String? since,
  String? until,
  int limit = kMessageSearchPageSize,
  int offset = 0,
}) {
  return <String, String>{
    'q': q,
    'limit': '$limit',
    'offset': '$offset',
    if (chatId != null && chatId.isNotEmpty) 'chatId': chatId,
    if (fromUserId != null && fromUserId.isNotEmpty) 'fromUserId': fromUserId,
    if (since != null && since.isNotEmpty) 'since': since,
    if (until != null && until.isNotEmpty) 'until': until,
  };
}

/// Parses a search answer. A deleted message stays in the archive with
/// `deletedAt` set, and showing it would let a search resurrect text the
/// author removed, so those (and empty bodies) are dropped from the items.
/// `nextOffset` still counts every raw row.
MessageSearchPage parseMessageSearchPage(
  Map<String, dynamic> data, {
  int offset = 0,
  int limit = kMessageSearchPageSize,
}) {
  final rawItems = data['items'];
  final raw = rawItems is List ? rawItems : const <dynamic>[];
  final items = <MessageSearchHit>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final deletedAt = entry['deletedAt'];
    if (deletedAt != null && '$deletedAt'.isNotEmpty) continue;
    final body = entry['body'];
    if (body is! String || body.isEmpty) continue;
    String s(String key) => entry[key]?.toString() ?? '';
    items.add(MessageSearchHit(
      id: s('_id'),
      chatId: s('chatId'),
      chatType: s('chatType'),
      room: s('room'),
      from: s('from'),
      fromUserId: s('fromUserId'),
      body: body,
      messageId: s('messageId'),
      stanzaId: s('stanzaId'),
      createdAt: s('createdAt'),
    ));
  }
  int n(Object? value, int fallback) {
    final parsed = int.tryParse('${value ?? ''}');
    return parsed == null || parsed == 0 ? fallback : parsed;
  }

  return MessageSearchPage(
    items: items,
    total: int.tryParse('${data['total'] ?? ''}') ?? 0,
    offset: n(data['offset'], offset),
    limit: n(data['limit'], limit),
    nextOffset: offset + raw.length,
  );
}

/// Full-text search over the chat archive. For a user token the server
/// restricts it to chats the caller can see.
class MessageSearchService {
  MessageSearchService({required this.apiClient, required this.config});

  final ApiClient apiClient;
  final ChatComponentConfig config;

  Future<MessageSearchPage> search({
    required String q,
    String? chatId,
    String? fromUserId,
    String? since,
    String? until,
    int limit = kMessageSearchPageSize,
    int offset = 0,
  }) async {
    final appId = (config.appId ?? '').trim();
    if (appId.isEmpty) throw StateError('message_search_no_app_id');
    final body = await apiClient.get(
      '/v2/apps/${Uri.encodeComponent(appId)}/messages/search',
      query: buildMessageSearchQuery(
        q: q,
        chatId: chatId,
        fromUserId: fromUserId,
        since: since,
        until: until,
        limit: limit,
        offset: offset,
      ),
    );
    return parseMessageSearchPage(body, offset: offset, limit: limit);
  }
}
