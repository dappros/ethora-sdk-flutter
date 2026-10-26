// Pure helpers that decide HOW a call is carried (web calls/callMode.ts),
// shared by the dialer, the stanza handler and the overlay.
//
// Three kinds of call exist:
//   - 1:1 over our own WebRTC peer connection ("p2p"): chosen by the server,
//     only for private chats and only when the install has P2P enabled;
//   - 1:1 over LiveKit: the fallback when the server answers `livekit`;
//   - group over LiveKit: any non-private chat, always `livekit`.
// The client never picks the transport, it follows the server's `mode`.

import 'dart:convert';

import 'call_display.dart';

enum CallMode { livekit, p2p }

enum CallKind { audio, video }

enum CallRoomType { private, group }

CallKind? callKindFromName(Object? value) {
  switch ('${value ?? ''}'.trim().toLowerCase()) {
    case 'audio':
      return CallKind.audio;
    case 'video':
      return CallKind.video;
  }
  return null;
}

/// One STUN/TURN entry (serializable subset of RTCIceServer).
class IceServerConfig {
  const IceServerConfig({
    required this.urls,
    this.username,
    this.credential,
  });

  final List<String> urls;
  final String? username;
  final String? credential;

  /// The map `createPeerConnection` expects inside `iceServers`.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'urls': urls.length == 1 ? urls.first : urls,
        if (username != null) 'username': username,
        if (credential != null) 'credential': credential,
      };

  @override
  bool operator ==(Object other) =>
      other is IceServerConfig &&
      other.username == username &&
      other.credential == credential &&
      _listEquals(other.urls, urls);

  @override
  int get hashCode => Object.hash(Object.hashAll(urls), username, credential);
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final RegExp _iceUrl =
    RegExp(r'^(stun|stuns|turn|turns):', caseSensitive: false);

/// Accepts a list, an `{iceServers}` envelope or a JSON string of either (the
/// call-token stanza carries the list as a JSON attribute) and returns only
/// well formed stun/turn entries. Anything else is dropped, never thrown.
List<IceServerConfig> normalizeIceServers(Object? raw) {
  Object? value = raw;
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return const <IceServerConfig>[];
    try {
      value = jsonDecode(text);
    } catch (_) {
      return const <IceServerConfig>[];
    }
  }
  if (value is Map && value['iceServers'] is List) {
    value = value['iceServers'];
  }
  if (value is! List) return const <IceServerConfig>[];

  final out = <IceServerConfig>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final rawUrls = entry['urls'] ?? entry['url'];
    final candidates = rawUrls is List ? rawUrls : <Object?>[rawUrls];
    final list = candidates
        .whereType<String>()
        .map((u) => u.trim())
        .where(_iceUrl.hasMatch)
        .toList();
    if (list.isEmpty) continue;
    final username = entry['username'];
    final credential = entry['credential'];
    out.add(
      IceServerConfig(
        urls: rawUrls is String ? <String>[list.first] : list,
        username: username is String && username.isNotEmpty ? username : null,
        credential:
            credential is String && credential.isNotEmpty ? credential : null,
      ),
    );
  }
  return out;
}

final RegExp _livekitUrl =
    RegExp(r'^(wss?|https?)://\S+$', caseSensitive: false);

/// A LiveKit server URL as the backend publishes it. Only websocket / http(s)
/// URLs are accepted: the value ends up as the connect target of the media
/// session, so anything else is treated as unset.
String? normalizeLivekitUrl(Object? raw) {
  final text = raw is String ? raw.trim() : '';
  return _livekitUrl.hasMatch(text) ? text : null;
}

bool _isTrueish(Object? value) {
  final text = '${value ?? ''}'.trim().toLowerCase();
  return text == 'true' || text == '1';
}

/// Public so the router can apply the same reading to stanza attributes.
bool isTrueishAttr(Object? value) => _isTrueish(value);

/// Attributes of a `<data type="call-token">` element, defensively read.
class ParsedCallTokenAttrs {
  const ParsedCallTokenAttrs({
    required this.token,
    required this.room,
    required this.callId,
    required this.kind,
    required this.mode,
    required this.group,
    required this.iceServers,
    required this.livekitUrl,
    required this.callerName,
    required this.caller,
  });

  final String token;
  final String room;

  /// Raw `callId` attribute, null when absent (the JWT may still carry it).
  final String? callId;

  /// Valid `kind` attribute, null when absent or unrecognised.
  final CallKind? kind;
  final CallMode mode;
  final bool group;

  /// Callee's ICE servers for `mode=p2p`, null when absent or unparseable.
  final List<IceServerConfig>? iceServers;

  /// Public LiveKit wss URL for `mode=livekit`, null when not sent or unusable.
  final String? livekitUrl;

  /// Caller's display name as plain text; '' when absent. Only trustworthy
  /// from the system account (see call_sender_trust.dart).
  final String callerName;

  /// Caller's xmppUsername when well formed, else null. Same trust rule.
  final String? caller;

  /// Copy with the sender-controlled network and identity attributes removed.
  ParsedCallTokenAttrs withoutUntrustedFields() => ParsedCallTokenAttrs(
        token: token,
        room: room,
        callId: callId,
        kind: kind,
        mode: mode,
        group: group,
        iceServers: null,
        livekitUrl: null,
        callerName: '',
        caller: null,
      );

  bool get hasUntrustedFields =>
      livekitUrl != null ||
      iceServers != null ||
      callerName.isNotEmpty ||
      caller != null;
}

/// Tolerant reader for the call-token stanza. A server that sends neither
/// `mode` nor `group` (every server before P2P / group calls) yields
/// `livekit`, not a group: exactly the legacy behaviour. Never throws.
ParsedCallTokenAttrs parseCallTokenAttrs(Map<String, String>? attrs) {
  final a = attrs ?? const <String, String>{};
  final mode = (a['mode'] ?? '').trim().toLowerCase() == 'p2p'
      ? CallMode.p2p
      : CallMode.livekit;
  final iceList = mode == CallMode.p2p
      ? normalizeIceServers(a['ice'])
      : const <IceServerConfig>[];
  final callId = (a['callId'] ?? a['callid'] ?? '').trim();
  return ParsedCallTokenAttrs(
    token: (a['token'] ?? '').trim(),
    room: (a['room'] ?? '').trim(),
    callId: callId.isEmpty ? null : callId,
    kind: callKindFromName(a['kind']),
    mode: mode,
    // A p2p call is 1:1 by construction; never let a stray attribute flip it.
    group: mode == CallMode.livekit && _isTrueish(a['group']),
    iceServers: mode == CallMode.p2p && iceList.isNotEmpty ? iceList : null,
    livekitUrl:
        mode == CallMode.livekit ? normalizeLivekitUrl(a['livekitUrl']) : null,
    callerName: sanitizeCallName(a['callerName']),
    caller: sanitizeXmppUsername(a['caller']),
  );
}

/// Normalised `POST /v1/chats/call/create/:chatName` response.
class CallCreateResult {
  const CallCreateResult({
    required this.callId,
    required this.mode,
    required this.kind,
    required this.group,
    required this.livekitUrl,
    required this.iceServers,
    required this.ttlSeconds,
  });

  final String? callId;
  final CallMode mode;
  final CallKind kind;

  /// Server-reported group flag, null when the server did not say.
  final bool? group;
  final String? livekitUrl;
  final List<IceServerConfig> iceServers;
  final int? ttlSeconds;
}

/// Reads the create response. Old servers answer with no `mode`, which maps to
/// `livekit` (the caller then waits for its own call-token as before). A p2p
/// answer without a callId is unusable (no way to correlate signalling) and
/// throws a [FormatException].
CallCreateResult parseCallCreateResponse(Object? data, CallKind fallbackKind) {
  final root = data is Map ? data : const <String, dynamic>{};
  final result = root['result'];
  final d = result is Map && root['mode'] == null ? result : root;
  final mode = '${d['mode'] ?? ''}'.trim().toLowerCase() == 'p2p'
      ? CallMode.p2p
      : CallMode.livekit;
  final callId = '${d['callId'] ?? d['callid'] ?? ''}'.trim();
  if (mode == CallMode.p2p && callId.isEmpty) {
    throw const FormatException('Call response is missing callId');
  }
  final ttl = num.tryParse('${d['ttlSeconds'] ?? ''}');
  return CallCreateResult(
    callId: callId.isEmpty ? null : callId,
    mode: mode,
    kind: callKindFromName(d['kind']) ?? fallbackKind,
    group: d['group'] is bool ? d['group'] as bool : null,
    livekitUrl: normalizeLivekitUrl(d['livekitUrl']),
    iceServers: mode == CallMode.p2p
        ? normalizeIceServers(d['iceServers'])
        : const <IceServerConfig>[],
    ttlSeconds: ttl != null && ttl > 0 ? ttl.toInt() : null,
  );
}

/// Which room types may start / receive calls. Hosts that never set
/// `allowedRoomTypes` get 1:1 and group chats; an explicit list is respected
/// as written (so `[private]` keeps a host on 1:1 only).
const List<CallRoomType> kDefaultCallRoomTypes = <CallRoomType>[
  CallRoomType.private,
  CallRoomType.group,
];

/// [roomType] is the API's room type string (`private`, `group`, `public`).
/// Public rooms never call.
bool isCallRoomTypeAllowed(
  String? roomType,
  List<CallRoomType>? allowedRoomTypes,
) {
  final CallRoomType type;
  switch (roomType) {
    case 'private':
      type = CallRoomType.private;
    case 'group':
      type = CallRoomType.group;
    default:
      return false;
  }
  return (allowedRoomTypes ?? kDefaultCallRoomTypes).contains(type);
}

/// What [decideIncomingWhileBusy] needs to know about the call on screen.
class BusyCallSnapshot {
  const BusyCallSnapshot({
    required this.phase,
    required this.direction,
    required this.mode,
    required this.callId,
    required this.roomBareName,
  });

  /// One of the CallPhase names: `idle`, `requesting`, ...
  final String phase;

  /// `incoming`, `outgoing` or null.
  final String? direction;
  final CallMode mode;
  final String? callId;
  final String? roomBareName;
}

/// What to do with an incoming call-token while another call may be active.
///  - accept:      nothing active, ring.
///  - duplicate:   same callId as the active call (server re-delivery), ignore.
///  - replace:     legacy LiveKit behaviour (a new token overwrites the old
///                 call), kept exactly for livekit-vs-livekit.
///  - glareYield:  both sides dialled each other; the lexicographically smaller
///                 callId wins on BOTH ends, and this is the loser: drop our
///                 outgoing call and ring for theirs.
///  - glareKeep:   same race, we hold the winning callId, ignore theirs.
///  - busy:        a different call is in progress, decline the newcomer.
enum IncomingWhileBusy {
  accept,
  duplicate,
  replace,
  glareYield,
  glareKeep,
  busy
}

IncomingWhileBusy decideIncomingWhileBusy(
  BusyCallSnapshot current, {
  required CallMode mode,
  required String? callId,
  required String? roomBareName,
}) {
  if (current.phase == 'idle') return IncomingWhileBusy.accept;
  if (callId != null && callId.isNotEmpty && current.callId == callId) {
    return IncomingWhileBusy.duplicate;
  }
  if (current.mode != CallMode.p2p && mode != CallMode.p2p) {
    return IncomingWhileBusy.replace;
  }
  final sameRoom = roomBareName != null &&
      roomBareName.isNotEmpty &&
      current.roomBareName == roomBareName;
  final mine = current.callId;
  if (sameRoom &&
      current.direction == 'outgoing' &&
      current.phase == 'requesting' &&
      mode == CallMode.p2p &&
      current.mode == CallMode.p2p &&
      mine != null &&
      mine.isNotEmpty &&
      callId != null &&
      callId.isNotEmpty) {
    return callId.compareTo(mine) < 0
        ? IncomingWhileBusy.glareYield
        : IncomingWhileBusy.glareKeep;
  }
  return IncomingWhileBusy.busy;
}
