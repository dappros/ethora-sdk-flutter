import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/chat_component_config.dart';

/// Single refresh-token rotation point, ported from web `authRefresh.ts`.
///
/// The backend rotates refresh tokens with reuse detection: every successful
/// `POST /v1/users/login/refresh` burns the presented token and issues a new
/// one, and presenting a burned token looks like theft. That puts three
/// obligations on the client:
///
///  1. Persist the NEW refresh token from every response before returning.
///  2. Never rotate concurrently (one shared in-flight call).
///  3. Route every refresh through here.
///
/// Callers must also stop treating a 401 as "log out": two of the four refresh
/// error codes are race signals. Only [RefreshFatalError] means the session
/// is dead.

/// Refresh error codes the backend answers with (HTTP 401).
enum RefreshErrorCode {
  inProgress('REFRESH_IN_PROGRESS'),
  alreadyRotated('REFRESH_TOKEN_ALREADY_ROTATED'),
  reuseDetected('REFRESH_TOKEN_REUSE_DETECTED'),
  notFound('REFRESH_TOKEN_NOT_FOUND');

  const RefreshErrorCode(this.wire);

  /// The code as it appears on the wire.
  final String wire;
}

/// The session is genuinely dead: the caller must log the user out. Any
/// other error from this module (network, 5xx, a plain 401) must NOT log out.
class RefreshFatalError implements Exception {
  RefreshFatalError(this.code, [String? message])
      : message = message ?? 'Refresh failed: ${code.wire}';

  final RefreshErrorCode code;
  final String message;

  @override
  String toString() => 'RefreshFatalError($message)';
}

/// The refresh endpoint answered with a non-2xx status that is not one of the
/// fatal codes. Passed through untouched.
class RefreshHttpException implements Exception {
  RefreshHttpException(this.statusCode, this.body, [this.headers = const {}]);

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  RefreshErrorCode? get code =>
      parseRefreshErrorCode(body: body, headers: headers);

  @override
  String toString() => 'Refresh failed with HTTP $statusCode: $body';
}

/// A token pair as the refresh flow handles it. [token] and [refreshToken]
/// are both required; [fileToken] and [xmppPassword] ride along when present.
class AuthTokens {
  const AuthTokens({
    required this.token,
    required this.refreshToken,
    this.fileToken,
    this.xmppPassword,
  });

  final String token;
  final String refreshToken;
  final String? fileToken;
  final String? xmppPassword;
}

/// Reads the error code from every shape the API has used: body `code`,
/// `error.code`, `errors[0].code`, `error`, `message`, then the
/// `x-error-code` header. The first known code wins.
RefreshErrorCode? parseRefreshErrorCode({
  String body = '',
  Map<String, String> headers = const <String, String>{},
}) {
  final candidates = <Object?>[];
  try {
    final data = jsonDecode(body);
    if (data is Map) {
      candidates.add(data['code']);
      final error = data['error'];
      if (error is Map) candidates.add(error['code']);
      final errors = data['errors'];
      if (errors is List && errors.isNotEmpty && errors.first is Map) {
        candidates.add((errors.first as Map)['code']);
      }
      candidates.add(error);
      candidates.add(data['message']);
    } else if (data is String) {
      candidates.add(data);
    }
  } catch (_) {
    candidates.add(body);
  }
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'x-error-code') candidates.add(entry.value);
  }
  for (final candidate in candidates) {
    if (candidate is! String) continue;
    for (final code in RefreshErrorCode.values) {
      if (candidate.contains(code.wire)) return code;
    }
  }
  return null;
}

/// Expiry of a JWT (`exp` claim) in epoch milliseconds, or null when [jwt]
/// is not a JWT or carries no `exp`.
int? jwtExpiryMs(String? jwt) {
  if (jwt == null || jwt.isEmpty) return null;
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    final payload =
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return null;
    final exp = decoded['exp'];
    if (exp is num) return (exp * 1000).round();
    if (exp is String) {
      final parsed = num.tryParse(exp);
      if (parsed != null) return (parsed * 1000).round();
    }
  } catch (_) {
    // Not a JWT.
  }
  return null;
}

/// True when [jwt] has an `exp` that is already past or within [skew] of
/// [now]. Opaque tokens (no `exp`) never need a proactive refresh.
bool jwtNeedsRefresh(
  String? jwt, {
  Duration skew = kProactiveRefreshSkew,
  DateTime? now,
}) {
  final exp = jwtExpiryMs(jwt);
  if (exp == null) return false;
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return exp - skew.inMilliseconds <= nowMs;
}

/// How long before `exp` the access token is rotated.
const Duration kProactiveRefreshSkew = Duration(seconds: 60);

/// `REFRESH_IN_PROGRESS` retry budget (backend guidance: 300 ms x 2-3).
const int kRefreshInProgressMaxAttempts = 3;
const int kRefreshInProgressBaseDelayMs = 300;
const int kRefreshInProgressJitterMs = 150;

typedef RefreshRequest = Future<http.Response> Function(String refreshToken);
typedef StoredTokensReader = Future<AuthTokens?> Function();
typedef TokensPersister = Future<void> Function(AuthTokens tokens);

class AuthRefresher {
  AuthRefresher({
    required this.readStoredTokens,
    required this.persistTokens,
    required this.postRefresh,
    this.hostRefresh,
    this.onFatal,
    this.log,
    Future<void> Function(Duration delay)? sleep,
    Random? random,
    DateTime Function()? now,
    this.skew = kProactiveRefreshSkew,
    this.minProactiveDelay = const Duration(seconds: 5),
  })  : _sleep = sleep ?? Future<void>.delayed,
        _random = random ?? Random(),
        _now = now ?? DateTime.now;

  /// The newest tokens as of RIGHT NOW (secure storage), not an in-memory
  /// copy: another isolate or the host may have rotated since.
  final StoredTokensReader readStoredTokens;

  /// Writes a rotation to durable storage. Awaited before any refresh
  /// resolves, so a crash right after cannot lose the new refresh token.
  final TokensPersister persistTokens;

  /// `POST /v1/users/login/refresh` with `Authorization: {refreshToken}`.
  final RefreshRequest postRefresh;

  /// Host-owned rotation (`config.refreshTokens.refreshFunction`). When it
  /// returns non-null it REPLACES the built-in endpoint.
  final RefreshFunction? Function()? hostRefresh;

  /// Called when a background (timer) refresh finds the session dead.
  final void Function(RefreshFatalError error)? onFatal;
  final void Function(String message)? log;
  final Duration skew;

  /// Floor for the proactive timer, so an already-late token does not spin.
  final Duration minProactiveDelay;

  final Future<void> Function(Duration delay) _sleep;
  final Random _random;
  final DateTime Function() _now;

  Future<AuthTokens>? _inflight;
  Timer? _proactiveTimer;
  bool _proactiveStopped = true;

  /// True when there is anything left to rotate.
  Future<bool> hasRotatableSession() async {
    if (hostRefresh?.call() != null) return true;
    final stored = await readStoredTokens();
    return (stored?.refreshToken ?? '').isNotEmpty;
  }

  /// Rotates the tokens. Concurrent callers share ONE request. Throws
  /// [RefreshFatalError] when the session is dead (log out) and any other
  /// error otherwise (leave the session alone).
  Future<AuthTokens> refresh() {
    final inflight = _inflight;
    if (inflight != null) return inflight;
    final run = _perform().whenComplete(() => _inflight = null);
    _inflight = run;
    return run;
  }

  /// Never throws: for call sites that only want "make sure the tokens are
  /// fresh". Unless [force], an access token that is still valid beyond the
  /// skew is returned as is without rotating.
  Future<AuthTokens?> refreshQuietly({bool force = false}) async {
    try {
      if (!force) {
        final current = await readStoredTokens();
        if (current != null &&
            current.token.isNotEmpty &&
            !jwtNeedsRefresh(current.token, skew: skew, now: _now())) {
          return current;
        }
      }
      return await refresh();
    } catch (error) {
      log?.call('background refresh failed: $error');
      return null;
    }
  }

  /// Pre-request check: rotates when the access token is expired or about to
  /// be. Non-fatal failures are swallowed (the request then runs and the
  /// normal 401 path handles it); a fatal verdict is rethrown.
  Future<void> ensureFresh() async {
    final current = await readStoredTokens();
    if (current == null ||
        !jwtNeedsRefresh(current.token, skew: skew, now: _now())) {
      return;
    }
    if (!await hasRotatableSession()) return;
    try {
      await refresh();
    } on RefreshFatalError {
      rethrow;
    } catch (error) {
      log?.call('proactive refresh failed: $error');
    }
  }

  /// Arms a timer that rotates shortly before the access token's `exp`.
  /// Re-arms itself after every rotation. No-op for opaque tokens.
  Future<void> scheduleProactive() async {
    _proactiveStopped = false;
    _proactiveTimer?.cancel();
    _proactiveTimer = null;
    final current = await readStoredTokens();
    final exp = jwtExpiryMs(current?.token);
    if (_proactiveStopped || exp == null) return;
    var delay = Duration(
      milliseconds: exp - _now().millisecondsSinceEpoch - skew.inMilliseconds,
    );
    if (delay < minProactiveDelay) delay = minProactiveDelay;
    _proactiveTimer = Timer(delay, _onProactiveTimer);
  }

  void stopProactive() {
    _proactiveStopped = true;
    _proactiveTimer?.cancel();
    _proactiveTimer = null;
  }

  Future<void> _onProactiveTimer() async {
    _proactiveTimer = null;
    if (_proactiveStopped) return;
    try {
      await refresh();
    } on RefreshFatalError catch (error) {
      onFatal?.call(error);
      return;
    } catch (error) {
      log?.call('scheduled refresh failed: $error');
      if (_proactiveStopped) return;
      // Retry in a minute rather than hammering a failing endpoint.
      _proactiveTimer = Timer(const Duration(minutes: 1), _onProactiveTimer);
      return;
    }
    await scheduleProactive();
  }

  Duration _inProgressDelay(int attempt) => Duration(
        milliseconds: kRefreshInProgressBaseDelayMs * attempt +
            _random.nextInt(kRefreshInProgressJitterMs),
      );

  Future<AuthTokens> _perform() async {
    final host = hostRefresh?.call();
    if (host != null) return _runHostRefresh(host);

    for (var attempt = 1; attempt <= kRefreshInProgressMaxAttempts; attempt++) {
      final stored = await readStoredTokens();
      final presented = stored?.refreshToken ?? '';
      if (presented.isEmpty) {
        // Deliberately NOT fatal: a missing token mid-bootstrap must not
        // nuke a session that is still being hydrated.
        throw StateError('Refresh token is missing');
      }
      try {
        return await _requestRotation(presented);
      } on RefreshHttpException catch (error) {
        final code = error.code;
        if (code == RefreshErrorCode.inProgress) {
          if (attempt < kRefreshInProgressMaxAttempts) {
            await _sleep(_inProgressDelay(attempt));
            continue;
          }
          // Budget spent. Whoever holds the mutex has very likely finished
          // and written a newer token: take it if so.
          final adopted = await _adoptStoredTokens(notEqualTo: presented);
          if (adopted != null) return adopted;
          rethrow;
        }
        if (code == RefreshErrorCode.alreadyRotated) {
          // Our copy is stale. A newer stored token means a benign race.
          final adopted = await _adoptStoredTokens(notEqualTo: presented);
          if (adopted != null) return adopted;
          throw RefreshFatalError(RefreshErrorCode.alreadyRotated);
        }
        if (code == RefreshErrorCode.reuseDetected ||
            code == RefreshErrorCode.notFound) {
          throw RefreshFatalError(code!);
        }
        // Plain 401 or 5xx without a code: pass through, no logout.
        rethrow;
      }
    }
    throw StateError('Refresh attempts exhausted');
  }

  Future<AuthTokens> _requestRotation(String refreshToken) async {
    final response = await postRefresh(refreshToken);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RefreshHttpException(
        response.statusCode,
        response.body,
        response.headers,
      );
    }
    Map<String, dynamic> body = const <String, dynamic>{};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // Handled by the missing-token check below.
    }
    final token = _text(body['token']);
    final newRefresh = _text(body['refreshToken']);
    if (token == null || newRefresh == null) {
      throw StateError('Refresh response did not contain both tokens');
    }
    final result = AuthTokens(
      token: token,
      refreshToken: newRefresh,
      fileToken: _text(body['fileToken']),
      xmppPassword: _text(body['xmppPassword']),
    );
    // Persist BEFORE resolving. Every early return between here and the
    // caller is a chance to lose the rotation, so there are none.
    await persistTokens(result);
    return result;
  }

  Future<AuthTokens> _runHostRefresh(RefreshFunction refreshFunction) async {
    final refreshed = await refreshFunction();
    final access = _text(refreshed?.accessToken);
    if (refreshed == null || access == null) {
      throw StateError(
          'Custom refresh function did not return an access token');
    }
    var refreshToken = _text(refreshed.refreshToken);
    if (refreshToken == null) {
      // Not fatal (non-rotating hosts exist) but on a rotating backend this
      // keeps a burned token around.
      log?.call(
        'custom refreshFunction returned no refreshToken; keeping the stored one',
      );
      refreshToken = (await readStoredTokens())?.refreshToken ?? '';
    }
    final result = AuthTokens(
      token: access,
      refreshToken: refreshToken,
      fileToken: _text(refreshed.fileToken),
      xmppPassword: _text(refreshed.xmppPassword),
    );
    await persistTokens(result);
    return result;
  }

  /// Another writer rotated while we waited: its tokens are already stored.
  /// Returns them when they differ from [notEqualTo], else null.
  Future<AuthTokens?> _adoptStoredTokens({required String notEqualTo}) async {
    final stored = await readStoredTokens();
    if (stored == null ||
        stored.refreshToken.isEmpty ||
        stored.token.isEmpty ||
        stored.refreshToken == notEqualTo) {
      return null;
    }
    // Idempotent write: lets the controller pull the pair into memory.
    await persistTokens(stored);
    return stored;
  }

  static String? _text(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}
