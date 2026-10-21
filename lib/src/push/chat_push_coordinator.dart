import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/chat_component_state.dart';
import '../models/chat_component_config.dart';
import '../networking/api_client.dart';
import '../networking/xmpp_client.dart';
import 'push_api.dart';
import 'push_payload.dart';
import 'push_registration.dart';
import 'push_storage.dart';
import 'push_subscription_service.dart';

/// Host hook for call pushes. Return true when the payload was consumed
/// (the SDK then does not open a room for it).
typedef CallPushHandler = bool Function(Map<String, dynamic> data);

/// Ties push registration, MucSub subscriptions and tapped-push handling to
/// the controller's session. Owned by the controller; the host reaches it
/// through the controller's push methods.
class ChatPushCoordinator {
  ChatPushCoordinator({
    required this.config,
    required ApiClient apiClient,
    required ValueListenable<ChatComponentState> state,
    required XmppClient? Function() xmpp,
    required Future<void> Function(String roomJid) selectRoom,
    PushStorage? storage,
    http.Client? gatewayClient,
    DateTime Function()? now,
    void Function(String message)? log,
  })  : _apiClient = apiClient,
        _state = state,
        _xmpp = xmpp,
        _selectRoom = selectRoom,
        _storage = storage ?? const SharedPreferencesPushStorage(),
        _now = now ?? DateTime.now,
        _log = log ?? ((_) {}) {
    manager = PushRegistrationManager(
      api: PushApi(apiClient: apiClient, gatewayClient: gatewayClient),
      readSession: _readSession,
      storage: _storage,
      log: _log,
      tokenHook: config.pushNotifications?.getPushTokens,
    );
    subscriptions = PushSubscriptionService(storage: _storage);
  }

  final ChatComponentConfig config;
  final ApiClient _apiClient;
  final ValueListenable<ChatComponentState> _state;
  final XmppClient? Function() _xmpp;
  final Future<void> Function(String roomJid) _selectRoom;
  final PushStorage _storage;
  final DateTime Function() _now;
  final void Function(String message) _log;

  late final PushRegistrationManager manager;
  late final PushSubscriptionService subscriptions;

  /// Set by the host (or the calls module) to receive call pushes.
  CallPushHandler? onCallPush;

  String? _pendingRoomJid;
  Set<String> _knownRooms = <String>{};
  bool _watching = false;

  PushNotificationsConfig? get _push => config.pushNotifications;

  /// True when push is in use (the host configured it, or handed over a
  /// token) and not switched off by `pushNotifications.enabled: false`.
  bool get isConfigured =>
      _push?.enabled != false && (_push != null || manager.tokens.isNotEmpty);

  /// Asks `pushNotifications.getPushTokens` again and registers the result.
  Future<void> refreshPushTokens() => manager.refreshFromHook();

  Future<PushSession> _readSession() async {
    final user = _state.value.user;
    final token = await _apiClient.readAccessToken() ?? '';
    return PushSession(
      authToken: token,
      appId: (config.appId ?? user?.appId ?? '').trim(),
      xmppUsername:
          (user?.xmppUsername ?? user?.walletAddress ?? user?.username ?? '')
              .trim(),
      xmppHost: config.xmppSettings?.host ?? '',
      projectName: (_push?.projectName ?? '').trim(),
      gatewayUrl: (_push?.apiUrl ?? '').trim(),
      configEnabled: _push?.enabled != false,
    );
  }

  Future<RegisterPushOutcome> registerPushToken(
    String token, {
    PushTokenType? tokenType,
  }) {
    return manager.register(token, tokenType: tokenType);
  }

  Future<UnregisterPushOutcome> unregisterPushToken({
    PushTokenType? tokenType,
  }) {
    return manager.unregister(tokenType: tokenType);
  }

  /// Logout: release the device on the server and drop the MucSub memory.
  /// Awaited FIRST by the logout order; never throws.
  Future<void> releaseOnLogout() async {
    try {
      await manager.releaseAndForget();
    } catch (error) {
      _log('push: release on logout failed: $error');
    }
    try {
      await subscriptions.reset();
    } catch (_) {
      // Best effort.
    }
    _knownRooms = <String>{};
    _pendingRoomJid = null;
    try {
      await _storage.remove(kPendingNotificationJidKey);
    } catch (_) {
      // Best effort.
    }
  }

  /// Called once XMPP is up and the rooms are loaded: registers held tokens,
  /// subscribes every room and starts watching for new rooms.
  Future<void> onRuntimeReady() async {
    await manager.loadPreferences();
    if (!_watching) {
      _watching = true;
      _state.addListener(_onStateChanged);
    }
    unawaited(manager.syncHeldTokens());
    await _subscribeRooms();
    await _applyPendingRoom();
  }

  /// After a socket reconnect: MucSub survives on the server, so only rooms
  /// not remembered are subscribed.
  Future<void> onReconnected() async {
    await manager.syncHeldTokens();
    await _subscribeRooms();
  }

  void dispose() {
    if (_watching) {
      _watching = false;
      _state.removeListener(_onStateChanged);
    }
  }

  /// MucSub is unconditional like web and RN: every room is subscribed so
  /// the push server sees its messages. Only an explicit
  /// `pushNotifications.enabled: false` or the user's own switch turns it off.
  bool get _mucSubWanted => _push?.enabled != false && manager.userEnabled;

  Set<String> _roomJids() => _state.value.rooms
      .map((room) => room.jid.trim())
      .where((jid) => jid.isNotEmpty)
      .toSet();

  Future<void> _subscribeRooms([Iterable<String>? only]) async {
    if (!_mucSubWanted) return;
    final xmpp = _xmpp();
    if (xmpp == null || xmpp.state != ChatConnectionState.online) return;
    final jids = only ?? _roomJids();
    if (jids.isEmpty) return;
    try {
      final done = await subscriptions.subscribeClientToRooms(xmpp, jids);
      if (done > 0) _log('push: MucSub subscribed $done room(s)');
    } catch (error) {
      _log('push: MucSub subscribe failed: $error');
    }
  }

  /// A room that turned up after bootstrap (created here, an invite, the
  /// room list after a reconnect) gets its push subscription too.
  Future<void> subscribeRoomForPush(String roomJid) =>
      _subscribeRooms(<String>[roomJid]);

  List<dynamic>? _lastRoomsList;

  void _onStateChanged() {
    final roomsList = _state.value.rooms;
    if (identical(roomsList, _lastRoomsList)) return;
    _lastRoomsList = roomsList;
    final rooms = _roomJids();
    final added = rooms.difference(_knownRooms);
    _knownRooms = rooms;
    if (added.isNotEmpty && _mucSubWanted) {
      unawaited(_subscribeRooms(added));
    }
    final pending = _pendingRoomJid;
    if (pending != null && _hasRoom(pending)) {
      _pendingRoomJid = null;
      unawaited(_openAndClear(pending));
    }
  }

  bool _hasRoom(String jid) {
    final wanted = jid.toLowerCase();
    return _state.value.rooms.any((room) => room.jid.toLowerCase() == wanted);
  }

  /// Opens the room a tapped push pointed at, or keeps it pending (5 min)
  /// until the room list has it. The host calls this from its notification
  /// tap handler with the push `data` map.
  Future<PushPayloadOutcome> handlePushPayload(
    Map<String, dynamic>? data,
  ) async {
    if (data == null || data.isEmpty) return PushPayloadOutcome.unknown;
    if (isCallPush(data) && (onCallPush?.call(data) ?? false)) {
      return PushPayloadOutcome.call;
    }
    final jid = pushRoomJid(data);
    if (jid == null) return PushPayloadOutcome.unknown;
    return openRoomFromPush(jid);
  }

  Future<PushPayloadOutcome> openRoomFromPush(String jid) async {
    final full = normalizePushRoomJid(jid, config.xmppSettings?.conference);
    try {
      await _storage.write(
        kPendingNotificationJidKey,
        encodePendingJid(full, _now()),
      );
    } catch (_) {
      // Memory copy below still works for this process.
    }
    if (_hasRoom(full)) {
      _pendingRoomJid = null;
      await _openAndClear(full);
      return PushPayloadOutcome.room;
    }
    _pendingRoomJid = full;
    return PushPayloadOutcome.pending;
  }

  String _canonicalRoom(String jid) {
    final wanted = jid.toLowerCase();
    return _state.value.rooms
        .firstWhere((room) => room.jid.toLowerCase() == wanted)
        .jid;
  }

  Future<void> _clearPendingStorage() async {
    try {
      await _storage.remove(kPendingNotificationJidKey);
    } catch (_) {
      // Best effort.
    }
  }

  /// The pending room, from memory or (after a cold start) from storage.
  Future<String?> readPendingRoom() async {
    final inMemory = _pendingRoomJid;
    if (inMemory != null) return inMemory;
    try {
      return decodePendingJid(
        await _storage.read(kPendingNotificationJidKey),
        _now(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _applyPendingRoom() async {
    final pending = await readPendingRoom();
    if (pending == null) return;
    if (!_hasRoom(pending)) {
      _pendingRoomJid = pending;
      return;
    }
    _pendingRoomJid = null;
    await _openAndClear(pending);
  }

  Future<void> _openAndClear(String jid) async {
    await _clearPendingStorage();
    await _selectRoom(_canonicalRoom(jid));
  }
}
