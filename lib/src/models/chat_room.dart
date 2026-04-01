class ChatRoom {
  const ChatRoom({
    required this.jid,
    this.title,
    this.unreadCount = 0,
    this.pendingMessages = 0,
    this.composingList = const <String>[],
  });

  final String jid;
  final String? title;
  final int unreadCount;
  final int pendingMessages;
  final List<String> composingList;

  ChatRoom copyWith({
    String? jid,
    String? title,
    int? unreadCount,
    int? pendingMessages,
    List<String>? composingList,
  }) {
    return ChatRoom(
      jid: jid ?? this.jid,
      title: title ?? this.title,
      unreadCount: unreadCount ?? this.unreadCount,
      pendingMessages: pendingMessages ?? this.pendingMessages,
      composingList: composingList ?? this.composingList,
    );
  }

  factory ChatRoom.fromApi(Map<String, dynamic> room) {
    return ChatRoom(
      jid: room['jid']?.toString() ?? '',
      title: room['title']?.toString(),
      unreadCount: int.tryParse(room['unreadCount']?.toString() ?? '0') ?? 0,
    );
  }
}
