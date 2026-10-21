import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_component_config.dart';
import '../core/chat_component_log.dart';
import 'auth_refresh.dart';

typedef TokenReader = Future<String?> Function();
typedef RefreshTokenReader = Future<String?> Function();
typedef TokenWriter = Future<void> Function(
    String accessToken, String? refreshToken);
typedef SessionClearer = Future<void> Function();
/// Receives the `fileToken` of a refresh response (secure media `ft`).
typedef FileTokenWriter = Future<void> Function(String fileToken);
/// Receives the `xmppPassword` of a refresh response (fresh SASL password).
typedef XmppPasswordWriter = Future<void> Function(String xmppPassword);

/// A non-2xx answer from the REST API. [statusCode] lets callers decide (for
/// example the secure-upload fallback, which must not retry a 401 or 413).
/// [reason] is the server's own message
/// when the body carries one (`message` or `error`), so the UI can show it.
class ApiException implements Exception {
  ApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  String? get reason {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final value = decoded['message'] ?? decoded['error'];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    } catch (_) {
      // Not JSON: fall through to the raw body.
    }
    final raw = body.trim();
    return raw.isEmpty ? null : raw;
  }

  @override
  String toString() => 'API error $statusCode: $body';
}

class ApiClient {
  ApiClient({
    required ChatComponentConfig config,
    required this.readAccessToken,
    required this.readRefreshToken,
    required this.writeTokens,
    required this.clearSession,
    required this.log,
    http.Client? httpClient,
    this.writeFileToken,
    this.writeXmppPassword,
    this.onRefreshFatal,
    this.hostRecovery,
  })  : _config = config,
        _httpClient = httpClient ?? http.Client() {
    auth = AuthRefresher(
      readStoredTokens: _readStoredTokens,
      persistTokens: _persistRotation,
      postRefresh: _postRefresh,
      hostRefresh: () =>
          _config.refreshTokens?.enabled == false
              ? null
              : _config.refreshTokens?.refreshFunction,
      onFatal: (error) => unawaited(_onTimerFatal(error)),
      log: (message) => log(
        ChatLogEvent(
          level: ChatLogLevel.info,
          category: ChatLogCategory.refresh,
          message: message,
          timestamp: DateTime.now(),
        ),
      ),
    );
  }

  final ChatComponentConfig _config;
  final http.Client _httpClient;
  final TokenReader readAccessToken;
  final RefreshTokenReader readRefreshToken;
  final TokenWriter writeTokens;
  final SessionClearer clearSession;
  final void Function(ChatLogEvent event) log;
  final FileTokenWriter? writeFileToken;
  final XmppPasswordWriter? writeXmppPassword;

  /// Called after a fatal refresh verdict, once the session is cleared.
  final void Function(RefreshFatalError error)? onRefreshFatal;

  /// Asked before a dead refresh token logs the user out (web Bug D): a host
  /// with `customLogin` or `jwtLogin` can usually hand back a fresh session.
  /// Returns true when the session was re-established; the stored tokens are
  /// then fresh and the request is retried.
  final Future<bool> Function()? hostRecovery;

  /// The single refresh-token rotation point (see [AuthRefresher]). Every
  /// refresh in the SDK goes through this instance.
  late final AuthRefresher auth;

  Future<AuthTokens?> _readStoredTokens() async {
    final token = await readAccessToken();
    final refresh = await readRefreshToken();
    if ((token ?? '').isEmpty && (refresh ?? '').isEmpty) return null;
    return AuthTokens(token: token ?? '', refreshToken: refresh ?? '');
  }

  /// Persists a rotation. The refresh token goes first: it is the one a
  /// crash must never lose.
  Future<void> _persistRotation(AuthTokens tokens) async {
    await writeTokens(tokens.token, tokens.refreshToken);
    final fileToken = tokens.fileToken;
    if (fileToken != null && fileToken.isNotEmpty && writeFileToken != null) {
      await writeFileToken!(fileToken);
    }
    final xmppPassword = tokens.xmppPassword;
    if (xmppPassword != null &&
        xmppPassword.isNotEmpty &&
        writeXmppPassword != null) {
      await writeXmppPassword!(xmppPassword);
    }
    log(
      ChatLogEvent(
        level: ChatLogLevel.info,
        category: ChatLogCategory.refresh,
        message: 'Token refresh successful',
        timestamp: DateTime.now(),
      ),
    );
  }

  /// `POST /v1/users/login/refresh`, `Authorization: {refreshToken}`, empty
  /// JSON body (web authRefresh.ts requestRotation).
  Future<http.Response> _postRefresh(String refreshToken) {
    return _httpClient.post(
      _uri('/v1/users/login/refresh'),
      headers: <String, String>{
        'Authorization': refreshToken,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: '{}',
    );
  }

  Future<bool> _tryHostRecovery() async {
    final recover = hostRecovery;
    if (recover == null) return false;
    try {
      return await recover();
    } catch (_) {
      return false;
    }
  }

  Future<void> _onTimerFatal(RefreshFatalError error) async {
    if (await _tryHostRecovery()) return;
    await _endSession(error);
  }

  Future<void> _endSession([RefreshFatalError? error]) async {
    await clearSession();
    if (error != null) onRefreshFatal?.call(error);
  }

  /// Login and refresh calls handle their own failures: running the refresh
  /// path for them would mask the real error (web apiClient exclusions).
  static bool _isAuthPath(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    const exact = <String>[
      '/users/login/refresh',
      '/users/login',
      '/users/login-with-email',
      '/users/client',
      '/users/my',
    ];
    final bare = normalized.replaceFirst(RegExp(r'^/v[12]'), '');
    final noQuery = bare.split('?').first;
    return exact.contains(noQuery);
  }

  /// A 401 came back for [path]. Rotates the tokens and reports whether the
  /// request is worth retrying. Only a fatal verdict ends the session; a
  /// network blip or a 5xx on the refresh leaves it alone and the caller
  /// surfaces the original 401.
  Future<bool> _refreshAfter401(String path) async {
    if (_isAuthPath(path)) return false;
    if (_config.refreshTokens?.enabled == false) return false;
    if (!await auth.hasRotatableSession()) return false;
    try {
      await auth.refresh();
      return true;
    } on RefreshFatalError catch (error) {
      if (await _tryHostRecovery()) return true;
      await _endSession(error);
      rethrow;
    } catch (error) {
      log(
        ChatLogEvent(
          level: ChatLogLevel.error,
          category: ChatLogCategory.refresh,
          message: 'Token refresh failed: $error',
          timestamp: DateTime.now(),
        ),
      );
      return false;
    }
  }

  /// Rotates a token that is expired or about to be, before the request
  /// goes out. A fatal verdict ends the session.
  Future<void> _ensureFreshBeforeRequest(String path) async {
    if (_isAuthPath(path)) return;
    if (_config.refreshTokens?.enabled == false) return;
    // Cheap pre-check on the access token alone; the full read only happens
    // when a rotation is actually due.
    if (!jwtNeedsRefresh(await readAccessToken(), skew: auth.skew)) return;
    try {
      await auth.ensureFresh();
    } on RefreshFatalError catch (error) {
      if (await _tryHostRecovery()) return;
      await _endSession(error);
      rethrow;
    }
  }

  /// Paths that carry their own version (`/v1/...`, `/v2/...`) hang off the
  /// host root, so a `/v2` call does not inherit the `/v1` suffix of the
  /// configured base (web apiClient: file and app endpoints are on v2).
  Uri _uri(String path, {Map<String, String>? query}) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    var base = _config.normalizedBaseUrl;
    if (normalizedPath.startsWith('/v1/') || normalizedPath.startsWith('/v2/')) {
      base = base.replaceFirst(RegExp(r'/v1$'), '');
    }
    final uri = Uri.parse('$base$normalizedPath');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  /// GET for a binary body (file downloads such as the data export). Uses
  /// the same auth and 401 refresh as the JSON calls.
  Future<List<int>> getBytes(
    String path, {
    Map<String, String>? headers,
    bool retried = false,
  }) async {
    await _ensureFreshBeforeRequest(path);
    final requestHeaders = await _buildHeaders(
      includeUserToken: true,
      customHeaders: headers,
      isMultipart: true,
    );
    final response = await _httpClient.get(_uri(path), headers: requestHeaders);
    if (response.statusCode == 401 && !retried) {
      if (await _refreshAfter401(path)) {
        return getBytes(path, headers: headers, retried: true);
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
    return response.bodyBytes;
  }

  /// GET. With [refreshOn401] false a 401 is surfaced as an [ApiException]
  /// as it is: no token rotation and no retry, for routes where a 401 means
  /// "this route does not take my token" and the caller has a fallback.
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? headers,
    Map<String, String>? query,
    bool refreshOn401 = true,
  }) async {
    return _send(
      method: 'GET',
      path: path,
      body: null,
      headers: headers,
      query: query,
      retried: !refreshOn401,
    );
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    return _send(method: 'POST', path: path, body: body, headers: headers);
  }

  /// PUT with a JSON body (web `http.put`), e.g. per-chat mute.
  Future<Map<String, dynamic>> put(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    return _send(method: 'PUT', path: path, body: body, headers: headers);
  }

  /// PATCH with a JSON body (web `http.patch`), e.g. a chat's picture.
  Future<Map<String, dynamic>> patch(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    return _send(method: 'PATCH', path: path, body: body, headers: headers);
  }

  /// DELETE with an optional JSON body (web `http.delete` with `data`).
  Future<Map<String, dynamic>> delete(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    return _send(method: 'DELETE', path: path, body: body, headers: headers);
  }

  Future<Map<String, dynamic>> upload(
    String path, {
    required List<int> bytes,
    required String filename,
    required String mimeType,
    Map<String, String>? headers,
    Map<String, String> fields = const <String, String>{},
    bool retried = false,
  }) async {
    await _ensureFreshBeforeRequest(path);
    final request = http.MultipartRequest('POST', _uri(path));
    final allHeaders = await _buildHeaders(
      includeUserToken: true,
      customHeaders: headers,
      isMultipart: true,
    );
    request.headers.addAll(allHeaders);
    request.fields.addAll(fields);
    request.files.add(
      http.MultipartFile.fromBytes('files', bytes, filename: filename),
    );
    final streamed = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamed);
    return _handleResponse(
      method: 'POST',
      path: path,
      response: response,
      retryOn401: !retried,
      requestBody: const <String, dynamic>{'filename': 'multipart'},
      retryFunction: () async {
        return upload(
          path,
          bytes: bytes,
          filename: filename,
          mimeType: mimeType,
          headers: headers,
          fields: fields,
          retried: true,
        );
      },
    );
  }

  Future<Map<String, dynamic>> _send({
    required String method,
    required String path,
    required Map<String, dynamic>? body,
    Map<String, String>? headers,
    Map<String, String>? query,
    bool retried = false,
  }) async {
    await _ensureFreshBeforeRequest(path);
    final requestHeaders = await _buildHeaders(
      includeUserToken: true,
      customHeaders: headers,
      isMultipart: false,
    );
    final uri = _uri(path, query: query);
    final http.Response response;
    if (method == 'GET') {
      response = await _httpClient.get(uri, headers: requestHeaders);
    } else if (method == 'POST') {
      response = await _httpClient.post(
        uri,
        headers: requestHeaders,
        body: jsonEncode(body ?? <String, dynamic>{}),
      );
    } else {
      final request = http.Request(method, uri)
        ..headers.addAll(requestHeaders)
        ..body = jsonEncode(body ?? <String, dynamic>{});
      response = await http.Response.fromStream(
        await _httpClient.send(request),
      );
    }
    return _handleResponse(
      method: method,
      path: path,
      response: response,
      retryOn401: !retried,
      requestBody: body,
      retryFunction: () async {
        return _send(
          method: method,
          path: path,
          body: body,
          headers: headers,
          query: query,
          retried: true,
        );
      },
    );
  }

  Future<Map<String, String>> _buildHeaders({
    required bool includeUserToken,
    required bool isMultipart,
    Map<String, String>? customHeaders,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      if (!isMultipart) 'Content-Type': 'application/json',
      ...?customHeaders,
    };
    if (includeUserToken && !headers.containsKey('Authorization')) {
      final token = await readAccessToken();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = token;
      } else if ((_config.customAppToken ?? '').isNotEmpty) {
        headers['Authorization'] = _config.customAppToken!;
      }
    }
    return headers;
  }

  Future<Map<String, dynamic>> _handleResponse({
    required String method,
    required String path,
    required http.Response response,
    required bool retryOn401,
    required Map<String, dynamic>? requestBody,
    required Future<Map<String, dynamic>> Function() retryFunction,
  }) async {
    log(
      ChatLogEvent(
        level:
            response.statusCode >= 400 ? ChatLogLevel.error : ChatLogLevel.info,
        category: ChatLogCategory.api,
        message: '$method $path -> ${response.statusCode}',
        timestamp: DateTime.now(),
      ),
    );

    if (response.statusCode == 401 && retryOn401) {
      if (await _refreshAfter401(path)) {
        return retryFunction();
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }

    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{'items': decoded};
  }
}
