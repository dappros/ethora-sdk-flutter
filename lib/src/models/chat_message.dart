import 'chat_user.dart';

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.roomJid,
    required this.text,
    required this.user,
    required this.createdAtMs,
    this.pending = false,
    this.isMedia = false,
    this.mediaUrl,
    this.mimeType,
    this.xmppId,
    this.timestamp,
    this.system = false,
    this.showInChannel = true,
    this.isReply = false,
  });

  final String id;
  final String roomJid;
  final String text;
  final ChatUser user;
  final int createdAtMs;
  final bool pending;
  final bool isMedia;
  final String? mediaUrl;
  final String? mimeType;
  final String? xmppId;
  final int? timestamp;
  final bool system;
  final bool showInChannel;
  final bool isReply;

  ChatMessage copyWith({
    String? id,
    String? roomJid,
    String? text,
    ChatUser? user,
    int? createdAtMs,
    bool? pending,
    bool? isMedia,
    String? mediaUrl,
    String? mimeType,
    String? xmppId,
    int? timestamp,
    bool? system,
    bool? showInChannel,
    bool? isReply,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      roomJid: roomJid ?? this.roomJid,
      text: text ?? this.text,
      user: user ?? this.user,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      pending: pending ?? this.pending,
      isMedia: isMedia ?? this.isMedia,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mimeType: mimeType ?? this.mimeType,
      xmppId: xmppId ?? this.xmppId,
      timestamp: timestamp ?? this.timestamp,
      system: system ?? this.system,
      showInChannel: showInChannel ?? this.showInChannel,
      isReply: isReply ?? this.isReply,
    );
  }
}
