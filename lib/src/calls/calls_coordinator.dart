// Owner of the call state machine (web: callTokenStanza.ts handlers + callSlice
// + VideoCallOverlay + P2PCallRunner + startCall in one place).
//
//  - registers a message interceptor on the XMPP client, so every call
//    stanza is swallowed before the chat pipeline (and acted on here);
//  - dials: `call-invite` direct message, then POST /v1/chats/call/create;
//  - rings for incoming call-tokens (system-account trust, 5 s freshness,
//    busy / glare rules) and routes p2p signalling to the call that owns it;
//  - starts and stops the media runtime for the call in hand: a
//    [P2PCallController] for a p2p 1:1 call, a [LiveKitSession] for LiveKit
//    1:1 and group calls;
//  - exposes the state as a [ChangeNotifier] for the overlay widgets.
//
// Platform pieces (WebRTC, LiveKit, REST, the XMPP socket) come in through
// small seams, so the whole machine runs under fakes in unit tests.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../models/chat_message.dart';
import '../models/chat_room.dart';
import '../models/video_calls_config.dart';
import '../networking/stanza_parser.dart' show localPart;
import '../networking/xmpp_client.dart';
import 'call_api.dart';
import 'call_log.dart';
import 'call_mode.dart';
import 'call_native_bridge.dart';
import 'call_push.dart';
import 'call_stanza.dart';
import 'call_state.dart';
import 'call_token_router.dart';
import 'call_tones.dart';
import 'livekit_session_port.dart';
import 'native_call_ui.dart';
import 'p2p/p2p_call_controller.dart';
import 'p2p/p2p_negotiator.dart';
import 'p2p/p2p_ports.dart';
import 'p2p/p2p_signal.dart';
import 'p2p/p2p_signal_inbox.dart';

/// What the coordinator needs to know about the running chat session.
abstract class CallsHost {
  VideoCallsConfig? get videoCalls;

  /// Our own xmpp username (local part), '' when signed out.
  String get selfXmppUsername;

  /// XMPP domain of this session (the domain call peers are addressed on).
  String get xmppDomain;

  List<ChatRoom> get rooms;

  /// MUC domain (`conference.<host>`), to turn a bare room name from a push
  /// into a room JID before the chat list has loaded.
  String get conferenceDomain;

  /// Adds a call log entry to the room's message list. The host dedupes it
  /// against the server's copy (see [mergeCallLog]).
  void addCallLog(ChatMessage message);

  /// Sends a stanza; false when the socket is not open.
  bool sendStanza(String stanza);

  void log(String message, [Object? detail]);
}

typedef P2PDepsFactory = P2PCallDeps Function({
  required Future<List<IceServerConfig>?> Function() fetchIce,
  required void Function(P2PSignalName signal, P2PSignalPayload payload)
      sendSignal,
  required void Function(String message, [Object? detail]) log,
});

/// How long a dial waits for the callee before it gives up (web
/// OUTGOING_CALL_TIMEOUT_MS; matches the typical PSTN ring window).
const Duration kOutgoingCallTimeout = Duration(seconds: 30);

/// An incoming ring nobody answers or cancels (a stale push, a caller whose
/// cancel was lost) dismisses itself after this long. The caller gives up
/// after 30 s, so this only ever fires for a ring that outlived its call.
const Duration kIncomingRingTimeout = Duration(seconds: 60);

class CallsCoordinator extends ChangeNotifier {
  CallsCoordinator({
    required this.host,
    required this.api,
    required P2PDepsFactory p2pDeps,
    required LiveKitSessionFactory livekit,
    P2PScheduler scheduler = timerScheduler,
    int Function()? now,
    P2PSignalInbox? inbox,
    this.p2pSupported = true,
    this.outgoingTimeout = kOutgoingCallTimeout,
    this.incomingRingTimeout = kIncomingRingTimeout,
    NativeCallUi? nativeUi,
    CallTonePlayer? tonePlayer,
    bool Function()? appResumed,
  })  : _p2pDeps = p2pDeps,
        _livekit = livekit,
        _scheduler = scheduler,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        inbox = inbox ?? P2PSignalInbox(),
        kindHints = CallKindHints(now: now),
        _appResumed = appResumed ?? (() => true) {
    if (tonePlayer != null) {
      _tones = CallToneDriver(tonePlayer, log: host.log);
    }
    if (nativeUi != null) {
      _native = CallNativeBridge(
        ui: nativeUi,
        appResumed: _appResumed,
        log: host.log,
        handlers: CallNativeHandlers(
          onAccept: _onNativeAccept,
          onDecline: _onNativeDecline,
          onEnded: _onNativeEnded,
          onTimeout: _onNativeTimeout,
          onRestored: _onNativeRestored,
        ),
      );
    }
  }

  final CallsHost host;
  final CallApi api;
  final P2PDepsFactory _p2pDeps;
  final LiveKitSessionFactory _livekit;
  final P2PScheduler _scheduler;
  final int Function() _now;
  final P2PSignalInbox inbox;
  final CallKindHints kindHints;

  /// This platform can run a peer to peer call; false makes the coordinator
  /// decline p2p rings instead of leaving the caller waiting.
  final bool p2pSupported;
  final Duration outgoingTimeout;
  final Duration incomingRingTimeout;
  final bool Function() _appResumed;
  CallToneDriver? _tones;
  CallNativeBridge? _native;
  final List<void Function()> _disposeHooks = <void Function()>[];

  CallSessionState _state = CallSessionState.idle;
  CallSessionState get state => _state;

  bool get enabled => host.videoCalls?.enabled == true;
  bool get isBusy => !_state.isIdle;

  /// The p2p controller of the call in hand, null for LiveKit calls.
  P2PCallController? get p2pController => _p2p;

  /// The LiveKit session of the call in hand, null for p2p calls.
  LiveKitSession? get livekitSession => _lk;

  XmppClient? _xmpp;
  bool Function(XmlElement)? _interceptor;

  P2PCallController? _p2p;
  String? _p2pCallId;
  void Function()? _p2pDetach;
  LiveKitSession? _lk;
  String? _lkKey;
  Timer? _dialTimer;
  int? _dialTimerFor;
  Timer? _ringTimer;
  int? _ringTimerFor;
  String? _ringingReportedFor;
  bool _syncing = false;
  bool _resync = false;
  bool _disposed = false;

  // ---- wiring -------------------------------------------------------------

  /// Starts intercepting call stanzas on [xmpp]. Attach regardless of the
  /// `videoCalls` config: with calls off the stanzas are still swallowed, so a
  /// `call-token` body never shows up as a chat bubble.
  void attach(XmppClient xmpp) {
    detach();
    _xmpp = xmpp;
    bool interceptor(XmlElement message) => _onMessage(message);
    _interceptor = interceptor;
    xmpp.messageInterceptors.add(interceptor);
  }

  void detach() {
    final xmpp = _xmpp;
    final interceptor = _interceptor;
    if (xmpp != null && interceptor != null) {
      xmpp.messageInterceptors.remove(interceptor);
    }
    _xmpp = null;
    _interceptor = null;
  }

  /// Logout / session loss: drop any call and all held signalling.
  void reset() {
    _disposeP2p();
    _disposeLk();
    _dialTimer?.cancel();
    _dialTimer = null;
    _dialTimerFor = null;
    _ringTimer?.cancel();
    _ringTimer = null;
    _ringTimerFor = null;
    _ringingReportedFor = null;
    inbox.clear();
    kindHints.clear();
    if (!_state.isIdle) {
      _state = CallSessionState.idle;
      _native?.onStateChanged(_state);
      notifyListeners();
    }
    _tones?.apply(null);
  }

  /// Runs [hook] when the coordinator is disposed (the platform wiring uses
  /// it to drop its lifecycle observer).
  void addDisposeHook(void Function() hook) => _disposeHooks.add(hook);

  /// Starts listening for the native call UI's buttons and picks up a call it
  /// kept across a cold start. Call once, after the session is up.
  Future<void> startNativeCallUi() async => _native?.start();

  /// The app moved between foreground and background: a ring that is still
  /// up moves to the native UI (or back), and the in-app ringtone follows.
  void onAppLifecycleChanged() {
    if (_disposed) return;
    _native?.onLifecycleChanged(_state);
    _updateTone();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detach();
    reset();
    _native?.dispose();
    _tones?.dispose();
    for (final hook in _disposeHooks) {
      hook();
    }
    _disposeHooks.clear();
    super.dispose();
  }

  // ---- state --------------------------------------------------------------

  void _set(CallSessionState next) {
    if (_disposed || identical(next, _state)) return;
    final prev = _state;
    _state = next;
    if (!prev.isIdle && next.isIdle) _logEndedCall(prev);
    _sync();
    // A runtime event inside _sync may have moved the state on again.
    _native?.onStateChanged(_state);
    _updateTone();
    notifyListeners();
  }

  /// A media runtime (p2p controller, LiveKit session) changed.
  void _onMediaChanged() {
    if (_disposed) return;
    _updateTone();
    notifyListeners();
  }

  void _updateTone() {
    final tones = _tones;
    if (tones == null) return;
    final s = _state;
    final tone = desiredCallTone(
      s,
      remoteJoined: (_lk?.snapshot.remoteCount ?? 0) > 0,
      appResumed: _appResumed(),
      nativeIncomingShown: _native?.isRingingNatively(s.callId) ?? false,
    );
    // Ringback of an audio call stays on the earpiece; everything else is
    // loud enough to hear across the room.
    tones.apply(
      tone,
      speaker: tone != CallTone.ringback || s.kind == CallKind.video,
    );
  }

  /// Logs the call that just ended into its room (web terminateCall). The
  /// server's call-state broadcast is authoritative but not guaranteed, and
  /// the host dedupes the two by callId. Only calls that got as far as an id
  /// or a connection are logged.
  void _logEndedCall(CallSessionState ended) {
    final roomJid = ended.roomJid;
    if (roomJid == null || roomJid.isEmpty) return;
    final callId = ended.callId ?? '';
    if (callId.isEmpty && ended.connectedAt == null) return;
    final now = _now();
    final connectedAt = ended.connectedAt;
    try {
      host.addCallLog(
        buildLocalCallLogMessage(
          roomJid: roomJid,
          callId: callId,
          outgoing: ended.isOutgoing,
          durationMs: connectedAt == null ? 0 : now - connectedAt,
          kind: ended.kind,
          selfXmppUsername: host.selfXmppUsername,
          callerXmppUsername:
              ended.callerXmppUsername ?? ended.peerXmppUsername,
          nowMs: now,
        ),
      );
    } catch (error) {
      host.log('[call] local call log failed', error);
    }
  }

  bool _isCurrentCall(String callId) =>
      !_state.isIdle && _state.callId == callId;

  void _endCall() => _set(CallSessionState.idle);

  // ---- dialling -----------------------------------------------------------

  /// Whether [room] may show call buttons: calls on, room type allowed and a
  /// LiveKit URL configured (web ChatHeader `canCall`).
  bool canCallRoom(ChatRoom room) {
    final cfg = host.videoCalls;
    if (cfg == null || !cfg.enabled) return false;
    if (!isCallRoomTypeAllowed(room.type, cfg.allowedRoomTypes)) return false;
    return cfg.hasLivekitUrl;
  }

  /// Places a call in [room]. Returns once the create request settled (the
  /// call itself then continues through the state).
  Future<void> startCall(ChatRoom room, CallKind kind) async {
    if (_disposed || isBusy || !canCallRoom(room)) return;
    final chatName = room.jid.split('@').first;
    if (chatName.isEmpty) return;

    final isGroup = room.type == 'group';
    // Resolve the peer so we can XMPP-signal them when we hang up / cancel:
    // without this they would keep ringing forever. A group call has no
    // single peer; the server rings every member and LiveKit carries the call.
    final self = host.selfXmppUsername;
    ChatRoomMember? peer;
    if (!isGroup) {
      for (final member in room.members) {
        final local = member.xmppUsername.split('@').first;
        if (local.isNotEmpty && local != self) {
          peer = member;
          break;
        }
      }
    }
    final peerXmpp =
        (peer?.xmppUsername ?? '').isEmpty ? null : peer!.xmppUsername;

    // Never show "deleted" / "Unknown" as the dial screen title when the chat
    // title is one of the server sentinels: prefer the peer's name.
    final rawTitle = (room.title ?? '').trim();
    final badTitle = rawTitle.isEmpty ||
        const <String>{'deleted', 'deleted user', 'unknown', 'null'}
            .contains(rawTitle.toLowerCase());
    final peerDisplay =
        '${peer?.firstName ?? ''} ${peer?.lastName ?? ''}'.trim();
    final dialName = (badTitle ? peerDisplay : rawTitle).isNotEmpty
        ? (badTitle ? peerDisplay : rawTitle)
        : (peerDisplay.isNotEmpty ? peerDisplay : chatName);

    _set(
      CallSessionState.startOutgoing(
        roomJid: room.jid,
        roomName: dialName,
        roomBareName: chatName,
        kind: kind,
        peerXmppUsername: peerXmpp,
        isGroup: isGroup,
        nowMs: _now(),
      ),
    );
    final startedAt = _state.startedAt;

    // The server's broadcast call-token drops the `kind` attribute, so signal
    // it directly to the peer first. Direct chat is fast and almost always
    // lands before the server-relayed token.
    if (peerXmpp != null) {
      host.sendStanza(
        buildCallInviteStanza(
          to: _toBareJid(peerXmpp),
          kind: kind.name,
          room: chatName,
        ),
      );
    }

    final CallCreateResult result;
    try {
      result = await api.createCall(chatName, kind);
    } catch (error) {
      if (!_disposed && !_state.isIdle && _state.startedAt == startedAt) {
        _set(_state.withError(
          error is CallCreateException
              ? error.message
              : 'Failed to create call',
          _now(),
        ));
      }
      return;
    }
    _onCreateResult(result, startedAt, chatName, peerXmpp);
  }

  void _onCreateResult(
    CallCreateResult result,
    int? startedAt,
    String chatName,
    String? peerXmpp,
  ) {
    if (_disposed) return;
    final stillCurrent =
        !_state.isIdle && _state.isOutgoing && _state.startedAt == startedAt;
    if (!stillCurrent) {
      // A p2p answer that lands after the user already cancelled: the server
      // has already rung the callee and nothing else knows its callId.
      if (result.mode == CallMode.p2p) {
        api.reportEnded(result.callId);
        if (peerXmpp != null) {
          _sendCallState(
            CallSignalState.cancelled,
            peer: peerXmpp,
            callId: result.callId,
            room: chatName,
          );
        }
      }
      return;
    }
    _set(
      _state.withOutgoingRoute(
        startedAt: startedAt,
        callId: result.callId,
        mode: result.mode,
        group: result.group,
        livekitUrl: result.livekitUrl,
        iceServers: result.iceServers,
      ),
    );
  }

  // ---- user actions -------------------------------------------------------

  void acceptIncoming() {
    if (!_state.isRingingIncoming) return;
    _set(_state.accepted(_now()));
  }

  void declineIncoming() {
    final s = _state;
    if (s.isIdle) return;
    _sendCurrentCallState(CallSignalState.declined);
    // p2p has no LiveKit webhook: the server learns of the decline (and
    // relays it to the caller) only from this report. Never sent for LiveKit
    // calls, where a REST decline would act on the LiveKit room.
    if (s.mode == CallMode.p2p) api.reportDeclined(s.callId);
    _endCall();
  }

  /// Hang up / cancel / decline / dismiss, whatever state the call is in.
  void hangup() {
    final s = _state;
    if (s.isIdle) return;
    if (s.isRingingIncoming) {
      declineIncoming();
    } else if (s.phase == CallPhase.error) {
      _endCall();
    } else {
      _sendCurrentCallState(
        s.phase == CallPhase.requesting
            ? CallSignalState.cancelled
            : CallSignalState.ended,
      );
      _endCall();
    }
  }

  void dismissError() {
    if (_state.phase == CallPhase.error) _endCall();
  }

  // ---- outgoing signalling ------------------------------------------------

  String _toBareJid(String peer) =>
      peer.contains('@') ? peer : '$peer@${host.xmppDomain}';

  void _sendCurrentCallState(CallSignalState state) {
    final s = _state;
    _sendCallState(
      state,
      peer: s.peerXmppUsername,
      callId: s.callId,
      room: s.roomBareName ?? (s.roomJid ?? '').split('@').first,
    );
  }

  void _sendCallState(
    CallSignalState state, {
    required String? peer,
    required String? callId,
    required String? room,
  }) {
    final to = (peer ?? '').trim();
    if (to.isEmpty) return;
    try {
      host.sendStanza(
        buildCallStateStanza(
          to: _toBareJid(to),
          state: state,
          callId: callId ?? '',
          room: room ?? '',
        ),
      );
    } catch (_) {
      // Best effort: the media disconnect is an implicit "call ended" too.
    }
  }

  // ---- incoming stanzas ---------------------------------------------------

  bool _onMessage(XmlElement stanza) {
    // Never let a malformed call stanza break the chat pipeline behind us.
    try {
      final classified = classifyCallMessage(stanza);
      if (classified == null) return false;
      return _handle(classified);
    } catch (error) {
      host.log('[call] stanza handling failed', error);
      return true;
    }
  }

  /// Returns true to consume the stanza; false lets a server call-log flow on
  /// to the chat pipeline, where it becomes a friendly log entry.
  bool _handle(Object classified) {
    switch (classified) {
      case CallStateStanza stanza:
        final data = stanza.data;
        final state =
            (data.getAttribute('state') ?? data.getAttribute('event') ?? '')
                .toLowerCase();
        final declinedInGroup =
            state == 'declined' && isTrueishAttr(data.getAttribute('group'));
        if (!declinedInGroup) _endForState(stanza);
        // Server call-logs (carry callerXmppUsername / durationMs) flow on to
        // the chat; bare client signalling frames are swallowed - they exist
        // only to tear the overlay down.
        return !callStateHasLogData(data);
      case CallInviteStanza stanza:
        _onInvite(stanza);
        return true;
      case CallP2pStanza stanza:
        if (enabled) _onP2pSignal(stanza.message);
        return true;
      case CallDeclinedRelayStanza stanza:
        // In a group call one member declining must not end the call for
        // everybody. For 1:1 it is a terminal state, like a client `declined`.
        if (isTrueishAttr(stanza.attr('group'))) {
          host.log('[call] group member declined', stanza.attr('by'));
          return true;
        }
        _endForState(stanza, overrideState: 'declined');
        return true;
      case CallRingingRelayStanza stanza:
        _onRingingRelay(stanza);
        return true;
      case CallTokenStanza stanza:
        _onCallToken(stanza);
        return true;
      default:
        // Unknown `call-*` signalling, or a legacy body-only keyword: swallow
        // so it never lands in chat.
        return true;
    }
  }

  void _endForState(CallStanza stanza, {String? overrideState}) {
    final data = stanza.data;
    final state = overrideState ??
        (data.getAttribute('state') ?? data.getAttribute('event') ?? '');
    final room = (data.getAttribute('room') ?? '').trim();
    final end = shouldEndCallForState(
      _state,
      state: state,
      roomAttr: room.isEmpty ? stanza.fromRoom : room,
      callIdAttr:
          (data.getAttribute('callId') ?? data.getAttribute('callid') ?? '')
              .trim(),
      hasLogData: callStateHasLogData(data),
    );
    if (end) _endCall();
  }

  void _onInvite(CallInviteStanza stanza) {
    final kind = (stanza.attr('kind')).toLowerCase() == 'audio'
        ? CallKind.audio
        : CallKind.video;
    final room = stanza.attr('room').trim();
    final callId = (stanza.attr('callId').isNotEmpty
            ? stanza.attr('callId')
            : stanza.attr('callid'))
        .trim();
    // Stash for the upcoming call-token lookup AND patch any existing call
    // state if the token actually arrived first (rare race).
    kindHints.stash(room.isEmpty ? null : room, kind.name);
    kindHints.stash(callId.isEmpty ? null : callId, kind.name);

    final s = _state;
    final matchesActive = !s.isIdle &&
        ((room.isNotEmpty && s.matchesRoom(room)) ||
            (callId.isNotEmpty && s.callId == callId));
    if (matchesActive && s.kind != kind) _set(s.copyWith(kind: kind));
  }

  void _onRingingRelay(CallRingingRelayStanza stanza) {
    final s = _state;
    if (s.isIdle || !s.isOutgoing || s.peerRinging) return;
    final callId = stanza.attr('callId');
    final room = stanza.attr('room');
    if ((callId.isNotEmpty && s.callId == callId) ||
        (callId.isEmpty && room.isNotEmpty && s.matchesRoom(room))) {
      _set(s.copyWith(peerRinging: true));
    }
  }

  void _onP2pSignal(XmlElement message) {
    final signal = parseP2PSignalStanza(message, nowMs: _now());
    if (signal == null || signal.fromLocal.isEmpty) return;
    if (!isP2PSignalFresh(signal)) return;
    if (signal.fromLocal ==
        host.selfXmppUsername.split('@').first.toLowerCase()) {
      return;
    }
    inbox.receive(signal);
  }

  CallRoomInfo? _resolveRoom(String roomAttr) {
    final rooms = host.rooms;
    ChatRoom? found;
    for (final room in rooms) {
      if (room.jid == roomAttr) found = room;
    }
    found ??= rooms
        .where((room) => room.jid.split('@').first == roomAttr)
        .firstOrNull;
    found ??= rooms.where((room) => room.title == roomAttr).firstOrNull;
    if (found == null) return null;
    return CallRoomInfo(
      jid: found.jid,
      title: found.title,
      type: found.type,
      usersCnt: found.usersCnt,
    );
  }

  /// Display name of a user we only know by xmpp username (p2p tokens carry no
  /// JWT, so no caller name), from the members of the chat list.
  String _lookupUserName(String? xmppUsername) {
    final key = (xmppUsername ?? '').trim();
    if (key.isEmpty) return '';
    final local = localPart(key);
    for (final room in host.rooms) {
      for (final member in room.members) {
        if (member.xmppUsername == key || member.xmppUsername == local) {
          final name = '${member.firstName} ${member.lastName}'.trim();
          if (name.isNotEmpty) return name;
        }
      }
    }
    return '';
  }

  void _onCallToken(CallTokenStanza stanza) {
    final plan = planIncomingCallToken(
      message: stanza.message,
      data: stanza.data,
      videoCallsEnabled: enabled,
      allowedRoomTypes: host.videoCalls?.allowedRoomTypes,
      current: _state,
      selfXmppUsername: host.selfXmppUsername,
      sessionDomain: host.xmppDomain,
      resolveRoom: _resolveRoom,
      lookupUserName: _lookupUserName,
      kindHints: kindHints,
      p2pSupported: p2pSupported,
      nowMs: _now(),
    );
    switch (plan.action) {
      case IncomingTokenAction.ignore:
        return;
      case IncomingTokenAction.declineUnsupported:
        api.reportDeclined(plan.callId);
      case IncomingTokenAction.declineBusy:
        api.reportDeclined(plan.callId);
        _sendCallState(
          CallSignalState.declined,
          peer: plan.peerXmppUsername,
          callId: plan.callId,
          room: plan.roomBareName,
        );
      case IncomingTokenAction.outgoingToken:
        _set(
          _state.withOutgoingToken(
            roomJid: plan.roomJid,
            token: plan.token,
            callId: plan.callId,
            livekitUrl: plan.livekitUrl,
            nowMs: _now(),
          ),
        );
      case IncomingTokenAction.ring:
        if (plan.glareYield) {
          // We both dialled at once and the other call has the smaller id:
          // drop ours (the other side keeps theirs and ignores our token).
          final mine = _state;
          _sendCurrentCallState(CallSignalState.cancelled);
          api.reportEnded(mine.callId);
        }
        _set(
          CallSessionState.incoming(
            roomJid: plan.roomJid,
            roomName: plan.roomName,
            roomBareName: plan.roomBareName,
            token: plan.token,
            kind: plan.kind,
            callId: plan.callId,
            peerXmppUsername: plan.peerXmppUsername,
            mode: plan.mode,
            isGroup: plan.isGroup,
            iceServers: plan.iceServers,
            livekitUrl: plan.livekitUrl,
            callerName: plan.callerName,
            callerXmppUsername: plan.callerXmppUsername,
            nowMs: _now(),
          ),
        );
    }
  }

  // ---- call pushes and the native call UI ---------------------------------

  /// A call delivered by push (the host's `onCallPush` hook, or a tapped call
  /// notification): rings it, or with [accept] joins it straight away. Returns
  /// true when the push was consumed as a call, false to let the push layer
  /// treat it as a chat push (calls off, not a call, nothing to join).
  ///
  /// A live XMPP `call-token` for the same call is then ignored as a
  /// duplicate. A LiveKit push carries a one-minute join token, so it can only
  /// be answered while that is valid; a p2p push carries none and the caller
  /// re-sends its offer until it is answered.
  bool handleCallPush(Map<String, dynamic> data, {bool accept = false}) {
    if (_disposed || !enabled || !looksLikeCallPush(data)) return false;
    final push = parseCallPush(data);
    final callId = push.callId;
    if (callId == null) return false;
    final isP2P = push.mode == CallMode.p2p;

    final s = _state;
    if (!s.isIdle && s.callId == callId) {
      // Already ringing / in progress (the live token came first).
      if (accept) acceptIncoming();
      return true;
    }
    if (!isP2P && push.token.isEmpty) return false;

    final roomBare = push.roomBareName;
    if (roomBare == null || roomBare.isEmpty) return false;
    final resolved = _resolveRoom(push.roomRef ?? roomBare);
    // Public rooms never call.
    if (resolved?.type == 'public') return false;
    final allowed = host.videoCalls?.allowedRoomTypes;
    final group = push.group;
    if (group ? !isCallRoomTypeAllowed('group', allowed) : false) return false;
    if (!group &&
        resolved?.type != null &&
        resolved?.type != 'private' &&
        (resolved?.usersCnt ?? 0) > 2) {
      return false;
    }
    if (!group &&
        resolved?.type == 'private' &&
        !isCallRoomTypeAllowed('private', allowed)) {
      return false;
    }

    if (!s.isIdle) {
      // Another call is in progress.
      final decision = decideIncomingWhileBusy(
        s.toBusySnapshot(),
        mode: push.mode,
        callId: callId,
        roomBareName: roomBare,
      );
      if (decision == IncomingWhileBusy.busy && isP2P) {
        api.reportDeclined(callId);
      }
      return true;
    }

    if (isCallTokenExpired(push.exp, nowMs: _now())) {
      if (accept) {
        _set(
          CallSessionState.incoming(
            roomJid: resolved?.jid ?? _roomJidFor(push.roomRef, roomBare),
            roomName: push.callerName,
            roomBareName: roomBare,
            token: push.token,
            callId: callId,
            mode: push.mode,
            nowMs: _now(),
          ).withError('The call has already ended', _now()),
        );
      }
      return true;
    }

    final peer = group
        ? null
        : (push.callerXmppUsername ??
            derivePeerXmppUsername(roomBare, host.selfXmppUsername));
    final title = (resolved?.title ?? '').trim();
    final String name;
    if (group) {
      name = title.isNotEmpty ? title : roomBare;
    } else if (push.callerName.isNotEmpty) {
      name = push.callerName;
    } else {
      final known = _lookupUserName(peer);
      name = known.isNotEmpty ? known : title;
    }
    _set(
      CallSessionState.incoming(
        roomJid: resolved?.jid ?? _roomJidFor(push.roomRef, roomBare),
        roomName: name,
        roomBareName: roomBare,
        token: push.token,
        kind: push.kind,
        callId: callId,
        peerXmppUsername: peer,
        mode: push.mode,
        isGroup: group,
        livekitUrl: push.livekitUrl,
        callerName: push.callerName,
        callerXmppUsername: push.callerXmppUsername,
        nowMs: _now(),
      ),
    );
    if (accept) acceptIncoming();
    return true;
  }

  String _roomJidFor(String? roomRef, String bare) {
    if (roomRef != null && roomRef.contains('@')) {
      return roomRef.split('/').first;
    }
    final conference = host.conferenceDomain.trim();
    return '$bare@${conference.isEmpty ? 'conference.${host.xmppDomain}' : conference}';
  }

  void _onNativeAccept(String callId, Map<String, dynamic> extra) {
    final s = _state;
    if (!s.isIdle && s.callId == callId) {
      if (s.isRingingIncoming) acceptIncoming();
      return;
    }
    if (s.isIdle) handleCallPush(extra, accept: true);
  }

  void _onNativeDecline(String callId, Map<String, dynamic> extra) {
    final s = _state;
    if (!s.isIdle && s.callId == callId) {
      if (s.isRingingIncoming) declineIncoming();
      return;
    }
    // A push-only ring declined before the app had the call: tell the server
    // (p2p; the LiveKit room needs no decline) so the caller stops waiting.
    if (s.isIdle && looksLikeCallPush(extra)) {
      final push = parseCallPush(extra);
      if (push.mode == CallMode.p2p) api.reportDeclined(push.callId ?? callId);
    }
  }

  void _onNativeEnded(String callId) {
    final s = _state;
    if (!s.isIdle && s.callId == callId) hangup();
  }

  void _onNativeTimeout(String callId) {
    final s = _state;
    if (s.isRingingIncoming && s.callId == callId) _endCall();
  }

  void _onNativeRestored(Map<String, dynamic> extra) {
    if (_state.isIdle) handleCallPush(extra);
  }

  // ---- runtime sync -------------------------------------------------------

  /// Reconciles the media runtimes and timers with the state. Re-entrant
  /// calls (a runtime event that changes the state while we are syncing) are
  /// folded into one more pass.
  void _sync() {
    if (_syncing) {
      _resync = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _resync = false;
        _syncOnce();
      } while (_resync && !_disposed);
    } finally {
      _syncing = false;
    }
  }

  void _syncOnce() {
    final s = _state;
    final cfg = host.videoCalls;
    final on = cfg?.enabled == true;

    // Dial timeout: stop the dial UI sitting forever when no call-token is
    // ever broadcast (offline peer, backend error).
    final dialing = s.phase == CallPhase.requesting && s.isOutgoing;
    if (!dialing) {
      _dialTimer?.cancel();
      _dialTimer = null;
      _dialTimerFor = null;
    } else if (_dialTimerFor != s.startedAt) {
      _dialTimer?.cancel();
      _dialTimerFor = s.startedAt;
      final startedAt = s.startedAt;
      _dialTimer = Timer(outgoingTimeout, () {
        _dialTimer = null;
        final now = _state;
        if (_disposed ||
            now.phase != CallPhase.requesting ||
            !now.isOutgoing ||
            now.startedAt != startedAt) {
          return;
        }
        // A p2p callee has no server-driven timeout to dismiss its ring, so
        // the caller cancels explicitly.
        if (now.mode == CallMode.p2p) {
          _sendCurrentCallState(CallSignalState.cancelled);
        }
        _set(now.withError('No answer - call timed out', _now()));
      });
    }

    // An incoming ring that outlives its call dismisses itself.
    if (!s.isRingingIncoming) {
      _ringTimer?.cancel();
      _ringTimer = null;
      _ringTimerFor = null;
    } else if (_ringTimerFor != s.startedAt) {
      _ringTimer?.cancel();
      _ringTimerFor = s.startedAt;
      final startedAt = s.startedAt;
      _ringTimer = Timer(incomingRingTimeout, () {
        _ringTimer = null;
        final now = _state;
        if (_disposed || !now.isRingingIncoming || now.startedAt != startedAt) {
          return;
        }
        _endCall();
      });
    }

    _syncP2p(s, on, cfg);
    _syncLivekit(s, on, cfg);
  }

  void _syncP2p(CallSessionState s, bool on, VideoCallsConfig? cfg) {
    final incoming = s.isIncoming;
    final wants = on &&
        s.mode == CallMode.p2p &&
        (s.callId ?? '').isNotEmpty &&
        (incoming
            ? (s.phase == CallPhase.ringingIncoming ||
                s.phase == CallPhase.connecting ||
                s.phase == CallPhase.inCall)
            : s.isOutgoing &&
                s.iceServers != null &&
                (s.phase == CallPhase.requesting ||
                    s.phase == CallPhase.connecting ||
                    s.phase == CallPhase.inCall));
    // The callee waits on the ring screen; everyone else starts right away.
    final shouldStart =
        wants && !(incoming && s.phase == CallPhase.ringingIncoming);

    if (!wants) {
      _disposeP2p();
    } else {
      if (_p2pCallId != s.callId) {
        _disposeP2p();
        _createP2p(s, cfg);
      }
      if (shouldStart) {
        final controller = _p2p;
        if (controller != null) unawaited(controller.start());
      }
    }

    // Callee: the incoming UI is on screen, let the server (and so the
    // caller) know the phone is ringing. Once per call.
    if (on &&
        s.mode == CallMode.p2p &&
        incoming &&
        s.phase == CallPhase.ringingIncoming &&
        (s.callId ?? '').isNotEmpty &&
        _ringingReportedFor != s.callId) {
      _ringingReportedFor = s.callId;
      api.reportRinging(s.callId);
    }
  }

  void _createP2p(CallSessionState s, VideoCallsConfig? cfg) {
    final callId = s.callId!;
    final peer = (s.peerXmppUsername ?? '').trim();
    if (peer.isEmpty) {
      // Without the peer's address there is nobody to signal.
      _set(s.withError('Cannot reach the other participant', _now()));
      return;
    }
    final role = s.isIncoming ? P2PRole.callee : P2PRole.caller;
    final deps = _p2pDeps(
      fetchIce: api.fetchIceServers,
      sendSignal: (signal, payload) =>
          _sendP2pSignal(peer, callId, signal, payload),
      log: host.log,
    );
    final controller = P2PCallController(
      params: P2PCallParams(
        callId: callId,
        role: role,
        kind: s.kind,
        peerLocal: localPart(peer),
        iceServers: s.iceServers ?? const <IceServerConfig>[],
        startWithMicOn: cfg?.startWithMicOn ?? true,
        startWithCameraOn: cfg?.startWithCameraOn ?? true,
      ),
      deps: deps,
      scheduler: _scheduler,
      events: P2PCallEvents(
        onNegotiated: () {
          if (role == P2PRole.caller &&
              _isCurrentCall(callId) &&
              _state.phase == CallPhase.requesting) {
            _set(_state.copyWith(phase: CallPhase.connecting));
          }
        },
        onConnected: () {
          if (!_isCurrentCall(callId)) return;
          _set(_state.connected(_now()));
          // One side is enough to start the server-side call timer.
          if (role == P2PRole.caller) api.reportConnected(callId);
        },
        onRemoteEnd: (reason) {
          if (!_isCurrentCall(callId)) return;
          final notice = remoteEndNotice(reason);
          if (notice != null) {
            _set(_state.withError(notice, _now()));
          } else {
            _endCall();
          }
        },
        onFailed: (message) {
          if (_isCurrentCall(callId)) _set(_state.withError(message, _now()));
        },
        // Whatever ended it, tell the server the call is over (idempotent, so
        // it does not matter that the peer reports it too). A callee that
        // never accepted ends through the decline report instead.
        onDisposed: ({required bool started}) {
          if (started) api.reportEnded(callId);
        },
      ),
    );
    _p2p = controller;
    _p2pCallId = callId;
    _p2pDetach = inbox.attach(callId, controller.receive);
    // The controller changes (and fires events) outside our state, e.g. the
    // media status the screens show, so repaint on its changes too.
    controller.subscribe(_onMediaChanged);
  }

  void _sendP2pSignal(
    String peer,
    String callId,
    P2PSignalName signal,
    P2PSignalPayload payload,
  ) {
    final ok = host.sendStanza(
      buildP2PSignalStanza(
        to: _toBareJid(peer),
        callId: callId,
        signal: signal,
        payload: payload,
      ),
    );
    if (!ok) host.log('[p2p] failed to send ${signal.name} signal');
  }

  void _disposeP2p() {
    final controller = _p2p;
    final detach = _p2pDetach;
    _p2p = null;
    _p2pCallId = null;
    _p2pDetach = null;
    detach?.call();
    controller?.dispose();
  }

  void _syncLivekit(CallSessionState s, bool on, VideoCallsConfig? cfg) {
    final sessionPhase =
        s.phase == CallPhase.connecting || s.phase == CallPhase.inCall;
    final token = s.token ?? '';
    final wants =
        on && s.mode == CallMode.livekit && token.isNotEmpty && sessionPhase;
    if (!wants) {
      _disposeLk();
      return;
    }
    // The server's own URL (token stanza / create response) wins over config.
    final url = (s.livekitUrl ?? cfg?.livekitUrl ?? '').trim();
    if (url.isEmpty) {
      _set(s.withError(
        'Video calls unavailable: missing livekitUrl in config.videoCalls',
        _now(),
      ));
      return;
    }
    final key = '${s.callId ?? ''}|$token|$url';
    if (_lkKey == key) return;
    _disposeLk();
    final callKey = key;
    final session = _livekit(
      LiveKitSessionParams(
        url: url,
        token: token,
        kind: s.kind,
        isGroup: s.isGroup,
        startWithMicOn: cfg?.startWithMicOn ?? true,
        startWithCameraOn: cfg?.startWithCameraOn ?? true,
      ),
      LiveKitSessionEvents(
        onConnected: () {
          if (_lkKey != callKey) return;
          _set(_state.connected(_now()));
        },
        onError: (message) {
          if (_lkKey != callKey) return;
          _set(_state.withError(message, _now()));
        },
        onPeerLeft: () {
          if (_lkKey != callKey) return;
          // A 1:1 call is over when the one remote peer leaves: end locally
          // instead of waiting for a signal that may never arrive.
          _sendCurrentCallState(CallSignalState.ended);
          _endCall();
        },
      ),
    );
    _lk = session;
    _lkKey = key;
    session.subscribe(_onMediaChanged);
    unawaited(session.connect());
  }

  void _disposeLk() {
    final session = _lk;
    _lk = null;
    _lkKey = null;
    if (session != null) unawaited(session.dispose());
  }
}
