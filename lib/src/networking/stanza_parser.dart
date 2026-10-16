import 'dart:convert';

import 'package:xml/xml.dart';

import '../models/chat_message.dart';
import '../models/chat_user.dart';

/// Result of parsing one incoming `<message>` stanza. Mirrors the branches of
/// the web `stanzaHandlers.ts` / `getDataFromXml.ts` so a Flutter client reads
/// exactly what web and React Native write.
sealed class ParsedStanza {
  const ParsedStanza();
}

class ParsedChatMessage extends ParsedStanza {
  const ParsedChatMessage(this.message, {this.queryId});
  final ChatMessage message;

  /// MAM `queryid` when the message came from an archive page.
  final String? queryId;
}

class ParsedEdit extends ParsedStanza {
  const ParsedEdit({
    required this.roomJid,
    required this.targetId,
    required this.text,
  });
  final String roomJid;
  final String targetId;
  final String text;
}

class ParsedDelete extends ParsedStanza {
  const ParsedDelete({required this.roomJid, required this.targetId});
  final String roomJid;
  final String targetId;
}

class ParsedReaction extends ParsedStanza {
  const ParsedReaction({
    required this.roomJid,
    required this.targetId,
    required this.reactor,
    required this.reaction,
  });
  final String roomJid;
  final String targetId;

  /// Localpart of the reactor (from `<reactions from>`).
  final String reactor;
  final ChatReaction reaction;
}

class ParsedTyping extends ParsedStanza {
  const ParsedTyping({
    required this.roomJid,
    required this.nick,
    required this.fullName,
    required this.composing,
    this.senderJid,
  });
  final String roomJid;
  final String nick;
  final String fullName;
  final bool composing;
  final String? senderJid;
}

const _nsMam = 'urn:xmpp:mam:2';
const _nsChatStates = 'http://jabber.org/protocol/chatstates';

/// Converts any id-like or date-like value to epoch milliseconds the way web
/// `getTimestampFromUnknown` does (seconds, ms, microseconds, ISO strings).
int timestampFromUnknown(String? value) {
  if (value == null) return 0;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return 0;
  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    return _normalizeTimestamp(int.tryParse(trimmed) ?? 0);
  }
  final parsed = DateTime.tryParse(trimmed);
  if (parsed != null) return parsed.millisecondsSinceEpoch;
  final chunk = RegExp(r'\d{10,}').firstMatch(trimmed)?.group(0);
  if (chunk != null) return _normalizeTimestamp(int.tryParse(chunk) ?? 0);
  return 0;
}

int _normalizeTimestamp(int value) {
  if (value <= 0) return 0;
  if (value < 100000000000) return value * 1000;
  if (value > 100000000000000000) return value ~/ 1000000;
  if (value > 100000000000000) return value ~/ 1000;
  return value;
}

String localPart(String? jid) {
  final value = (jid ?? '').trim();
  if (value.isEmpty) return '';
  return value.split('@').first;
}

XmlElement? childOf(XmlElement? parent, String localName, {String? xmlns}) {
  if (parent == null) return null;
  for (final child in parent.childElements) {
    if (child.name.local != localName) continue;
    if (xmlns == null ||
        child.namespaceUri == xmlns ||
        child.getAttribute('xmlns') == xmlns) {
      return child;
    }
  }
  return null;
}

/// Unwraps a MUC-SUB pubsub event (`event > items > item > message`) like web.
XmlElement unwrapMucSub(XmlElement message) {
  final event = childOf(message, 'event');
  final inner = childOf(childOf(childOf(event, 'items'), 'item'), 'message');
  return inner ?? message;
}

/// Parses one `<message>` element. Returns null for stanzas the chat
/// pipeline ignores (headlines, call signalling, empty bodies, errors).
ParsedStanza? parseMessageStanza(XmlElement stanza) {
  if (stanza.getAttribute('type') == 'error') return null;
  if (stanza.getAttribute('type') == 'headline') return null;

  final result =
      childOf(stanza, 'result', xmlns: _nsMam) ?? childOf(stanza, 'result');
  final forwarded = childOf(result, 'forwarded');
  final unwrapped = unwrapMucSub(stanza);
  final full = childOf(forwarded, 'message') ?? unwrapped;
  final queryId = result?.getAttribute('queryid');

  final from = full.getAttribute('from') ?? '';
  final slash = from.indexOf('/');
  final roomJid = slash >= 0 ? from.substring(0, slash) : from;
  final resource = slash >= 0 ? from.substring(slash + 1) : '';
  if (roomJid.isEmpty) return null;

  final xmppId = full.getAttribute('id');
  final stanzaIdValue = childOf(full, 'stanza-id')?.getAttribute('id') ??
      childOf(stanza, 'stanza-id')?.getAttribute('id');
  final archiveId = result?.getAttribute('id') ?? stanzaIdValue ?? xmppId;
  final data = childOf(full, 'data') ?? childOf(stanza, 'data');

  // Call signalling never reaches the chat list (web dispatchStanza).
  final dataType = data?.getAttribute('type') ?? '';
  if (dataType.startsWith('call-') &&
      data?.getAttribute('isSystemMessage') != 'true') {
    return null;
  }

  final replace = childOf(full, 'replace');
  if (replace != null && (xmppId ?? '').contains('edit-message')) {
    final target = replace.getAttribute('id') ?? '';
    if (target.isEmpty) return null;
    return ParsedEdit(
      roomJid: roomJid,
      targetId: target,
      text: replace.getAttribute('text') ?? '',
    );
  }

  final delete = childOf(full, 'delete');
  if (delete != null) {
    final target = delete.getAttribute('id') ?? '';
    if (target.isEmpty) return null;
    final by = childOf(full, 'stanza-id')?.getAttribute('by');
    return ParsedDelete(
      roomJid: (by ?? '').isNotEmpty ? by! : roomJid,
      targetId: target,
    );
  }

  final reactions = childOf(full, 'reactions');
  if (reactions != null) {
    final target = reactions.getAttribute('id') ?? '';
    if (target.isEmpty) return null;
    final reactor = localPart(reactions.getAttribute('from') ?? from);
    return ParsedReaction(
      roomJid: roomJid,
      targetId: target,
      reactor: reactor,
      reaction: ChatReaction(
        emoji: reactions.childElements
            .where((e) => e.name.local == 'reaction')
            .map((e) => e.innerText.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        senderFirstName: data?.getAttribute('senderFirstName'),
        senderLastName: data?.getAttribute('senderLastName'),
        ts: stanzaIdValue ?? result?.getAttribute('id'),
      ),
    );
  }

  final composing = childOf(full, 'composing', xmlns: _nsChatStates) ??
      childOf(full, 'composing');
  final paused =
      childOf(full, 'paused', xmlns: _nsChatStates) ?? childOf(full, 'paused');
  if (composing != null || paused != null) {
    if (result != null) return null;
    return ParsedTyping(
      roomJid: roomJid,
      nick: resource,
      fullName: data?.getAttribute('fullName') ?? resource,
      composing: composing != null,
      senderJid: data?.getAttribute('senderJID'),
    );
  }

  final deleted = childOf(full, 'deleted') != null;
  final body = childOf(full, 'body')?.innerText;
  if ((body == null || body.trim().isEmpty) && !deleted) return null;

  final attrs = <String, String>{
    for (final a in data?.attributes ?? const <XmlAttribute>[])
      if (a.name.local != 'xmlns') a.name.local: a.value,
  };

  final delay =
      childOf(full, 'delay') ?? childOf(full, 'x', xmlns: 'jabber:x:delay');
  var ts = timestampFromUnknown(delay?.getAttribute('stamp'));
  if (ts == 0) ts = timestampFromUnknown(stanzaIdValue);
  if (ts == 0) ts = timestampFromUnknown(xmppId);
  if (ts == 0) ts = timestampFromUnknown(archiveId);
  if (ts == 0) ts = DateTime.now().millisecondsSinceEpoch;

  final senderLocal =
      resource.isNotEmpty ? resource : localPart(attrs['senderJID']);
  final photo = attrs['photo'] ?? attrs['photoURL'] ?? attrs['profileImage'];
  final user = ChatUser(
    id: senderLocal,
    username: senderLocal,
    xmppUsername: senderLocal,
    firstName: attrs['senderFirstName'],
    lastName: attrs['senderLastName'],
    walletAddress: attrs['senderWalletAddress'],
    photoUrl: photo,
  );

  final translations = <String, String>{};
  final translationsRaw = childOf(full, 'translations')?.getAttribute('value');
  if (translationsRaw != null) {
    try {
      final decoded = jsonDecode(translationsRaw);
      final list = decoded is Map ? decoded['translates'] : null;
      if (list is List) {
        for (final item in list) {
          if (item is Map &&
              item['translatedText'] is String &&
              item['languageName'] is String) {
            translations[item['languageName'] as String] =
                item['translatedText'] as String;
          }
        }
      }
    } catch (_) {}
  }

  final attachments = parseAttachments(attrs['attachments']);
  final isMedia = attrs['isMediafile'] == 'true' || attachments.isNotEmpty;
  final mediaUrl = attrs['location'] ??
      (attachments.isNotEmpty ? attachments.first['location'] : null);
  final mimeType = attrs['mimetype'] ??
      (attachments.isNotEmpty ? attachments.first['mimetype'] : null);
  final isSystem = attrs['isSystemMessage'] == 'true';

  final message = ChatMessage(
    id: archiveId ?? (xmppId ?? '$ts'),
    roomJid: roomJid,
    text: (body ?? '').trim(),
    user: user,
    createdAtMs: ts,
    timestamp: ts,
    xmppId: xmppId,
    isMedia: isMedia && (mediaUrl ?? '').isNotEmpty,
    mediaUrl: mediaUrl,
    mimeType: mimeType,
    system: isSystem,
    isReply: attrs['isReply'] == 'true',
    showInChannel: attrs['showInChannel'] == 'true' ||
        (attrs['isReply'] != 'true' && (attrs['mainMessage'] ?? '').isEmpty),
    mainMessage:
        (attrs['mainMessage'] ?? '').isEmpty ? null : attrs['mainMessage'],
    isDeleted: deleted,
    isHistory: delay != null || result != null,
    langSource: childOf(full, 'translate')?.getAttribute('source'),
    translations: translations,
    attachments: attachments,
    data: attrs,
  );
  return ParsedChatMessage(message, queryId: queryId);
}

/// Parses the web `attachments` JSON attribute (max 10 entries).
List<Map<String, String>> parseAttachments(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <Map<String, String>>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <Map<String, String>>[];
    return decoded
        .whereType<Map>()
        .take(10)
        .map(
          (item) => <String, String>{
            for (final entry in item.entries)
              if (entry.value != null) '${entry.key}': '${entry.value}',
          },
        )
        .where((item) => (item['location'] ?? '').isNotEmpty)
        .toList();
  } catch (_) {
    return const <Map<String, String>>[];
  }
}

/// Escapes a value for use inside an XML attribute or text node.
String xmlEscape(String input) {
  return input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
