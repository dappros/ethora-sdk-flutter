enum ChatLogLevel { debug, info, warn, error }

enum ChatLogCategory { auth, api, xmpp, rooms, messages, refresh, system }

class ChatLogEvent {
  const ChatLogEvent({
    required this.level,
    required this.category,
    required this.message,
    required this.timestamp,
    this.data,
  });

  final ChatLogLevel level;
  final ChatLogCategory category;
  final String message;
  final DateTime timestamp;
  final Map<String, Object?>? data;
}
