/// One member of a room as `GET /v1/chats/my` lists it (web `members[]`).
class ChatRoomMember {
  const ChatRoomMember({
    this.id = '',
    this.xmppUsername = '',
    this.firstName = '',
    this.lastName = '',
  });

  /// Mongo user id (`_id`), used by the search sender filter.
  final String id;
  final String xmppUsername;
  final String firstName;
  final String lastName;

  String get displayName {
    final name = '$firstName $lastName'.trim();
    return name.isEmpty ? xmppUsername : name;
  }

  factory ChatRoomMember.fromApi(Map<String, dynamic> member) {
    return ChatRoomMember(
      id: member['_id']?.toString() ?? '',
      xmppUsername: member['xmppUsername']?.toString() ?? '',
      firstName: member['firstName']?.toString() ?? '',
      lastName: member['lastName']?.toString() ?? '',
    );
  }
}

class ChatRoom {
  const ChatRoom({
    required this.jid,
    this.title,
    this.unreadCount = 0,
    this.unreadCapped = false,
    this.pendingMessages = 0,
    this.composingList = const <String>[],
    this.lastViewedTimestamp = 0,
    this.historyPreloadState = 'idle',
    this.historyComplete = false,
    this.lastDisplayedByUser = const <String, String>{},
    this.usersCnt = 0,
    this.members = const <ChatRoomMember>[],
    this.muted = false,
    this.type,
    this.description,
    this.picture,
    this.e2ee = false,
    this.role = '',
  });

  final String jid;
  final String? title;
  final int unreadCount;
  final bool unreadCapped;
  final int pendingMessages;
  final List<String> composingList;
  final int lastViewedTimestamp;
  final String historyPreloadState;
  final bool historyComplete;

  /// XEP-0333 read watermark per user: xmpp username -> last displayed
  /// message id (room level, like web `room.lastDisplayedByUser`).
  final Map<String, String> lastDisplayedByUser;

  /// Total occupants (the true count, `members` can be a truncated page).
  final int usersCnt;
  final List<ChatRoomMember> members;

  /// Per-user mute preference (`muted` on `/chats/my`).
  final bool muted;

  /// `public`, `group` or `private` as the API reports it.
  final String? type;
  final String? description;
  final String? picture;
  final bool e2ee;

  /// My role in the room, from my own MUC presence: `moderator` (owner or
  /// admin), `participant` (member) or empty while unknown (web `room.role`).
  final String role;

  /// True when I may add and remove members and edit the room.
  bool get canManage => role == 'moderator';

  /// Count to display: never below the loaded member list (web
  /// getRoomUserCount).
  int get displayUserCount =>
      usersCnt > members.length ? usersCnt : members.length;

  ChatRoom copyWith({
    String? jid,
    String? title,
    int? unreadCount,
    bool? unreadCapped,
    int? pendingMessages,
    List<String>? composingList,
    int? lastViewedTimestamp,
    String? historyPreloadState,
    bool? historyComplete,
    Map<String, String>? lastDisplayedByUser,
    int? usersCnt,
    List<ChatRoomMember>? members,
    bool? muted,
    String? type,
    String? description,
    String? picture,
    bool? e2ee,
    String? role,
  }) {
    return ChatRoom(
      jid: jid ?? this.jid,
      title: title ?? this.title,
      unreadCount: unreadCount ?? this.unreadCount,
      unreadCapped: unreadCapped ?? this.unreadCapped,
      pendingMessages: pendingMessages ?? this.pendingMessages,
      composingList: composingList ?? this.composingList,
      lastViewedTimestamp: lastViewedTimestamp ?? this.lastViewedTimestamp,
      historyPreloadState: historyPreloadState ?? this.historyPreloadState,
      historyComplete: historyComplete ?? this.historyComplete,
      lastDisplayedByUser: lastDisplayedByUser ?? this.lastDisplayedByUser,
      usersCnt: usersCnt ?? this.usersCnt,
      members: members ?? this.members,
      muted: muted ?? this.muted,
      type: type ?? this.type,
      description: description ?? this.description,
      picture: picture ?? this.picture,
      e2ee: e2ee ?? this.e2ee,
      role: role ?? this.role,
    );
  }

  factory ChatRoom.fromApi(Map<String, dynamic> room) {
    final rawMembers = room['members'];
    return ChatRoom(
      jid: room['jid']?.toString() ?? '',
      title: room['title']?.toString(),
      unreadCount: int.tryParse(room['unreadCount']?.toString() ?? '0') ?? 0,
      unreadCapped: room['unreadCapped'] == true,
      lastViewedTimestamp:
          int.tryParse(room['lastViewedTimestamp']?.toString() ?? '0') ?? 0,
      historyPreloadState: room['historyPreloadState']?.toString() ?? 'idle',
      historyComplete: room['historyComplete'] == true,
      usersCnt: int.tryParse(room['usersCnt']?.toString() ?? '0') ?? 0,
      members: rawMembers is List
          ? rawMembers
              .whereType<Map<String, dynamic>>()
              .map(ChatRoomMember.fromApi)
              .toList()
          : const <ChatRoomMember>[],
      muted: room['muted'] == true,
      type: room['type']?.toString(),
      description: room['description']?.toString(),
      picture: room['picture']?.toString(),
      e2ee: room['e2ee'] == true,
      role: room['role']?.toString() ?? '',
    );
  }
}
