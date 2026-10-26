import 'dart:convert';

import '../i18n/chat_i18n.dart';
import '../models/chat_message.dart';

/// Parent reference carried by a reply in `<data mainMessage>` (web
/// `parseMessageReference`).
class MessageReference {
  const MessageReference({
    this.id,
    this.text,
    this.roomJid,
    this.userName,
    this.createdAt,
    this.imageLocation,
    this.imagePreview,
    this.mimeType,
  });

  /// Archive id of the parent message.
  final String? id;
  final String? text;
  final String? roomJid;
  final String? userName;
  final String? createdAt;
  final String? imageLocation;
  final String? imagePreview;
  final String? mimeType;
}

/// Parses a `mainMessage` JSON string. Returns null for empty or invalid
/// values, never throws.
MessageReference? parseMessageReference(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    String? s(String key) {
      final value = decoded[key];
      if (value == null) return null;
      final text = '$value';
      return text.isEmpty ? null : text;
    }

    return MessageReference(
      id: s('id'),
      text: s('text'),
      roomJid: s('roomJid'),
      userName: s('userName'),
      createdAt: s('createdAt'),
      imageLocation: s('imageLocation'),
      imagePreview: s('imagePreview'),
      mimeType: s('mimeType'),
    );
  } catch (_) {
    return null;
  }
}

/// Web `replyParentId`: the parent id of a message that is a thread reply
/// and nothing else. A reply also shown in the channel returns null because
/// it already sits in the main list.
String? replyParentId(ChatMessage message) {
  if (!message.isReply) return null;
  if (message.showInChannel) return null;
  return parseMessageReference(message.mainMessage)?.id;
}

/// The parent id of any reply, even one shown in the channel (used to count
/// and list the replies of a thread root).
String? threadParentId(ChatMessage message) {
  if (!message.isReply) return null;
  return parseMessageReference(message.mainMessage)?.id;
}

/// What a media message reads as in a reply preview: its caption, else what
/// the files are (web `getMediaLabel`).
String mediaLabel(ChatMessage message, ChatStrings strings) {
  final caption = (message.data['caption'] ?? '').trim();
  if (caption.isNotEmpty) return caption;
  final items = message.attachments.isNotEmpty
      ? message.attachments
      : <Map<String, String>>[
          <String, String>{'mimetype': message.mimeType ?? ''},
        ];
  final count = items.length;
  bool all(bool Function(String mime) test) =>
      items.every((item) => test(item['mimetype'] ?? ''));
  if (all((m) => m.startsWith('image/'))) {
    return count > 1
        ? strings.t('lastMessage.photos', {'count': count})
        : strings.t('lastMessage.photo');
  }
  if (all((m) => m.startsWith('video/'))) {
    return count > 1
        ? strings.t('lastMessage.videos', {'count': count})
        : strings.t('lastMessage.video');
  }
  if (count == 1 && all((m) => m.startsWith('audio/'))) {
    return strings.t('lastMessage.audio');
  }
  return count > 1
      ? strings.t('lastMessage.files', {'count': count})
      : strings.t('lastMessage.file');
}

/// Web `createMainMessageForThread`: the JSON string stored in the reply's
/// `mainMessage` attribute.
String createMainMessage(ChatMessage message, ChatStrings strings) {
  final body = message.isMedia ? mediaLabel(message, strings) : message.text;
  return jsonEncode(<String, String>{
    'text': body,
    'id': message.id,
    'userName': message.user.displayName,
    'createdAt':
        DateTime.fromMillisecondsSinceEpoch(message.createdAtMs, isUtc: true)
            .toIso8601String(),
    'imageLocation': message.mediaUrl ?? '',
    'imagePreview': message.data['locationPreview'] ?? '',
    'mimeType': message.mimeType ?? '',
    'size': '',
    'duration': '',
    'waveForm': '',
    'attachmentId': '',
    'wrappable': '',
    'nftActionType': '',
    'contractAddress': '',
    'roomJid': message.roomJid,
    'nftId': '',
  });
}
