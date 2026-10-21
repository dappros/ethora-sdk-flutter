// Display-name hygiene for the call UI (web calls/callDisplay.ts). Names reach
// the ring screen from several places (a call-token attribute, a JWT claim, a
// room title); this keeps raw identifiers and hostile text from ever being
// shown as a person's name.

/// Shown on the ring screen when no human-readable name is known.
const String kNeutralIncomingCallLabel = 'Incoming call';

const int _maxCallNameLength = 80;

const String _hex24 = '[0-9a-fA-F]{24}';
// A user JID local part: <appId>_<userId>, optionally with an @domain.
const String _userId = '$_hex24' '_' '$_hex24' r'(?:@[A-Za-z0-9.]+)?';

// A 1:1 chat is named "<jidA>-<jidB>" (two user ids joined by a hyphen).
final RegExp _oneToOneRoom = RegExp('^$_userId(?:-$_userId)*\$');
// A group chat is named "<appId>_<uuid>".
final RegExp _groupRoom = RegExp(
  '^$_hex24'
  '_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\$',
);
// Anything long that is nothing but hex, underscores and hyphens is an id.
final RegExp _opaqueId = RegExp(r'^[0-9a-fA-F_-]{16,}$');

/// True for strings that are a chat's internal name or an id rather than
/// something a person would be called: two user JIDs joined (the private chat
/// name), a lone user id, an `<appId>_<uuid>` group name, or any long run of
/// hex / underscore / hyphen.
bool looksLikeRawRoomName(Object? value) {
  final text = value is String ? value.trim() : '';
  if (text.isEmpty) return false;
  return _oneToOneRoom.hasMatch(text) ||
      _groupRoom.hasMatch(text) ||
      _opaqueId.hasMatch(text);
}

// C0/C1 controls, bidi overrides/isolates and zero-width characters: none of
// them belong in a name, and the bidi ones can make text read backwards.
final RegExp _unwantedChars = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2060-\u2064'
  r'\u2066-\u2069\uFEFF]',
);

/// Plain-text, display-safe version of a name: control characters stripped,
/// whitespace collapsed and trimmed, capped at about 80 characters. Returns ''
/// when nothing usable is left or the value is a raw chat name / id.
String sanitizeCallName(Object? value) {
  if (value is! String) return '';
  final cleaned = value
      .replaceAll(_unwantedChars, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return '';
  // Cap by code point so a surrogate pair is never cut in half.
  final capped =
      String.fromCharCodes(cleaned.runes.take(_maxCallNameLength)).trim();
  return looksLikeRawRoomName(capped) ? '' : capped;
}

/// [sanitizeCallName] with null instead of '' (state-friendly).
String? safeCallName(Object? value) {
  final name = sanitizeCallName(value);
  return name.isEmpty ? null : name;
}

final RegExp _xmppUsernameShape =
    RegExp(r'^[A-Za-z0-9_-]{1,128}(?:@[A-Za-z0-9.-]+)?$');

/// An xmppUsername from a stanza attribute, or null when it is not shaped like
/// one (it is only ever used for lookups and routing, never shown).
String? sanitizeXmppUsername(Object? value) {
  final text = value is String ? value.trim() : '';
  final local = text.split('/').first;
  return _xmppUsernameShape.hasMatch(local) ? local : null;
}
