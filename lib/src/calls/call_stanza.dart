// Pure stanza-level helpers for call signalling (web networking/
// callTokenStanza.ts): classifying an incoming `<message>`, the 5 s call-token
// freshness check, JWT claim reading, the `call-invite` kind hint stash and
// the outgoing `call-state` / `call-invite` builders. No sockets, no state:
// everything here is unit testable.

import 'dart:convert';

import 'package:xml/xml.dart';

import '../networking/stanza_parser.dart' show childOf, unwrapMucSub, xmlEscape;

/// A call-token whose stanza-id is older than this is a replay (a push-woken
/// app, an archive re-delivery): ringing for it would be a phantom call.
const int kMaxCallTokenAgeMs = 5000;

/// How long a `call-invite` kind hint waits for its call-token.
const int kKindHintTtlMs = 60000;

/// Body-text values the server may use to broadcast call signalling into a
/// MUC room. These must NEVER reach the chat pipeline or they render as chat
/// bubbles saying "call-state".
const Set<String> kCallBodyKeywords = <String>{
  'call-token',
  'call-state',
  'call-ringing',
  'call-ended',
  'call-declined',
  'call-cancelled',
  'call-canceled',
  'call-timeout',
  'call-rejected',
};

/// First 13 digits of a numeric id or timestamp as epoch ms (stanza-ids are
/// 16-digit microseconds). Null when nothing numeric is there.
int? extractNumericTimestamp(String? value) {
  final source = (value ?? '').trim();
  if (source.isEmpty) return null;
  final direct = int.tryParse(source);
  if (direct != null && direct > 0) {
    return source.length > 13 ? int.tryParse(source.substring(0, 13)) : direct;
  }
  final match = RegExp(r'\d{13,}').firstMatch(source)?.group(0);
  if (match == null) return null;
  return int.tryParse(match.substring(0, 13));
}

/// True when the stanza's `stanza-id` says it was created within
/// [kMaxCallTokenAgeMs] of [nowMs]. A stanza with no stanza-id is not fresh.
bool isFreshCallToken(XmlElement stanza, {int? nowMs}) {
  final id = childOf(stanza, 'stanza-id')?.getAttribute('id');
  final created = extractNumericTimestamp(id);
  if (created == null || created <= 0) return false;
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return (now - created).abs() <= kMaxCallTokenAgeMs;
}

/// Decodes the JWT payload without verifying it. Only non-sensitive claims are
/// read (`sub`, `metadata.callId`): the server already vetted the token and
/// LiveKit rejects anything tampered with on connect. Null when [token] is
/// not a parseable JWT.
Map<String, dynamic>? decodeJwtPayload(String? token) {
  if (token == null || token.isEmpty) return null;
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    var b64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    b64 = b64.padRight(b64.length + (4 - b64.length % 4) % 4, '=');
    final decoded = jsonDecode(utf8.decode(base64.decode(b64)));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// The call id from the `callId` attribute, else from the JWT `metadata`.
String? extractCallId(XmlElement data, Map<String, dynamic>? jwtPayload) {
  final fromAttr =
      (data.getAttribute('callId') ?? data.getAttribute('callid') ?? '').trim();
  if (fromAttr.isNotEmpty) return fromAttr;
  var metadata = jwtPayload?['metadata'];
  if (metadata is String) {
    try {
      metadata = jsonDecode(metadata);
    } catch (_) {
      return null;
    }
  }
  if (metadata is Map && metadata['callId'] != null) {
    final id = '${metadata['callId']}'.trim();
    return id.isEmpty ? null : id;
  }
  return null;
}

final RegExp _rawIdShape = RegExp(r'^[0-9a-fA-F_-]{16,}$');

/// The JWT `sub` as a caller name. The server sometimes falls back to the
/// xmppUsername / userId when the profile is incomplete; those look like raw
/// ids (long, no spaces, hex and underscores) and are skipped so an opaque id
/// never renders as a "caller name".
String extractCallerDisplayName(Map<String, dynamic>? jwtPayload) {
  final sub = jwtPayload?['sub'];
  if (sub is! String) return '';
  final trimmed = sub.trim();
  if (trimmed.isEmpty || _rawIdShape.hasMatch(trimmed)) return '';
  return trimmed;
}

/// Room name format is `<userA>-<userB>` for 1:1 private chats. Derives the
/// peer xmpp localpart by removing the current user's from the split.
String? derivePeerXmppUsername(String bareRoomName, String selfXmppUsername) {
  if (!bareRoomName.contains('-')) return null;
  final parts = bareRoomName.split('-');
  if (parts.length != 2) return null;
  final selfLocal = selfXmppUsername.split('@').first;
  for (final part in parts) {
    if (part.isNotEmpty && part != selfLocal) return part;
  }
  return null;
}

/// Backend currently does not propagate `kind` on the broadcast call-token
/// stanza, so the dialer sends a direct `call-invite` first. This stash keys
/// the hint by callId AND by room bare name (the token sometimes drops the
/// callId). The TTL keeps the map from growing if a token never arrives.
class CallKindHints {
  CallKindHints({int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  final Map<String, ({String kind, int expiresAt})> _hints =
      <String, ({String kind, int expiresAt})>{};

  void stash(String? key, String kind) {
    if (key == null || key.isEmpty) return;
    final now = _now();
    _hints.removeWhere((_, hint) => hint.expiresAt < now);
    _hints[key] = (kind: kind, expiresAt: now + kKindHintTtlMs);
  }

  /// The first live hint among [keys] (and removes it), else null.
  String? consume(List<String?> keys) {
    final now = _now();
    for (final key in keys) {
      if (key == null || key.isEmpty) continue;
      final hit = _hints[key];
      if (hit != null && hit.expiresAt >= now) {
        _hints.remove(key);
        return hit.kind;
      }
    }
    return null;
  }

  void clear() => _hints.clear();
}

/// What kind of call message a `<message>` is.
sealed class CallStanza {
  const CallStanza({required this.message, required this.data});

  /// The message with any MUC-SUB wrapper removed (the one carrying `<data>`).
  final XmlElement message;
  final XmlElement data;

  /// `from` of the unwrapped message.
  String get from => message.getAttribute('from') ?? '';

  /// Bare room name from `from` (the MUC JID localpart), as a fallback when a
  /// server call-log does not put `room` on the `<data>`.
  String get fromRoom => from.split('/').first.split('@').first.trim();

  String attr(String name) => data.getAttribute(name) ?? '';
}

class CallTokenStanza extends CallStanza {
  const CallTokenStanza({required super.message, required super.data});
}

class CallStateStanza extends CallStanza {
  const CallStateStanza({required super.message, required super.data});
}

class CallInviteStanza extends CallStanza {
  const CallInviteStanza({required super.message, required super.data});
}

/// Server relay of a callee's decline (`call-state-declined`).
class CallDeclinedRelayStanza extends CallStanza {
  const CallDeclinedRelayStanza({required super.message, required super.data});
}

/// Server relay that the callee's phone is ringing (`call-state-ringing`).
class CallRingingRelayStanza extends CallStanza {
  const CallRingingRelayStanza({required super.message, required super.data});
}

class CallP2pStanza extends CallStanza {
  const CallP2pStanza({required super.message, required super.data});
}

/// Any other `<data type="call-*">`: swallowed, never shown in chat.
class CallUnknownStanza extends CallStanza {
  const CallUnknownStanza({required super.message, required super.data});
}

/// Legacy servers broadcast the signal as plain body text only.
class CallBodyOnlyStanza {
  const CallBodyOnlyStanza({required this.message, required this.state});
  final XmlElement message;

  /// The body keyword without the `call-` prefix (`state`, `ended`, ...).
  final String state;
}

/// The `<message>` with a MUC-SUB wrapper removed (web unwrapMucsub).
XmlElement unwrapCallMessage(XmlElement stanza) => unwrapMucSub(stanza);

/// Classifies [stanza] for the calls module, or null when it is not call
/// signalling and belongs to the chat pipeline.
Object? classifyCallMessage(XmlElement stanza) {
  final inner = unwrapCallMessage(stanza);
  final data = childOf(inner, 'data');
  if (data != null &&
      (data.getAttribute('type') ?? '').toLowerCase().startsWith('call-')) {
    switch ((data.getAttribute('type') ?? '').toLowerCase()) {
      case 'call-state':
        return CallStateStanza(message: inner, data: data);
      case 'call-invite':
        return CallInviteStanza(message: inner, data: data);
      case 'call-p2p':
        return CallP2pStanza(message: inner, data: data);
      case 'call-state-declined':
        return CallDeclinedRelayStanza(message: inner, data: data);
      case 'call-state-ringing':
        return CallRingingRelayStanza(message: inner, data: data);
      case 'call-token':
        return CallTokenStanza(message: inner, data: data);
      default:
        return CallUnknownStanza(message: inner, data: data);
    }
  }
  final body = (childOf(inner, 'body')?.innerText ?? '').trim().toLowerCase();
  if (body.isNotEmpty && kCallBodyKeywords.contains(body)) {
    return CallBodyOnlyStanza(
      message: inner,
      state: body.replaceFirst(RegExp(r'^call-'), ''),
    );
  }
  return null;
}

/// True when a server `call-state` carries log metadata (a caller and/or a
/// duration). Bare client signalling (state=cancelled, no caller/duration)
/// must not become a chat entry: it is real-time teardown only.
bool callStateHasLogData(XmlElement data) {
  final caller = (data.getAttribute('callerXmppUsername') ?? '').trim();
  final duration = data.getAttribute('durationMs');
  return caller.isNotEmpty || (duration != null && duration.isNotEmpty);
}

bool isTerminalCallState(String state) {
  switch (state.toLowerCase()) {
    case 'ended':
    case 'declined':
    case 'cancelled':
    case 'canceled':
    case 'timeout':
    case 'rejected':
      return true;
  }
  return false;
}

/// Client-sent call-state values (web CallSignalState).
enum CallSignalState { ended, declined, cancelled, rejected }

/// Direct `call-state` message that dismisses the peer's ring / call screen.
/// Addressed to the peer's bare JID: going through the room is unreliable
/// because the callee may not have joined the MUC during the ring window.
String buildCallStateStanza({
  required String to,
  required CallSignalState state,
  required String callId,
  required String room,
  int? nowMs,
}) {
  final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return '<message to="${xmlEscape(to)}" type="chat" id="call-state-$ms">'
      '<data type="call-state" state="${state.name}" '
      'callId="${xmlEscape(callId)}" room="${xmlEscape(room)}"/>'
      '</message>';
}

/// Tells the peer what KIND of call is starting before the server-side
/// call-token reaches them (the backend drops `kind` on its broadcast).
String buildCallInviteStanza({
  required String to,
  required String kind,
  required String room,
  String? callId,
  int? nowMs,
}) {
  final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return '<message to="${xmlEscape(to)}" type="chat" id="call-invite-$ms">'
      '<data type="call-invite" kind="${xmlEscape(kind)}" '
      'room="${xmlEscape(room)}" callId="${xmlEscape(callId ?? '')}"/>'
      '</message>';
}
