import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_component_config.dart';
import '../core/chat_component_log.dart';

typedef TokenReader = Future<String?> Function();
typedef RefreshTokenReader = Future<String?> Function();
typedef TokenWriter = Future<void> Function(
    String accessToken, String? refreshToken);
typedef SessionClearer = Future<void> Function();

class ApiClient {
  ApiClient({
    required ChatComponentConfig config,
    required this.readAccessToken,
    required this.readRefreshToken,
    required this.writeTokens,
    required this.clearSession,
    required this.log,
    http.Client? httpClient,
  })  : _config = config,
        _httpClient = httpClient ?? http.Client();

  final ChatComponentConfig _config;
  final http.Client _httpClient;
  final TokenReader readAccessToken;
  final RefreshTokenReader readRefreshToken;
  final TokenWriter writeTokens;
  final SessionClearer clearSession;
  final void Function(ChatLogEvent event) log;

  Completer<bool>? _refreshCompleter;

  Uri _uri(String path) {
    final base = _config.normalizedBaseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$normalizedPath');
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? headers,
  }) async {
    return _send(method: 'GET', path: path, body: null, headers: headers);
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    return _send(method: 'POST', path: path, body: body, headers: headers);
  }

  Future<Map<String, dynamic>> upload(
    String path, {
    required List<int> bytes,
    required String filename,
    required String mimeType,
    Map<String, String>? headers,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path));
    final allHeaders = await _buildHeaders(
      includeUserToken: true,
      customHeaders: headers,
      isMultipart: true,
    );
    request.headers.addAll(allHeaders);
    request.files.add(
      http.MultipartFile.fromBytes('files', bytes, filename: filename),
    );
    final streamed = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamed);
    return _handleResponse(
      method: 'POST',
      path: path,
      response: response,
      retryOn401: true,
      requestBody: const <String, dynamic>{'filename': 'multipart'},
      retryFunction: () async {
        return upload(
          path,
          bytes: bytes,
          filename: filename,
          mimeType: mimeType,
          headers: headers,
        );
      },
    );
  }

  Future<Map<String, dynamic>> _send({
    required String method,
    required String path,
    required Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    final requestHeaders = await _buildHeaders(
      includeUserToken: true,
      customHeaders: headers,
      isMultipart: false,
    );
    final response = method == 'GET'
        ? await _httpClient.get(_uri(path), headers: requestHeaders)
        : await _httpClient.post(
            _uri(path),
            headers: requestHeaders,
            body: jsonEncode(body ?? <String, dynamic>{}),
          );
    return _handleResponse(
      method: method,
      path: path,
      response: response,
      retryOn401: true,
      requestBody: body,
      retryFunction: () async {
        return _send(method: method, path: path, body: body, headers: headers);
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
      final refreshed = await _refreshTokensSingleFlight();
      if (refreshed) {
        return retryFunction();
      }
      await clearSession();
      throw Exception('Unauthorized and token refresh failed');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('API error ${response.statusCode}: ${response.body}');
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

  Future<bool> _refreshTokensSingleFlight() async {
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }
    _refreshCompleter = Completer<bool>();
    try {
      final refreshToken = await readRefreshToken();
      if (refreshToken == null || refreshToken.isEmpty) {
        _refreshCompleter!.complete(false);
        return false;
      }
      final response = await _httpClient.post(
        _uri('/users/login/refresh'),
        headers: <String, String>{
          'Authorization': _config.customAppToken ?? '',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{'refreshToken': refreshToken}),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _refreshCompleter!.complete(false);
        return false;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final accessToken = body['token']?.toString();
      final newRefreshToken = body['refreshToken']?.toString();
      if (accessToken == null || accessToken.isEmpty) {
        _refreshCompleter!.complete(false);
        return false;
      }
      await writeTokens(accessToken, newRefreshToken);
      log(
        ChatLogEvent(
          level: ChatLogLevel.info,
          category: ChatLogCategory.refresh,
          message: 'Token refresh successful',
          timestamp: DateTime.now(),
        ),
      );
      _refreshCompleter!.complete(true);
      return true;
    } catch (_) {
      _refreshCompleter!.complete(false);
      return false;
    } finally {
      _refreshCompleter = null;
    }
  }
}
