import '../core/chat_component_log.dart';
import '../core/room_events.dart';
import '../models/chat_component_config.dart';
import '../models/chat_room.dart';
import 'api_client.dart';

/// REST calls that change or describe a room (web `rooms.api.ts`,
/// `roomMembers.api.ts`, `publicChats.api.ts`).
class RoomActionsService {
  RoomActionsService({
    required this.apiClient,
    required this.config,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ApiClient apiClient;
  final ChatComponentConfig config;
  final void Function(ChatLogEvent event)? log;
  final DateTime Function() _now;

  String _enc(String value) => Uri.encodeComponent(value);

  /// `PUT` (mute, body `{}`) or `DELETE` (unmute) `/v1/chats/my/{chatName}/mute`.
  /// Returns the server's `muted` value, or [muted] when the answer omits it.
  Future<bool> setMuted(String chatName, bool muted) async {
    final path = '/v1/chats/my/${_enc(chatName)}/mute';
    final body = muted
        ? await apiClient.put(path, body: const <String, dynamic>{})
        : await apiClient.delete(path);
    final result = body['result'];
    if (result is Map && result['muted'] is bool) {
      return result['muted'] as bool;
    }
    return muted;
  }

  /// `POST /v1/chats/reports/{chatName}`.
  Future<void> reportRoom(
    String chatName, {
    required String category,
    required String text,
  }) async {
    await apiClient.post(
      '/v1/chats/reports/${_enc(chatName)}',
      body: buildReportBody(category, text),
    );
  }

  /// `DELETE /v1/chats/users-access` for the signed-in user. A 404 means the
  /// membership is already gone and counts as success; any other failure
  /// rethrows so the chat stays in the list.
  Future<void> leaveRoom(String chatName, String myXmppUsername) async {
    try {
      await removeMembers(chatName, <String>[myXmppUsername]);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return;
      rethrow;
    }
  }

  /// `POST /v1/chats/users-access`. Returns the per-member `results`.
  Future<List<Map<String, dynamic>>> addMembers(
    String chatName,
    List<String> members,
  ) async {
    final body = await apiClient.post(
      '/v1/chats/users-access',
      body: <String, dynamic>{'chatName': chatName, 'members': members},
    );
    final results = body['results'];
    return results is List
        ? results.whereType<Map<String, dynamic>>().toList()
        : const <Map<String, dynamic>>[];
  }

  /// `DELETE /v1/chats/users-access`.
  Future<void> removeMembers(String chatName, List<String> members) async {
    await apiClient.delete(
      '/v1/chats/users-access',
      body: <String, dynamic>{'chatName': chatName, 'members': members},
    );
  }

  /// `DELETE /v1/chats {name}`.
  Future<void> deleteRoom(String chatName) async {
    await apiClient.delete(
      '/v1/chats',
      body: <String, dynamic>{'name': chatName},
    );
  }

  /// `POST /v1/chats/private`. `e2ee` is sent only when true: the backend
  /// validates the payload with a schema that rejects unknown keys, so
  /// `e2ee: false` would break backends that predate the field.
  Future<Map<String, dynamic>> createPrivateRoom(
    String username, {
    bool e2ee = false,
  }) async {
    final body = await apiClient.post(
      '/v1/chats/private',
      body: <String, dynamic>{'username': username, if (e2ee) 'e2ee': true},
    );
    return _result(body);
  }

  /// `POST /v1/chats`: a new group or public chat.
  Future<Map<String, dynamic>> createRoom({
    required String title,
    String description = '',
    String picture = '',
    String type = 'group',
    List<String> members = const <String>[],
  }) async {
    final body = await apiClient.post(
      '/v1/chats',
      body: <String, dynamic>{
        'title': title,
        'description': description,
        'picture': picture,
        'type': type,
        'members': members,
      },
    );
    return _result(body);
  }

  /// `PATCH /v1/chats/my/{chatName}`: the room's own title, description or
  /// picture. Send an empty string to clear one (web `patchMyChat`).
  Future<void> patchRoom(
    String chatName, {
    String? title,
    String? description,
    String? picture,
  }) async {
    await apiClient.patch(
      '/v1/chats/my/${_enc(chatName)}',
      body: <String, dynamic>{
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (picture != null) 'picture': picture,
      },
    );
  }

  /// `GET /v1/chats/my/{chatName}`: one room, fresh.
  Future<Map<String, dynamic>> roomByName(String chatName) async {
    final body = await apiClient.get('/v1/chats/my/${_enc(chatName)}');
    return body;
  }

  /// `GET /v1/chats/public`. The endpoint rejects a limit above 50. Reported
  /// chats are not advertised in a directory.
  Future<PublicChatsPage> publicChats({
    int offset = 0,
    int limit = kPublicChatsPageSize,
  }) async {
    final body = await apiClient.get(
      '/v1/chats/public',
      query: <String, String>{
        'limit':
            '${limit > kPublicChatsPageSize ? kPublicChatsPageSize : limit}',
        'offset': '$offset',
      },
    );
    return parsePublicChatsPage(body, offset: offset, limit: limit);
  }

  Map<String, dynamic> _result(Map<String, dynamic> body) {
    final result = body['result'];
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('room_result_missing');
  }

  // --- single user lookup with a route fallback chain -----------------------
  //
  //   1. GET /v1/apps/users/<xmppUsername>      the intended route; a user
  //      token may be refused (400, 401) or the route may be missing.
  //   2. GET /v2/chats/users?xmppUsername=<id>  works with a user token, and
  //      also returns email and tags: only display fields are ever kept.
  //
  // A refusal of the v1 route is remembered for [kUserRouteTtl] and v2 is used
  // meanwhile; v1 is probed again after that. A 403 on v1 is a per-user answer
  // (the shared-room rule): the route stays supported and v2 is NOT consulted
  // (it would leak what v1 refused).

  DateTime? _v1UnsupportedUntil;

  /// True while the v1 user route is remembered as refused.
  bool get isUserV1RouteUnsupported =>
      _v1UnsupportedUntil != null && _v1UnsupportedUntil!.isAfter(_now());

  /// One user by `appId_userId`. Never throws.
  Future<UserLookupResult> lookupUser(String xmppUsername) async {
    final id = xmppUsername.trim();
    if (id.isEmpty || id == 'undefined') {
      return const UserLookupResult(UserLookupStatus.notFound);
    }
    if (isUserV1RouteUnsupported) return _callV2(id);
    final v1 = await _callV1(id);
    if (v1.routeUnsupported) {
      _v1UnsupportedUntil = _now().add(kUserRouteTtl);
      return _callV2(id);
    }
    return v1.result;
  }

  Future<({UserLookupResult result, bool routeUnsupported})> _callV1(
    String id,
  ) async {
    try {
      final body = await apiClient.get(
        '/v1/apps/users/${_enc(id)}',
        // A 401 here means the route does not take this token, not that the
        // session is bad: fall back to v2 without rotating tokens.
        refreshOn401: false,
      );
      final user = pickUserProfile(body);
      return (
        result: user == null
            ? const UserLookupResult(UserLookupStatus.error)
            : UserLookupResult(UserLookupStatus.ok, user: user),
        routeUnsupported: false,
      );
    } on ApiException catch (e) {
      final notFound = isUserNotFoundBody(e.body);
      if (e.statusCode == 404) {
        // A 404 without USER_NOT_FOUND is a route that is not there.
        return (
          result: const UserLookupResult(UserLookupStatus.notFound),
          routeUnsupported: !notFound,
        );
      }
      if (e.statusCode == 403) {
        return (
          result: const UserLookupResult(UserLookupStatus.forbidden),
          routeUnsupported: false,
        );
      }
      if (e.statusCode == 400 || e.statusCode == 401) {
        return (
          result: const UserLookupResult(UserLookupStatus.error),
          routeUnsupported: true,
        );
      }
      return (
        result: const UserLookupResult(UserLookupStatus.error),
        routeUnsupported: false,
      );
    } catch (_) {
      return (
        result: const UserLookupResult(UserLookupStatus.error),
        routeUnsupported: false,
      );
    }
  }

  Future<UserLookupResult> _callV2(String id) async {
    try {
      final body = await apiClient.get(
        '/v2/chats/users',
        query: <String, String>{'xmppUsername': id},
      );
      final user = pickUserProfile(body);
      return user == null
          ? const UserLookupResult(UserLookupStatus.error)
          : UserLookupResult(UserLookupStatus.ok, user: user);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        return const UserLookupResult(UserLookupStatus.notFound);
      }
      if (e.statusCode == 403) {
        return const UserLookupResult(UserLookupStatus.forbidden);
      }
      return const UserLookupResult(UserLookupStatus.error);
    } catch (_) {
      return const UserLookupResult(UserLookupStatus.error);
    }
  }
}

/// Body of `POST /v1/chats/reports/{chatName}` as the backend validates it:
/// `category` is one of `spam`, `violance` (sic), `pornography`,
/// `personal details`, `illegal drugs`, `other`, and `text` is required and
/// non-empty. The picker's English ids map onto those. "Child Abuse" has no
/// backend value, so it goes as `other` with the reason leading the text. A
/// blank text falls back to the reason, so the report is never rejected for
/// being empty.
///
/// The web SDK sends the picker ids as they are and the full room JID in the
/// path, which this backend answers with 422 and 403; the backend is what
/// counts.
Map<String, dynamic> buildReportBody(String category, String text) {
  const direct = <String, String>{
    'spam': 'spam',
    'violence': 'violance',
    'violance': 'violance',
    'pornography': 'pornography',
    'personal details': 'personal details',
    'illegal drugs': 'illegal drugs',
    'other': 'other',
  };
  final key = category.trim().toLowerCase();
  final details = text.trim();
  var wire = direct[key];
  var reason = category.trim();
  if (wire == null) {
    wire = 'other';
    if (reason.isEmpty) reason = 'Other';
  }
  final body = wire == 'other' && key != 'other' && key.isNotEmpty
      ? (details.isEmpty ? reason : '$reason: $details')
      : (details.isEmpty ? reason : details);
  return <String, dynamic>{
    'category': wire,
    'text': body.isEmpty ? 'Other' : body,
  };
}

/// How long a refused v1 user route is remembered.
const Duration kUserRouteTtl = Duration(minutes: 10);

/// The directory endpoint rejects a limit above 50.
const int kPublicChatsPageSize = 50;

enum UserLookupStatus { ok, notFound, forbidden, error }

class UserLookupResult {
  const UserLookupResult(this.status, {this.user});

  final UserLookupStatus status;
  final UserProfile? user;
}

/// The display fields of a user. Email, tags and the rest are never kept.
class UserProfile {
  const UserProfile({
    this.id = '',
    this.xmppUsername = '',
    this.firstName = '',
    this.lastName = '',
    this.profileImage = '',
  });

  final String id;
  final String xmppUsername;
  final String firstName;
  final String lastName;
  final String profileImage;

  String get displayName {
    final name = '$firstName $lastName'.trim();
    return name.isEmpty ? xmppUsername : name;
  }
}

bool isUserNotFoundBody(String body) {
  return RegExp('USER_NOT_FOUND', caseSensitive: false).hasMatch(body) ||
      RegExp(r'user[^a-z]{0,3}not[^a-z]{0,3}found', caseSensitive: false)
          .hasMatch(body);
}

/// The user object of a lookup answer, whichever envelope the backend used
/// (`result`, `item`, `data`, a one element list, or the user itself).
UserProfile? pickUserProfile(Map<String, dynamic> data) {
  Object? candidate = data['result'] ?? data['item'] ?? data['data'];
  if (candidate is List) candidate = candidate.isEmpty ? null : candidate.first;
  if (candidate == null &&
      (data['xmppUsername'] != null ||
          data['firstName'] != null ||
          data['lastName'] != null)) {
    candidate = data;
  }
  if (candidate is Map &&
      (candidate['result'] != null || candidate['item'] != null) &&
      candidate['xmppUsername'] == null) {
    candidate = candidate['result'] ?? candidate['item'];
  }
  if (candidate is! Map) return null;
  final fields = candidate;
  String s(String key) {
    final value = fields[key];
    return value is String
        ? value
        : (key == '_id' && value != null ? '$value' : '');
  }

  final profile = UserProfile(
    id: s('_id'),
    xmppUsername: s('xmppUsername'),
    firstName: s('firstName'),
    lastName: s('lastName'),
    profileImage: s('profileImage'),
  );
  final empty = profile.id.isEmpty &&
      profile.xmppUsername.isEmpty &&
      profile.firstName.isEmpty &&
      profile.lastName.isEmpty &&
      profile.profileImage.isEmpty;
  return empty ? null : profile;
}

/// One entry of the public directory.
class PublicChat {
  const PublicChat({
    required this.name,
    this.title = '',
    this.description = '',
    this.picture = '',
    this.e2ee = false,
  });

  /// Room name, the local part of its JID.
  final String name;
  final String title;
  final String description;
  final String picture;
  final bool e2ee;

  String get displayTitle => title.isEmpty ? name : title;
}

class PublicChatsPage {
  const PublicChatsPage({
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
    required this.nextOffset,
  });

  final List<PublicChat> items;
  final int total;
  final int offset;
  final int limit;

  /// Server rows consumed so far, counting the hidden (reported) ones.
  final int nextOffset;

  bool get hasMore => nextOffset < total;
}

PublicChatsPage parsePublicChatsPage(
  Map<String, dynamic> data, {
  int offset = 0,
  int limit = kPublicChatsPageSize,
}) {
  final rawItems = data['items'];
  final raw = rawItems is List ? rawItems : const <dynamic>[];
  final items = <PublicChat>[];
  for (final entry in raw.whereType<Map>()) {
    final name = entry['name']?.toString() ?? '';
    if (name.isEmpty || entry['reported'] == true) continue;
    items.add(PublicChat(
      name: name,
      title: (entry['title']?.toString() ?? '').trim(),
      description: (entry['description']?.toString() ?? '').trim(),
      picture: entry['picture']?.toString() ?? '',
      e2ee: entry['e2ee'] == true,
    ));
  }
  int n(Object? value, int fallback) {
    final parsed = int.tryParse('${value ?? ''}');
    return parsed == null || parsed == 0 ? fallback : parsed;
  }

  return PublicChatsPage(
    items: items,
    total: int.tryParse('${data['total'] ?? ''}') ?? 0,
    offset: n(data['offset'], offset),
    limit: n(data['limit'], limit),
    nextOffset: offset + raw.length,
  );
}

/// A [ChatRoom] from a `/v1/chats` answer. The room JID is built from the
/// chat name and the conference host when the answer has no `jid`. A private
/// chat whose title is a sentinel is named after the other member.
ChatRoom chatRoomFromApi(
  Map<String, dynamic> api, {
  required String conference,
  String myLocal = '',
}) {
  final name = api['name']?.toString() ?? '';
  var jid = api['jid']?.toString() ?? '';
  if (jid.isEmpty && name.isNotEmpty) {
    jid = name.contains('@') ? name : '$name@$conference';
  }
  final room = ChatRoom.fromApi(<String, dynamic>{...api, 'jid': jid});
  final title = roomTitleFromApi(api, myLocal: myLocal);
  return title == null ? room : room.copyWith(title: title);
}
