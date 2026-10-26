// The call state machine's data (web roomStore/callSlice.ts). Immutable; every
// transition is a method returning the next state, so the rules are plain
// functions that unit tests can drive without a UI or a connection.

import 'call_display.dart';
import 'call_mode.dart';

enum CallPhase { idle, requesting, ringingIncoming, connecting, inCall, error }

enum CallDirection { outgoing, incoming }

class CallSessionState {
  const CallSessionState({
    this.phase = CallPhase.idle,
    this.direction,
    this.kind = CallKind.video,
    this.roomJid,
    this.roomName,
    this.roomBareName,
    this.callId,
    this.peerXmppUsername,
    this.token,
    this.error,
    this.startedAt,
    this.connectedAt,
    this.mode = CallMode.livekit,
    this.isGroup = false,
    this.livekitUrl,
    this.iceServers,
    this.callerName,
    this.callerXmppUsername,
    this.peerRinging = false,
  });

  static const CallSessionState idle = CallSessionState();

  final CallPhase phase;
  final CallDirection? direction;
  final CallKind kind;
  final String? roomJid;

  /// What the call is called on screen (never a raw chat name).
  final String? roomName;

  /// Bare room name (JID localpart). Server call-state stanzas reference calls
  /// by this value, and we echo it back on hangup signalling.
  final String? roomBareName;

  /// Stable id from the call-token attribute, JWT metadata or the create
  /// response. Used when emitting our own call-state so the peer can
  /// correlate.
  final String? callId;

  /// Peer's XMPP localpart (bare username, no @host). Null in a group call.
  final String? peerXmppUsername;

  /// LiveKit JWT. Empty for a p2p call.
  final String? token;
  final String? error;

  /// Epoch ms the call was created locally (dialled or started ringing).
  final int? startedAt;

  /// Epoch ms the call actually connected; null until then.
  final int? connectedAt;

  /// Transport of this call. `livekit` is the legacy path (and the only one
  /// for group rooms); `p2p` is our own WebRTC peer connection for 1:1.
  final CallMode mode;

  /// Group room call (always LiveKit): more than two participants, so the
  /// session must not assume the call is over when one remote leaves.
  final bool isGroup;

  /// Public LiveKit URL the server reported. Wins over the host config.
  final String? livekitUrl;

  /// STUN/TURN servers (ephemeral credentials) for a p2p call.
  final List<IceServerConfig>? iceServers;

  /// Who is calling, from the call-token (system account only). [roomName]
  /// is the name shown for the call; for a group it is the room, and this is
  /// the person.
  final String? callerName;
  final String? callerXmppUsername;

  /// The callee's phone is ringing (server `call-state-ringing` relay).
  final bool peerRinging;

  bool get isIdle => phase == CallPhase.idle;
  bool get isIncoming => direction == CallDirection.incoming;
  bool get isOutgoing => direction == CallDirection.outgoing;
  bool get isRingingIncoming =>
      isIncoming && phase == CallPhase.ringingIncoming;

  BusyCallSnapshot toBusySnapshot() => BusyCallSnapshot(
        phase: switch (phase) {
          CallPhase.idle => 'idle',
          CallPhase.requesting => 'requesting',
          CallPhase.ringingIncoming => 'ringing-incoming',
          CallPhase.connecting => 'connecting',
          CallPhase.inCall => 'in-call',
          CallPhase.error => 'error',
        },
        direction: switch (direction) {
          CallDirection.outgoing => 'outgoing',
          CallDirection.incoming => 'incoming',
          null => null,
        },
        mode: mode,
        callId: callId,
        roomBareName: roomBareName,
      );

  /// Does [roomAttr] (a stanza `room`) name this call's room?
  bool matchesRoom(String roomAttr) {
    if (roomAttr.isEmpty) return false;
    return roomJid == roomAttr ||
        roomName == roomAttr ||
        roomBareName == roomAttr ||
        (roomJid ?? '').split('@').first == roomAttr;
  }

  CallSessionState copyWith({
    CallPhase? phase,
    CallKind? kind,
    String? token,
    String? error,
    bool clearError = false,
    int? connectedAt,
    bool? peerRinging,
  }) {
    return CallSessionState(
      phase: phase ?? this.phase,
      direction: direction,
      kind: kind ?? this.kind,
      roomJid: roomJid,
      roomName: roomName,
      roomBareName: roomBareName,
      callId: callId,
      peerXmppUsername: peerXmppUsername,
      token: token ?? this.token,
      error: clearError ? null : (error ?? this.error),
      startedAt: startedAt,
      connectedAt: connectedAt ?? this.connectedAt,
      mode: mode,
      isGroup: isGroup,
      livekitUrl: livekitUrl,
      iceServers: iceServers,
      callerName: callerName,
      callerXmppUsername: callerXmppUsername,
      peerRinging: peerRinging ?? this.peerRinging,
    );
  }

  // ---- transitions ---------------------------------------------------------

  /// The user pressed a call button.
  static CallSessionState startOutgoing({
    required String roomJid,
    String? roomName,
    String? roomBareName,
    CallKind kind = CallKind.video,
    String? peerXmppUsername,
    bool isGroup = false,
    required int nowMs,
  }) {
    final bare = (roomBareName ?? '').isNotEmpty
        ? roomBareName
        : roomJid.split('@').first;
    return CallSessionState(
      phase: CallPhase.requesting,
      direction: CallDirection.outgoing,
      kind: kind,
      roomJid: roomJid,
      // A raw chat name is never a name: safeCallName drops it, the UI then
      // shows a neutral label.
      roomName: safeCallName(roomName),
      roomBareName: (bare ?? '').isEmpty ? null : bare,
      peerXmppUsername:
          (peerXmppUsername ?? '').isEmpty ? null : peerXmppUsername,
      startedAt: nowMs,
      isGroup: isGroup,
    );
  }

  /// The create response told the caller how the call is carried. Applied only
  /// to the very call that asked ([startedAt] must match), so a late response
  /// for a call the user already cancelled cannot leak into the next.
  CallSessionState withOutgoingRoute({
    required int? startedAt,
    required String? callId,
    required CallMode mode,
    bool? group,
    String? livekitUrl,
    List<IceServerConfig>? iceServers,
  }) {
    if (direction != CallDirection.outgoing) return this;
    if (startedAt != this.startedAt) return this;
    // The LiveKit call-token can overtake the HTTP response, so a livekit
    // route may still be applied once the phase has moved on to 'connecting'.
    // A p2p route only makes sense while still dialling.
    if (phase != CallPhase.requesting) {
      if (phase != CallPhase.connecting || mode != CallMode.livekit) {
        return this;
      }
    }
    return CallSessionState(
      phase: phase,
      direction: direction,
      kind: kind,
      roomJid: roomJid,
      roomName: roomName,
      roomBareName: roomBareName,
      callId: (callId ?? '').isNotEmpty ? callId : this.callId,
      peerXmppUsername: peerXmppUsername,
      token: token,
      error: error,
      startedAt: this.startedAt,
      connectedAt: connectedAt,
      mode: mode,
      isGroup: group ?? isGroup,
      livekitUrl: (livekitUrl ?? '').isEmpty ? null : livekitUrl,
      iceServers: mode == CallMode.p2p
          ? (iceServers ?? const <IceServerConfig>[])
          : null,
      callerName: callerName,
      callerXmppUsername: callerXmppUsername,
      peerRinging: peerRinging,
    );
  }

  /// A call-token arrived for a call we did not dial: ring.
  static CallSessionState incoming({
    required String roomJid,
    String? roomName,
    String? roomBareName,
    required String token,
    CallKind kind = CallKind.video,
    String? callId,
    String? peerXmppUsername,
    CallMode mode = CallMode.livekit,
    bool isGroup = false,
    List<IceServerConfig>? iceServers,
    String? livekitUrl,
    String? callerName,
    String? callerXmppUsername,
    required int nowMs,
  }) {
    final bare = (roomBareName ?? '').isNotEmpty
        ? roomBareName
        : roomJid.split('@').first;
    return CallSessionState(
      phase: CallPhase.ringingIncoming,
      direction: CallDirection.incoming,
      kind: kind,
      roomJid: roomJid,
      roomName: safeCallName(roomName),
      roomBareName: (bare ?? '').isEmpty ? null : bare,
      callId: (callId ?? '').isEmpty ? null : callId,
      peerXmppUsername:
          (peerXmppUsername ?? '').isEmpty ? null : peerXmppUsername,
      token: token,
      startedAt: nowMs,
      mode: mode,
      isGroup: isGroup,
      livekitUrl: (livekitUrl ?? '').isEmpty ? null : livekitUrl,
      iceServers: iceServers,
      callerName: safeCallName(callerName),
      callerXmppUsername:
          (callerXmppUsername ?? '').isEmpty ? null : callerXmppUsername,
    );
  }

  /// The LiveKit call-token for the call we dialled arrived.
  CallSessionState withOutgoingToken({
    required String roomJid,
    required String token,
    String? callId,
    String? livekitUrl,
    required int nowMs,
  }) {
    if (direction != CallDirection.outgoing) return this;
    final current = this.roomJid ?? '';
    if (current.isNotEmpty && current != roomJid) return this;
    return CallSessionState(
      phase: CallPhase.connecting,
      direction: direction,
      kind: kind,
      roomJid: roomJid,
      roomName: roomName,
      roomBareName: roomBareName,
      callId: (callId ?? '').isNotEmpty ? callId : this.callId,
      peerXmppUsername: peerXmppUsername,
      token: token,
      startedAt: startedAt ?? nowMs,
      connectedAt: connectedAt,
      mode: mode,
      isGroup: isGroup,
      // The stanza's URL, when present, wins over the create response's.
      livekitUrl: (livekitUrl ?? '').isNotEmpty ? livekitUrl : this.livekitUrl,
      iceServers: iceServers,
      callerName: callerName,
      callerXmppUsername: callerXmppUsername,
      peerRinging: peerRinging,
    );
  }

  /// The callee pressed accept.
  CallSessionState accepted(int nowMs) {
    if (direction != CallDirection.incoming) return this;
    return CallSessionState(
      phase: CallPhase.connecting,
      direction: direction,
      kind: kind,
      roomJid: roomJid,
      roomName: roomName,
      roomBareName: roomBareName,
      callId: callId,
      peerXmppUsername: peerXmppUsername,
      token: token,
      startedAt: startedAt ?? nowMs,
      mode: mode,
      isGroup: isGroup,
      livekitUrl: livekitUrl,
      iceServers: iceServers,
      callerName: callerName,
      callerXmppUsername: callerXmppUsername,
    );
  }

  CallSessionState withError(String message, int nowMs) => CallSessionState(
        phase: CallPhase.error,
        direction: direction,
        kind: kind,
        roomJid: roomJid,
        roomName: roomName,
        roomBareName: roomBareName,
        callId: callId,
        peerXmppUsername: peerXmppUsername,
        token: token,
        error: message,
        startedAt: startedAt ?? nowMs,
        connectedAt: connectedAt,
        mode: mode,
        isGroup: isGroup,
        livekitUrl: livekitUrl,
        iceServers: iceServers,
        callerName: callerName,
        callerXmppUsername: callerXmppUsername,
      );

  /// The media is up. Anchors [connectedAt] once, so a mid-call reconnect
  /// blip does not reset the duration.
  CallSessionState connected(int nowMs) => copyWith(
        phase: CallPhase.inCall,
        clearError: true,
        connectedAt: connectedAt ?? nowMs,
      );
}

/// A stanza naming a call decides whether it tears the active one down (web
/// handleCallStateData). Two shapes arrive: client signalling with an
/// explicit terminal `state`, and the server call-log (no `state`, but a
/// caller and/or duration) broadcast when the session concludes. A signal
/// that names a DIFFERENT call than the one on screen (a late log of the
/// previous call in the same room) never tears down the current one.
bool shouldEndCallForState(
  CallSessionState current, {
  required String state,
  required String roomAttr,
  required String callIdAttr,
  required bool hasLogData,
}) {
  if (current.isIdle) return false;
  final roomMatches = current.matchesRoom(roomAttr);
  final callIdMatches = callIdAttr.isNotEmpty &&
      (current.callId ?? '').isNotEmpty &&
      current.callId == callIdAttr;
  final callIdConflicts = callIdAttr.isNotEmpty &&
      (current.callId ?? '').isNotEmpty &&
      current.callId != callIdAttr;
  final lower = state.toLowerCase();
  final terminal = const <String>{
    'ended',
    'declined',
    'cancelled',
    'canceled',
    'timeout',
    'rejected',
  }.contains(lower);
  final isServerCallLog = lower.isEmpty && hasLogData;
  return (callIdMatches || (roomMatches && !callIdConflicts)) &&
      (terminal || isServerCallLog);
}
