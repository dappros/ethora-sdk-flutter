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
    );
  }

  factory ChatRoom.fromApi(Map<String, dynamic> room) {
    return ChatRoom(
      jid: room['jid']?.toString() ?? '',
      title: room['title']?.toString(),
      unreadCount: int.tryParse(room['unreadCount']?.toString() ?? '0') ?? 0,
      unreadCapped: room['unreadCapped'] == true,
      lastViewedTimestamp:
          int.tryParse(room['lastViewedTimestamp']?.toString() ?? '0') ?? 0,
      historyPreloadState: room['historyPreloadState']?.toString() ?? 'idle',
      historyComplete: room['historyComplete'] == true,
    );
  }
}
