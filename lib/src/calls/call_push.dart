// An incoming call delivered by push (web helpers/callPush.ts). Calls normally
// ring through a live XMPP `call-token`, which only arrives while the socket
// is up. With the app in the background or closed the backend also sends the
// call as a push `data` payload; this reads it, tolerating the field-name
// variations backends use.

import 'call_display.dart';
import 'call_mode.dart';
import 'call_stanza.dart';

class ParsedCallPush {
  const ParsedCallPush({
    required this.callId,
    required this.token,
    required this.kind,
    required this.roomBareName,
    required this.roomRef,
    required this.callerName,
    required this.callerXmppUsername,
    required this.mode,
    required this.group,
    required this.livekitUrl,
    required this.exp,
  });

  final String? callId;

  /// LiveKit JWT, empty for a p2p call (no token) or when the push had none.
  final String token;
  final CallKind kind;

  /// Bare room name (JID localpart) the call belongs to.
  final String? roomBareName;

  /// Raw room reference from the payload (full JID or bare name).
  final String? roomRef;

  /// Display name of the caller, sanitised ('' when unusable).
  final String callerName;
  final String? callerXmppUsername;
  final CallMode mode;
  final bool group;
  final String? livekitUrl;

  /// The JWT `exp` claim in epoch ms, null when there is no token or claim.
  final int? exp;
}

String _pick(Map<String, dynamic> data, List<String> keys) {
  for (final key in keys) {
    final value = data[key];
    if (value != null && '$value'.trim().isNotEmpty) return '$value'.trim();
  }
  return '';
}

/// True when [data] represents an incoming call: an explicit call marker, or
/// a callId paired with a call-specific field, so a chat push is never read
/// as a call.
bool looksLikeCallPush(Map<String, dynamic>? data) {
  if (data == null) return false;
  final marker = _pick(
    data,
    const <String>['type', 'pushType', 'category', 'messageType', 'event'],
  ).toLowerCase();
  if (const <String>{'call', 'incoming-call', 'call-token', 'call-invite'}
      .contains(marker)) {
    return true;
  }
  final callId = _pick(data, const <String>['callId', 'callid', 'callID']);
  final kind = _pick(data, const <String>['kind']).toLowerCase();
  final hasCallField =
      _pick(data, const <String>['callToken', 'livekitToken']).isNotEmpty ||
          _pick(data, const <String>['callKind']).isNotEmpty ||
          kind == 'audio' ||
          kind == 'video';
  return callId.isNotEmpty && hasCallField;
}

ParsedCallPush parseCallPush(Map<String, dynamic>? data) {
  final d = data ?? const <String, dynamic>{};
  final roomRef = _pick(
    d,
    const <String>['callRoom', 'room', 'roomJid', 'jid', 'chatId'],
  );
  final token = _pick(d, const <String>['callToken', 'livekitToken', 'token']);
  final mode = _pick(d, const <String>['mode']).toLowerCase() == 'p2p'
      ? CallMode.p2p
      : CallMode.livekit;
  final exp = decodeJwtPayload(token)?['exp'];
  return ParsedCallPush(
    callId: _pick(d, const <String>['callId', 'callid', 'callID']).isEmpty
        ? null
        : _pick(d, const <String>['callId', 'callid', 'callID']),
    token: token,
    kind: callKindFromName(_pick(d, const <String>['callKind', 'kind'])) ??
        CallKind.video,
    roomBareName: roomRef.isEmpty ? null : roomRef.split('@').first,
    roomRef: roomRef.isEmpty ? null : roomRef,
    callerName: sanitizeCallName(
      _pick(d, const <String>[
        'callerName',
        'callerDisplayName',
        'senderName',
        'title',
      ]),
    ),
    callerXmppUsername: sanitizeXmppUsername(
      _pick(d, const <String>[
        'callerXmppUsername',
        'callerUsername',
        'userJid',
        'senderJid',
      ]).split('@').first,
    ),
    mode: mode,
    // A p2p call is 1:1 by construction.
    group: mode == CallMode.livekit &&
        isTrueishAttr(_pick(d, const <String>['group'])),
    livekitUrl: normalizeLivekitUrl(_pick(d, const <String>['livekitUrl'])),
    exp: exp is num ? exp.toInt() * 1000 : null,
  );
}

/// A LiveKit join token is only valid for a minute or so; a push that arrives
/// (or is answered) after that cannot join.
bool isCallTokenExpired(int? expMs, {int? nowMs, int skewMs = 2000}) {
  if (expMs == null) return false;
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return now > expMs + skewMs;
}
