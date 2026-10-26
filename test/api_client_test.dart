import 'dart:convert';

import 'package:ethora_sdk_flutter/src/networking/api_client.dart';
import 'package:ethora_sdk_flutter/src/models/chat_component_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('adds Authorization user token by default', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
    });

    final api = ApiClient(
      config: const ChatComponentConfig(baseUrl: 'https://api.chat.ethora.com'),
      readAccessToken: () async => 'user-token',
      readRefreshToken: () async => null,
      writeTokens: (_, __) async {},
      clearSession: () async {},
      log: (_) {},
      httpClient: client,
    );

    await api.get('/chats/my');
    expect(captured.headers['Authorization'], 'user-token');
  });

  test('refreshes and retries request once on 401', () async {
    var mainCalls = 0;
    var refreshCalls = 0;
    String token = 'stale-token';

    final client = MockClient((request) async {
      if (request.url.path == '/v1/users/login/refresh') {
        refreshCalls += 1;
        // Web contract: the refresh token is the Authorization header and
        // the body is empty (not the app token, not a refreshToken field).
        expect(request.headers['Authorization'], 'refresh-token');
        expect(request.body, '{}');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'token': 'fresh-token',
            'refreshToken': 'r2',
          }),
          200,
        );
      }
      mainCalls += 1;
      if (mainCalls == 1) {
        return http.Response('unauthorized', 401);
      }
      return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
    });

    final api = ApiClient(
      config: const ChatComponentConfig(
        baseUrl: 'https://api.chat.ethora.com',
        customAppToken: 'app-token',
      ),
      readAccessToken: () async => token,
      readRefreshToken: () async => 'refresh-token',
      writeTokens: (accessToken, refreshToken) async {
        token = accessToken;
      },
      clearSession: () async {},
      log: (_) {},
      httpClient: client,
    );

    final response = await api.get('/chats/my');
    expect(response['ok'], true);
    expect(mainCalls, 2);
    expect(refreshCalls, 1);
    expect(token, 'fresh-token');
  });
}
