import '../models/chat_message.dart';
import '../models/chat_room.dart';
import '../models/chat_user.dart';

class UnreadResult {
  const UnreadResult({required this.unread, required this.unreadCapped});

  final int unread;
  final bool unreadCapped;
}

class UnreadService {
  const UnreadService();

  UnreadResult computeUnreadForRoom({
    required ChatRoom room,
    required List<ChatMessage> messages,
    required String? activeRoomJid,
    required ChatUser? currentUser,
  }) {
    if (room.jid == activeRoomJid) {
      return const UnreadResult(unread: 0, unreadCapped: false);
    }

    final myLocal = _toLocal(currentUser?.xmppUsername ?? '');
    final lastViewed = room.lastViewedTimestamp;
    final countable = <ChatMessage>[];

    for (final msg in messages) {
      if (!_isCountable(msg)) continue;
      final msgSender = _toLocal(msg.user.xmppUsername ?? msg.user.id ?? '');
      if (myLocal.isNotEmpty && msgSender == myLocal) continue;
      final ts = _timestamp(msg);
      if (ts <= 0) continue;
      if (lastViewed <= 0 || ts > lastViewed) {
        countable.add(msg);
      }
    }

    var unreadCapped = false;
    if (room.historyPreloadState == 'done' &&
        room.historyComplete != true &&
        countable.length >= 10) {
      final oldest = countable
          .map(_timestamp)
          .where((e) => e > 0)
          .fold<int>(1 << 62, (a, b) => b < a ? b : a);
      if (lastViewed <= 0 || oldest > lastViewed) {
        unreadCapped = true;
      }
    }

    return UnreadResult(unread: countable.length, unreadCapped: unreadCapped);
  }

  List<ChatMessage> normalizeDelimiterPosition(
    List<ChatMessage> messages,
    int lastViewedTimestamp,
    String roomJid,
  ) {
    final list = messages.where((m) => m.id != 'delimiter-new').toList();
    if (lastViewedTimestamp <= 0 || list.isEmpty) {
      return list;
    }

    final firstUnreadIndex = list.indexWhere((msg) {
      if (!_isCountable(msg)) return false;
      return _timestamp(msg) > lastViewedTimestamp;
    });

    if (firstUnreadIndex == -1) {
      return list;
    }

    list.insert(
      firstUnreadIndex,
      ChatMessage(
        id: 'delimiter-new',
        roomJid: roomJid,
        text: 'New Messages',
        user: const ChatUser(id: 'system', username: 'system'),
        createdAtMs: lastViewedTimestamp,
        system: true,
      ),
    );
    return list;
  }

  bool _isCountable(ChatMessage msg) {
    return msg.id != 'delimiter-new' &&
        msg.pending != true &&
        msg.system != true &&
        msg.text.trim().isNotEmpty;
  }

  int _timestamp(ChatMessage msg) {
    if ((msg.timestamp ?? 0) > 0) {
      return msg.timestamp!;
    }
    if (msg.createdAtMs > 0) {
      return msg.createdAtMs;
    }
    return 0;
  }

  String _toLocal(String value) {
    if (value.isEmpty) return '';
    return value.split('@').first;
  }
}
