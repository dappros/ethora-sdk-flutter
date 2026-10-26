import 'chat_user.dart';

/// One reactor's current set of reactions on a message, keyed by the reactor
/// localpart in [ChatMessage.reactions]. Mirrors the web `message.reaction`
/// shape: values are shortcodes (`+1`, `heart`), an empty list is a "removed"
/// marker kept with its [ts] so an older event cannot bring it back.
class ChatReaction {
  const ChatReaction({
    this.emoji = const <String>[],
    this.senderFirstName,
    this.senderLastName,
    this.ts,
  });

  final List<String> emoji;
  final String? senderFirstName;
  final String? senderLastName;
  final String? ts;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.roomJid,
    required this.text,
    required this.user,
    required this.createdAtMs,
    this.pending = false,
    this.failed = false,
    this.isMedia = false,
    this.mediaUrl,
    this.mimeType,
    this.xmppId,
    this.timestamp,
    this.system = false,
    this.showInChannel = true,
    this.isReply = false,
    this.mainMessage,
    this.isEdited = false,
    this.isDeleted = false,
    this.isHistory = false,
    this.langSource,
    this.translations = const <String, String>{},
    this.reactions = const <String, ChatReaction>{},
    this.attachments = const <Map<String, String>>[],
    this.data = const <String, String>{},
    this.receivedBy = const <String, int>{},
  });

  /// Archive id (MAM `<result id>` or `<stanza-id id>`), falling back to the
  /// outer stanza id while the server has not assigned one. Same as web `id`.
  final String id;
  final String roomJid;
  final String text;
  final ChatUser user;
  final int createdAtMs;
  final bool pending;
  final bool failed;
  final bool isMedia;
  final String? mediaUrl;
  final String? mimeType;

  /// Outer `<message id>` as sent by the author. Used to reconcile a pending
  /// local bubble with its server echo.
  final String? xmppId;
  final int? timestamp;

  /// True for `isSystemMessage="true"` and for local markers (the
  /// "New Messages" delimiter). Rendered as a pill, never counted as unread.
  final bool system;
  final bool showInChannel;
  final bool isReply;

  /// Raw `mainMessage` JSON string of a thread reply (parent reference).
  final String? mainMessage;
  final bool isEdited;
  final bool isDeleted;
  final bool isHistory;
  final String? langSource;

  /// languageName -> translated text, parsed from `<translations value>`.
  final Map<String, String> translations;
  final Map<String, ChatReaction> reactions;

  /// Parsed `attachments` JSON array of a multi-attachment message.
  final List<Map<String, String>> attachments;

  /// Every attribute of the `<data>` element, as received.
  final Map<String, String> data;

  /// XEP-0184 delivery receipts: xmpp username -> ms when it was received.
  /// Mirrors web `message.receivedBy`.
  final Map<String, int> receivedBy;

  ChatMessage copyWith({
    String? id,
    String? roomJid,
    String? text,
    ChatUser? user,
    int? createdAtMs,
    bool? pending,
    bool? failed,
    bool? isMedia,
    String? mediaUrl,
    String? mimeType,
    String? xmppId,
    int? timestamp,
    bool? system,
    bool? showInChannel,
    bool? isReply,
    String? mainMessage,
    bool? isEdited,
    bool? isDeleted,
    bool? isHistory,
    String? langSource,
    Map<String, String>? translations,
    Map<String, ChatReaction>? reactions,
    List<Map<String, String>>? attachments,
    Map<String, String>? data,
    Map<String, int>? receivedBy,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      roomJid: roomJid ?? this.roomJid,
      text: text ?? this.text,
      user: user ?? this.user,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      pending: pending ?? this.pending,
      failed: failed ?? this.failed,
      isMedia: isMedia ?? this.isMedia,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mimeType: mimeType ?? this.mimeType,
      xmppId: xmppId ?? this.xmppId,
      timestamp: timestamp ?? this.timestamp,
      system: system ?? this.system,
      showInChannel: showInChannel ?? this.showInChannel,
      isReply: isReply ?? this.isReply,
      mainMessage: mainMessage ?? this.mainMessage,
      isEdited: isEdited ?? this.isEdited,
      isDeleted: isDeleted ?? this.isDeleted,
      isHistory: isHistory ?? this.isHistory,
      langSource: langSource ?? this.langSource,
      translations: translations ?? this.translations,
      reactions: reactions ?? this.reactions,
      attachments: attachments ?? this.attachments,
      data: data ?? this.data,
      receivedBy: receivedBy ?? this.receivedBy,
    );
  }
}
