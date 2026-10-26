// What to do with an incoming `call-token` (web networking/callTokenStanza.ts
// onCallTokenMessage, the `call-token` branch), as one pure function: the
// stanza and a snapshot of the world go in, a plan comes out. The coordinator
// executes the plan, so every rule here (freshness, system-account trust,
// room-type filters, name resolution, busy / glare) is unit testable.

import 'package:xml/xml.dart';

import 'call_display.dart';
import 'call_mode.dart';
import 'call_sender_trust.dart';
import 'call_stanza.dart';
import 'call_state.dart';

/// The room a call-token names, as far as the local chat list knows it.
class CallRoomInfo {
  const CallRoomInfo({
    required this.jid,
    this.title,
    this.type,
    this.usersCnt = 0,
  });

  final String jid;
  final String? title;
  final String? type;
  final int usersCnt;
}

enum IncomingTokenAction {
  /// Nothing to do (disabled, stale, filtered, duplicate, malformed).
  ignore,

  /// Ring: dispatch [IncomingTokenPlan.incoming].
  ring,

  /// The token for the call WE dialled: connect to it.
  outgoingToken,

  /// A p2p call this platform cannot take: tell the server, do not ring.
  declineUnsupported,

  /// A p2p call while another call is in progress: decline it.
  declineBusy,
}

class IncomingTokenPlan {
  const IncomingTokenPlan._(
    this.action, {
    this.glareYield = false,
    this.roomJid = '',
    this.roomName = '',
    this.roomBareName = '',
    this.token = '',
    this.kind = CallKind.video,
    this.callId,
    this.peerXmppUsername,
    this.mode = CallMode.livekit,
    this.isGroup = false,
    this.iceServers,
    this.livekitUrl,
    this.callerName,
    this.callerXmppUsername,
  });

  const IncomingTokenPlan.ignore() : this._(IncomingTokenAction.ignore);

  final IncomingTokenAction action;

  /// We both dialled at once and the other call has the smaller id: drop ours
  /// (cancel + report ended) before ringing for theirs.
  final bool glareYield;

  final String roomJid;
  final String roomName;
  final String roomBareName;
  final String token;
  final CallKind kind;
  final String? callId;
  final String? peerXmppUsername;
  final CallMode mode;
  final bool isGroup;
  final List<IceServerConfig>? iceServers;
  final String? livekitUrl;
  final String? callerName;
  final String? callerXmppUsername;
}

const Set<String> _badTitles = <String>{
  'deleted',
  'deleted user',
  'unknown',
  'null',
};

/// Plans the handling of [data] (the `call-token` element) carried by
/// [message] (the unwrapped `<message>`).
///
/// [videoCallsEnabled] and [allowedRoomTypes] come from the host config;
/// [selfXmppUsername] and [sessionDomain] from the session; [resolveRoom]
/// matches the stanza's `room` against the chat list (full JID, JID
/// localpart, then title); [lookupUserName] gives a display name for an
/// xmpp username we only know by id.
IncomingTokenPlan planIncomingCallToken({
  required XmlElement message,
  required XmlElement data,
  required bool videoCallsEnabled,
  required List<CallRoomType>? allowedRoomTypes,
  required CallSessionState current,
  required String selfXmppUsername,
  required String sessionDomain,
  required CallRoomInfo? Function(String roomAttr) resolveRoom,
  required String Function(String? xmppUsername) lookupUserName,
  required CallKindHints kindHints,
  bool p2pSupported = true,
  int? nowMs,
}) {
  if (!videoCallsEnabled) return const IncomingTokenPlan.ignore();
  if (!isFreshCallToken(message, nowMs: nowMs)) {
    return const IncomingTokenPlan.ignore();
  }

  // Old servers send neither `mode` nor `group`: parseCallTokenAttrs maps that
  // to a plain LiveKit 1:1 call, exactly the legacy behaviour.
  var attrs = parseCallTokenAttrs(<String, String>{
    for (final a in data.attributes) a.name.local: a.value,
  });
  // livekitUrl and ice decide where the media goes, and callerName / caller
  // decide who the ring screen says is calling, so they are honoured only from
  // the app's system account. Anything else keeps the stanza but loses those
  // attributes: the callee then uses config.videoCalls.livekitUrl,
  // GET /v1/calls/ice-servers and the name it can work out locally.
  if (attrs.hasUntrustedFields &&
      !isSystemAccountSender(message.getAttribute('from'), sessionDomain)) {
    attrs = attrs.withoutUntrustedFields();
  }
  final isP2P = attrs.mode == CallMode.p2p;
  final group = attrs.group;
  final stanzaRoom = attrs.room;
  final stanzaCallId = attrs.callId;

  // Server doesn't propagate `kind` on the broadcast stanza, so first look for
  // a client-side `call-invite` hint stashed when the dialer signalled us
  // directly. Falls back to whatever the server attached, finally to video
  // (legacy default).
  final hinted = kindHints.consume(<String?>[stanzaRoom, stanzaCallId]);
  final kind = callKindFromName(hinted) ?? attrs.kind ?? CallKind.video;

  // A p2p token is intentionally empty (the media never touches LiveKit); it
  // needs the callId instead, to correlate the signalling.
  if (stanzaRoom.isEmpty ||
      (isP2P ? (stanzaCallId ?? '').isEmpty : attrs.token.isEmpty)) {
    return const IncomingTokenPlan.ignore();
  }

  final resolved = resolveRoom(stanzaRoom);
  // Public rooms never call, whatever the token says.
  if (resolved?.type == 'public') return const IncomingTokenPlan.ignore();
  final usersCnt = resolved?.usersCnt ?? 0;
  final isOneToOneLike = usersCnt > 0 && usersCnt <= 2;
  if (group) {
    // Group room call (always LiveKit). The host may opt out through
    // allowedRoomTypes; a room we know to be private contradicts `group`.
    if (!isCallRoomTypeAllowed('group', allowedRoomTypes)) {
      return const IncomingTokenPlan.ignore();
    }
    if (resolved?.type == 'private') return const IncomingTokenPlan.ignore();
  } else {
    final privateAllowed = isCallRoomTypeAllowed('private', allowedRoomTypes);
    final type = resolved?.type;
    if (type != null &&
        type.isNotEmpty &&
        type != 'private' &&
        !isOneToOneLike) {
      return const IncomingTokenPlan.ignore();
    }
    if (type == 'private' && !privateAllowed) {
      return const IncomingTokenPlan.ignore();
    }
    if ((type == null || type.isEmpty) &&
        !stanzaRoom.contains('@') &&
        !isOneToOneLike) {
      return const IncomingTokenPlan.ignore();
    }
  }

  final roomJid = resolved?.jid ?? (stanzaRoom.contains('@') ? stanzaRoom : '');
  if (roomJid.isEmpty) return const IncomingTokenPlan.ignore();

  // Prefer the JWT `sub` claim as the display name on the ring screen: the
  // server populates it with the caller's full name, far more useful than the
  // resolved room title (which for stale peer chats reads "deleted"). A p2p
  // token has no JWT, and in a group the ring should name the room.
  final jwtPayload = isP2P ? null : decodeJwtPayload(attrs.token);
  final jwtName =
      group ? '' : sanitizeCallName(extractCallerDisplayName(jwtPayload));
  final resolvedTitle = (resolved?.title ?? '').trim();
  final titleLooksBad = resolvedTitle.isEmpty ||
      _badTitles.contains(resolvedTitle.toLowerCase()) ||
      looksLikeRawRoomName(resolvedTitle);
  // Group rooms have no single peer; a "<a>-<b>" name there is a coincidence.
  final peerXmppUsername = group
      ? null
      : (derivePeerXmppUsername(stanzaRoom, selfXmppUsername) ?? attrs.caller);
  final peerName = titleLooksBad ? lookupUserName(peerXmppUsername) : '';
  // What the call is called on screen. A person's name is preferred; a raw
  // chat name (two joined JIDs) is never used, an empty result makes the UI
  // show a neutral label. In a group the call is the ROOM, and the caller is
  // carried separately (callerName) for the "X is calling in Y" line.
  final String incomingRoomName;
  if (group) {
    incomingRoomName = (titleLooksBad ? '' : resolvedTitle).isNotEmpty
        ? resolvedTitle
        : sanitizeCallName(stanzaRoom);
  } else {
    incomingRoomName = _firstNonEmpty(<String>[
      attrs.callerName,
      jwtName,
      titleLooksBad ? '' : resolvedTitle,
      sanitizeCallName(peerName),
      sanitizeCallName(stanzaRoom),
    ]);
  }

  final callId = extractCallId(data, jwtPayload);
  if (isP2P && (callId ?? '').isEmpty) return const IncomingTokenPlan.ignore();

  var glareYield = false;
  if (isP2P || current.mode == CallMode.p2p) {
    // Peer to peer (or an active p2p call): one call at a time, decided by
    // callId. The legacy LiveKit-over-LiveKit path is untouched.
    if (isP2P && !p2pSupported) {
      // This platform cannot take the call; tell the caller instead of
      // leaving them ringing.
      return IncomingTokenPlan._(
        IncomingTokenAction.declineUnsupported,
        callId: callId,
        peerXmppUsername: peerXmppUsername,
        roomBareName: stanzaRoom,
      );
    }
    final decision = decideIncomingWhileBusy(
      current.toBusySnapshot(),
      mode: attrs.mode,
      callId: callId,
      roomBareName: stanzaRoom,
    );
    if (decision == IncomingWhileBusy.duplicate ||
        decision == IncomingWhileBusy.glareKeep) {
      return const IncomingTokenPlan.ignore();
    }
    if (decision == IncomingWhileBusy.busy) {
      if (!isP2P) return const IncomingTokenPlan.ignore();
      return IncomingTokenPlan._(
        IncomingTokenAction.declineBusy,
        callId: callId,
        peerXmppUsername: peerXmppUsername,
        roomBareName: stanzaRoom,
      );
    }
    glareYield = decision == IncomingWhileBusy.glareYield;
  }

  // The same call delivered twice (a push that already rang, then the live
  // token): one ring is enough.
  if (current.isIncoming &&
      !current.isIdle &&
      (callId ?? '').isNotEmpty &&
      current.callId == callId) {
    return const IncomingTokenPlan.ignore();
  }

  final isOutgoingRoomMatch = !isP2P &&
      current.direction == CallDirection.outgoing &&
      (current.roomJid == roomJid ||
          current.roomName == incomingRoomName ||
          current.roomBareName == stanzaRoom);
  if (isOutgoingRoomMatch) {
    return IncomingTokenPlan._(
      IncomingTokenAction.outgoingToken,
      roomJid: roomJid,
      token: attrs.token,
      callId: callId,
      livekitUrl: attrs.livekitUrl,
    );
  }

  return IncomingTokenPlan._(
    IncomingTokenAction.ring,
    glareYield: glareYield,
    roomJid: roomJid,
    roomName: incomingRoomName,
    roomBareName: stanzaRoom,
    token: attrs.token,
    kind: kind,
    callId: callId,
    peerXmppUsername: peerXmppUsername,
    mode: attrs.mode,
    isGroup: group,
    iceServers: attrs.iceServers,
    livekitUrl: attrs.livekitUrl,
    callerName: attrs.callerName.isEmpty ? null : attrs.callerName,
    callerXmppUsername: attrs.caller,
  );
}

String _firstNonEmpty(List<String> values) {
  for (final value in values) {
    if (value.isNotEmpty) return value;
  }
  return '';
}
