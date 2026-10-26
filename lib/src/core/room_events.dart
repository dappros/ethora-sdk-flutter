import 'dart:async';

import '../models/chat_room.dart';
import '../networking/stanza_parser.dart';

// Server push and membership logic of rooms (web `networking/ethoraEvents.ts`,
// `onRoomMembershipChange`, `roomUserCount.ts`). Pure: the controller wires it
// to the REST API and to the room list.

const String kEthoraEventUserProfile = 'user-profile-updated';
const String kEthoraEventChatMeta = 'chat-meta-updated';

/// Several events for one room inside this window cause one refresh.
const Duration kRoomRefreshDebounce = Duration(milliseconds: 500);

/// Pause after the 1st, 2nd and 3rd (and later) failed refresh of a room.
const List<Duration> kRoomRefreshBackoff = <Duration>[
  Duration(seconds: 5),
  Duration(seconds: 30),
  Duration(seconds: 120),
];

/// Web `isTrustedEventSender` including `config.trustedEventSenders`: the
/// sender is a bare JID on the session's own domain, and when [pinned] is
/// non-empty it must be listed (full JID or localpart).
bool isTrustedEthoraSender(
  String from,
  String ownDomain, {
  List<String>? pinned,
}) {
  if (!isTrustedEventSender(from, ownDomain)) return false;
  if (pinned == null || pinned.isEmpty) return true;
  final value = from.trim().toLowerCase();
  final at = value.indexOf('@');
  final local = value.substring(0, at);
  return pinned.any((entry) {
    final e = entry.trim().toLowerCase();
    return e == value || e == local;
  });
}

/// Routes `ethora-event` headlines to the two refresh actions.
///
/// The payload is a pointer only: nothing in the stanza is ever shown or
/// stored. Unknown types, malformed attributes and untrusted senders are
/// ignored. Room refreshes are debounced per room, never overlap, and back
/// off after a failure (5 s, 30 s, then 120 s) so a broken endpoint is not
/// hammered.
class EthoraEventRouter {
  EthoraEventRouter({
    required this.holdsRoom,
    required this.refreshRoom,
    required this.refreshUser,
    DateTime Function()? now,
    this.debounce = kRoomRefreshDebounce,
    this.backoff = kRoomRefreshBackoff,
  }) : _now = now ?? DateTime.now;

  /// True when the room (by chat name, the JID localpart) is in the list.
  final bool Function(String chatName) holdsRoom;

  /// Re-reads a room through the API. A throw counts as a failure.
  final Future<void> Function(String chatName) refreshRoom;

  /// Re-reads a user profile. Errors are the callee's to swallow.
  final void Function(String xmppUsername) refreshUser;
  final DateTime Function() _now;
  final Duration debounce;
  final List<Duration> backoff;

  final Map<String, Timer> _timers = <String, Timer>{};
  final Set<String> _inflight = <String>{};
  final Set<String> _again = <String>{};
  final Map<String, _Failure> _failures = <String, _Failure>{};
  bool _disposed = false;

  /// Handles one event. Returns true when it was acted on or scheduled.
  bool handle(
    ParsedEthoraEvent event, {
    required String ownDomain,
    required String appId,
    List<String>? trustedSenders,
  }) {
    if (_disposed) return false;
    if (!isTrustedEthoraSender(
      event.from,
      ownDomain,
      pinned: trustedSenders,
    )) {
      return false;
    }
    final attrApp = event.attributes['appId'];
    if (attrApp != null && appId.isNotEmpty && attrApp != appId) return false;

    switch (event.type) {
      case kEthoraEventUserProfile:
        final id = event.attributes['xmppUsername'];
        if (isSafeEventKey(id, appId: appId)) {
          refreshUser(id!);
          return true;
        }
      case kEthoraEventChatMeta:
        final chatName = event.attributes['chatName'];
        // A room we do not hold (a brand-new room we were just added to) is
        // the invite and membership flow's job.
        if (isSafeEventKey(chatName, appId: appId) && holdsRoom(chatName!)) {
          scheduleRoomRefresh(chatName);
          return true;
        }
    }
    return false;
  }

  void scheduleRoomRefresh(String chatName) {
    if (_disposed) return;
    _timers.remove(chatName)?.cancel();
    _timers[chatName] = Timer(debounce, () {
      _timers.remove(chatName);
      unawaited(_run(chatName));
    });
  }

  Future<void> _run(String chatName) async {
    if (_disposed) return;
    if (_inflight.contains(chatName)) {
      _again.add(chatName);
      return;
    }
    final failure = _failures[chatName];
    if (failure != null && failure.until.isAfter(_now())) return;
    if (!holdsRoom(chatName)) return;

    _inflight.add(chatName);
    try {
      await refreshRoom(chatName);
      _failures.remove(chatName);
    } catch (_) {
      final count = (_failures[chatName]?.count ?? 0) + 1;
      final step = count - 1 < backoff.length ? count - 1 : backoff.length - 1;
      _failures[chatName] = _Failure(count, _now().add(backoff[step]));
    } finally {
      _inflight.remove(chatName);
      if (_again.remove(chatName)) scheduleRoomRefresh(chatName);
    }
  }

  /// Seconds-level state for tests: failures counted for [chatName].
  int failureCount(String chatName) => _failures[chatName]?.count ?? 0;

  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _inflight.clear();
    _again.clear();
    _failures.clear();
  }
}

class _Failure {
  const _Failure(this.count, this.until);
  final int count;
  final DateTime until;
}

/// My role in a room from the affiliation on my own MUC presence: owners and
/// admins moderate, members take part, anything else is unknown (empty).
String roleFromAffiliation(String affiliation) {
  switch (affiliation) {
    case 'owner':
    case 'admin':
      return 'moderator';
    case 'member':
      return 'participant';
    default:
      return '';
  }
}

/// True when the room is known to have more users than members loaded.
bool isRoomMembersTruncated(ChatRoom room) =>
    room.usersCnt > room.members.length;

/// Next usersCnt after a live join (+1) or leave (-1). Adjusts the CURRENT
/// count instead of recomputing from the (possibly truncated) members list.
int adjustUsersCnt(ChatRoom room, int delta, int nextMembersLength) {
  final current = room.displayUserCount;
  final next = current + delta;
  var result = nextMembersLength > next ? nextMembersLength : next;
  if (result < 0) result = 0;
  return result;
}

/// The room after a server membership message, or the same instance when
/// nothing changes. Only these messages adjust the count: a presence alone
/// never counts as a join.
ChatRoom applyMembershipChange(ChatRoom room, ParsedMembership change) {
  final username = change.xmppUsername;
  if (username.isEmpty) return room;
  final index = room.members.indexWhere((m) => m.xmppUsername == username);
  final leaving =
      change.affiliation == 'none' || change.affiliation == 'outcast';

  if (leaving) {
    if (index < 0) {
      // Truncated members: the leaver may exist only in the directory.
      if (!isRoomMembersTruncated(room)) return room;
      return room.copyWith(
        usersCnt: adjustUsersCnt(room, -1, room.members.length),
      );
    }
    final next = <ChatRoomMember>[
      for (var i = 0; i < room.members.length; i += 1)
        if (i != index) room.members[i],
    ];
    return room.copyWith(
      members: next,
      usersCnt: adjustUsersCnt(room, -1, next.length),
    );
  }

  if (index >= 0) return room;
  final next = <ChatRoomMember>[
    ...room.members,
    ChatRoomMember(xmppUsername: username),
  ];
  return room.copyWith(
    members: next,
    usersCnt: adjustUsersCnt(room, 1, next.length),
  );
}

/// Sentinels the backend falls back to when peer profile data is missing; they
/// are never shown as a chat title.
const Set<String> _badTitles = <String>{
  '',
  'deleted',
  'deleted user',
  'unknown',
  'null',
};

/// Title for a room from an API answer. A private chat whose title is a
/// sentinel is named after the other member (web `derivePrivateTitle`).
String? roomTitleFromApi(Map<String, dynamic> api, {String myLocal = ''}) {
  final title = (api['title']?.toString() ?? '').trim();
  final type = api['type']?.toString();
  if (type != 'private') return title.isEmpty ? null : title;
  if (!_badTitles.contains(title.toLowerCase())) return title;

  final members = api['members'];
  if (members is List) {
    for (final raw in members.whereType<Map>()) {
      final member = ChatRoomMember.fromApi(Map<String, dynamic>.from(raw));
      final local = localPart(member.xmppUsername).toLowerCase();
      if (local.isEmpty || local == myLocal.toLowerCase()) continue;
      final name = '${member.firstName} ${member.lastName}'.trim();
      if (name.isNotEmpty) return name;
    }
  }
  return title.isEmpty ? null : title;
}

/// [current] with the metadata of a `GET /v1/chats/my/{chatName}` answer.
/// Members and messages stay as they are (the answer carries the whole member
/// list and the loaded one may be a different, larger set). `usersCnt` is
/// never lowered. A missing field in the answer never blanks the one we have.
ChatRoom applyChatMeta(
  ChatRoom current,
  Map<String, dynamic> api, {
  String myLocal = '',
}) {
  String? text(String key) {
    final value = api[key];
    return value is String ? value : null;
  }

  final fresh = ChatRoom.fromApi(<String, dynamic>{
    ...api,
    'jid': current.jid,
  });
  final type = api['type']?.toString();
  return current.copyWith(
    title: roomTitleFromApi(api, myLocal: myLocal),
    description: text('description'),
    picture: text('picture'),
    usersCnt: fresh.usersCnt > current.displayUserCount
        ? fresh.usersCnt
        : current.displayUserCount,
    type:
        type == 'public' || type == 'group' || type == 'private' ? type : null,
  );
}
