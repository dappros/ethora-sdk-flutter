import 'dart:async';

import '../models/chat_component_config.dart';
import 'push_api.dart';
import 'push_storage.dart';

/// Everything registration needs to know about the signed-in user and the
/// SDK config, read fresh before each attempt.
class PushSession {
  const PushSession({
    required this.authToken,
    required this.appId,
    required this.xmppUsername,
    required this.xmppHost,
    required this.projectName,
    required this.gatewayUrl,
    required this.configEnabled,
  });

  final String authToken;
  final String appId;
  final String xmppUsername;
  final String xmppHost;
  final String projectName;
  final String gatewayUrl;

  /// `pushNotifications.enabled` (false switches push off for the host).
  final bool configEnabled;

  bool get isGateway => gatewayUrl.isNotEmpty;

  /// Signed in and carrying what the chosen path needs.
  bool get isReady =>
      authToken.isNotEmpty &&
      (isGateway
          ? xmppUsername.isNotEmpty && projectName.isNotEmpty
          : appId.isNotEmpty);
}

class RegisteredPushToken {
  const RegisteredPushToken(this.token, this.tokenType);

  final String token;
  final PushTokenType tokenType;
}

enum RegisterPushOutcome { registered, deferred, disabled }

enum UnregisterPushOutcome { unregistered, forgotten }

class _ServerRegistration {
  _ServerRegistration({
    required this.token,
    required this.appId,
    required this.xmppUsername,
    required this.gateway,
  });

  final RegisteredPushToken token;
  final String appId;
  final String xmppUsername;
  final bool gateway;
}

/// Registration state machine with two slots, `chat` and `voip` (RN
/// `pushRegistration.ts`). The host hands tokens over with [register]; they
/// are held in memory and registered whenever a session is ready, so a token
/// that arrives before sign-in is not lost.
class PushRegistrationManager {
  PushRegistrationManager({
    required PushApi api,
    required Future<PushSession> Function() readSession,
    PushStorage? storage,
    void Function(String message)? log,
    this.tokenHook,
    DateTime Function()? now,
  })  : _api = api,
        _readSession = readSession,
        _storage = storage ?? const SharedPreferencesPushStorage(),
        _log = log ?? ((_) {}),
        _now = now ?? DateTime.now;

  /// `pushNotifications.getPushTokens`. Runs once per account once a session
  /// is ready, and again on [refreshFromHook].
  final Future<List<PushTokenRegistration>> Function()? tokenHook;
  final DateTime Function() _now;
  String? _hookIdentity;
  DateTime? _hookFailedAt;

  /// A failed hook is not retried sooner than this.
  static const Duration hookRetryDelay = Duration(seconds: 30);

  final PushApi _api;
  final Future<PushSession> Function() _readSession;
  final PushStorage _storage;
  final void Function(String message) _log;

  final Map<PushSlot, RegisteredPushToken> _held =
      <PushSlot, RegisteredPushToken>{};
  final Map<PushSlot, _ServerRegistration> _registered =
      <PushSlot, _ServerRegistration>{};
  Future<void>? _inflight;
  bool _userEnabled = true;
  bool _prefsLoaded = false;

  /// The user's own push switch (Settings toggle). Persisted.
  bool get userEnabled => _userEnabled;

  Future<void> loadPreferences() async {
    if (_prefsLoaded) return;
    try {
      _userEnabled = (await _storage.read(kPushEnabledKey)) != 'false';
    } catch (_) {
      _userEnabled = true;
    }
    _prefsLoaded = true;
  }

  bool _isDisabled(PushSession session) =>
      !session.configEnabled || !_userEnabled;

  /// Tokens the host handed over, chat slot first.
  List<RegisteredPushToken> get tokens => <RegisteredPushToken>[
        for (final slot in PushSlot.values)
          if (_held[slot] != null) _held[slot]!,
      ];

  /// True when something is registered on the server right now.
  bool get hasServerRegistration => _registered.isNotEmpty;

  bool _same(
    RegisteredPushToken token,
    _ServerRegistration? current,
    PushSession session,
  ) =>
      current != null &&
      current.token.token == token.token &&
      current.token.tokenType == token.tokenType &&
      current.gateway == session.isGateway &&
      current.appId == session.appId &&
      current.xmppUsername == session.xmppUsername;

  List<PushSlot> _slotsNeedingRegistration(PushSession session) => <PushSlot>[
        for (final slot in PushSlot.values)
          if (_held[slot] != null &&
              !_same(_held[slot]!, _registered[slot], session))
            slot,
      ];

  /// Hands a device token to the SDK. Registers now when a session exists,
  /// otherwise keeps it until sign-in. Throws [PushRegistrationError] when
  /// the backend refuses it.
  Future<RegisterPushOutcome> register(
    String token, {
    PushTokenType? tokenType,
  }) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError(
          'registerPushToken: token must be a non-empty string');
    }
    await loadPreferences();
    final type = tokenType ?? detectPushTokenType(trimmed);
    _held[type.slot] = RegisteredPushToken(trimmed, type);

    final session = await _readSession();
    if (_isDisabled(session)) return RegisterPushOutcome.disabled;
    if (!session.isReady) return RegisterPushOutcome.deferred;
    await _registerNow();
    return RegisterPushOutcome.registered;
  }

  /// Registers whatever is held, when a session is ready. For the controller
  /// after sign-in and on reconnect. Never throws.
  Future<void> syncHeldTokens() async {
    await loadPreferences();
    try {
      final session = await _readSession();
      if (_isDisabled(session) || !session.isReady) return;
      await _runTokenHook(session);
      if (_slotsNeedingRegistration(session).isEmpty) return;
      await _registerNow();
    } catch (error) {
      _log('push: deferred token registration failed: $error');
    }
  }

  /// Asks `getPushTokens` again and registers what it returns (for example
  /// after the OS rotated the token). Does nothing without a hook or a ready
  /// session. A refused registration throws [PushRegistrationError].
  Future<void> refreshFromHook() async {
    await loadPreferences();
    if (tokenHook == null) return;
    final session = await _readSession();
    if (_isDisabled(session) || !session.isReady) return;
    await _runTokenHook(session, force: true);
    if (_slotsNeedingRegistration(session).isNotEmpty) await _registerNow();
  }

  Future<void> _runTokenHook(PushSession session, {bool force = false}) async {
    final hook = tokenHook;
    if (hook == null) return;
    final identity =
        session.xmppUsername.isNotEmpty ? session.xmppUsername : session.appId;
    if (identity.isEmpty) return;
    if (!force) {
      if (_hookIdentity == identity) return;
      final failedAt = _hookFailedAt;
      if (failedAt != null && _now().difference(failedAt) < hookRetryDelay) {
        return;
      }
    }
    _hookIdentity = identity;
    try {
      for (final entry in await hook()) {
        final token = entry.token.trim();
        if (token.isEmpty) continue;
        final type = entry.tokenType ?? detectPushTokenType(token);
        _held[type.slot] = RegisteredPushToken(token, type);
      }
      _hookFailedAt = null;
    } catch (error) {
      _hookIdentity = null;
      _hookFailedAt = _now();
      _log('push: getPushTokens failed; will retry: $error');
    }
  }

  Future<void> _registerNow() {
    final inflight = _inflight;
    if (inflight != null) return inflight;
    final run = _run().whenComplete(() => _inflight = null);
    _inflight = run;
    return run;
  }

  Future<void> _run() async {
    final session = await _readSession();
    if (_isDisabled(session) || session.authToken.isEmpty) return;
    if (session.isGateway && session.xmppUsername.isEmpty) return;
    for (final slot in _slotsNeedingRegistration(session)) {
      final token = _held[slot]!;
      final previous = _registered[slot];
      if (previous != null && previous.xmppUsername == session.xmppUsername) {
        // The slot held an older token for this same user: release it.
        _registered.remove(slot);
        try {
          await _releaseOnServer(previous);
        } catch (error) {
          _log('push: releasing the replaced token failed: $error');
        }
      }
      await _registerOne(token, session);
    }
  }

  Future<void> _registerOne(
    RegisteredPushToken token,
    PushSession session,
  ) async {
    if (session.isGateway) {
      if (session.projectName.isEmpty) {
        throw PushRegistrationError(
          'registerPushToken: pushNotifications.projectName is required when '
          'pushNotifications.apiUrl points at a push gateway.',
        );
      }
      await _api.subscribeToGateway(
        apiUrl: session.gatewayUrl,
        authToken: session.authToken,
        projectName: session.projectName,
        token: token.token,
        xmppUser: session.xmppUsername,
        xmppHost: session.xmppHost,
      );
    } else {
      if (session.appId.isEmpty) {
        throw PushRegistrationError(
          'registerPushToken: an app id is required. Set config.appId or '
          'sign in with a user that carries one.',
        );
      }
      await _api.register(
        appId: session.appId,
        token: token.token,
        tokenType: token.tokenType,
      );
    }
    _registered[token.tokenType.slot] = _ServerRegistration(
      token: token,
      appId: session.appId,
      xmppUsername: session.xmppUsername,
      gateway: session.isGateway,
    );
    _log(
      'push: ${token.tokenType.wire} token registered'
      '${session.isGateway ? ' (gateway)' : ' for app ${session.appId}'}',
    );
  }

  Future<void> _releaseOnServer(_ServerRegistration entry) async {
    // The gateway has no unsubscribe call.
    if (entry.gateway) return;
    await _api.unregister(appId: entry.appId, token: entry.token.token);
  }

  /// Takes the device off the backend without forgetting the held tokens
  /// (logout, or the user switched push off). Awaited by the caller; every
  /// failure is logged and swallowed so logout never stalls on it.
  Future<void> release() async {
    final current = _registered.values.toList();
    _registered.clear();
    if (current.isEmpty) return;
    await Future.wait(
      current.map(
        (entry) => _releaseOnServer(entry).then<void>((_) {
          _log('push: ${entry.token.tokenType.wire} token released');
        }).catchError((Object error) {
          _log('push: releasing the token failed: $error');
        }),
      ),
    );
  }

  /// Forgets the held tokens too (logout): the next user must not inherit
  /// this device's registration.
  Future<void> releaseAndForget() async {
    await release();
    _held.clear();
    _hookIdentity = null;
  }

  /// Host asked to stop: forgets the token(s) and removes them from the
  /// server. Throws [PushRegistrationError] when the server call fails.
  Future<UnregisterPushOutcome> unregister({PushTokenType? tokenType}) async {
    final slots =
        tokenType == null ? PushSlot.values : <PushSlot>[tokenType.slot];
    final toRelease = <_ServerRegistration>[];
    for (final slot in slots) {
      _held.remove(slot);
      final current = _registered.remove(slot);
      if (current != null) toRelease.add(current);
    }
    final removable = toRelease.where((entry) => !entry.gateway).toList();
    if (removable.isEmpty) return UnregisterPushOutcome.forgotten;
    final session = await _readSession();
    if (session.authToken.isEmpty) {
      _log(
        'push: unregisterPushToken called without a session; '
        'the backend still holds the token',
      );
      return UnregisterPushOutcome.forgotten;
    }
    final results = await Future.wait(
      removable.map(
        (entry) => _releaseOnServer(entry)
            .then<Object?>((_) => null)
            .catchError((Object error) => error),
      ),
    );
    final failure = results.whereType<Object>().firstOrNull;
    if (failure != null) throw failure;
    return UnregisterPushOutcome.unregistered;
  }

  /// The user's Settings toggle. Off: take the device off the backend but
  /// keep the tokens, so switching back on re-registers by itself.
  Future<void> setUserEnabled(bool enabled) async {
    await loadPreferences();
    _userEnabled = enabled;
    try {
      await _storage.write(kPushEnabledKey, enabled ? 'true' : 'false');
    } catch (_) {
      // Best effort: the in-memory switch still applies.
    }
    if (!enabled) {
      await release();
    } else {
      await syncHeldTokens();
    }
  }
}
