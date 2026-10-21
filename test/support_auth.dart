import 'dart:convert';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A JWT with the given `exp` (seconds since the epoch). The signature is
/// junk: the SDK only reads the payload.
String fakeJwt({required int expSeconds}) {
  String enc(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${enc(<String, Object?>{'alg': 'none'})}.'
      '${enc(<String, Object?>{'exp': expSeconds})}.sig';
}

/// Token storage that records every write, in order.
class FakeTokenStore {
  FakeTokenStore({this.token = 'access-1', this.refreshToken = 'refresh-1'});

  String? token;
  String? refreshToken;
  String? fileToken;
  String? xmppPassword;
  final List<String> events = <String>[];

  Future<String?> readAccess() async => token;
  Future<String?> readRefresh() async => refreshToken;

  Future<void> writeTokens(String access, String? refresh) async {
    // Yield so a caller that forgot to await the write is caught.
    await Future<void>.delayed(Duration.zero);
    token = access;
    if (refresh != null && refresh.isNotEmpty) refreshToken = refresh;
    events.add('tokens:$access:$refresh');
  }

  Future<void> writeFileToken(String value) async {
    fileToken = value;
    events.add('fileToken:$value');
  }

  Future<void> writeXmppPassword(String value) async {
    xmppPassword = value;
    events.add('xmppPassword:$value');
  }
}

/// An [ApiClient] over [handler] with its writes captured in [store].
ApiClient buildApiClient({
  required FakeTokenStore store,
  required Future<http.Response> Function(http.Request request) handler,
  ChatComponentConfig config = const ChatComponentConfig(
    baseUrl: 'https://api.example.test/v1',
    customAppToken: 'app-token',
  ),
  Future<void> Function()? clearSession,
}) {
  return ApiClient(
    config: config,
    readAccessToken: store.readAccess,
    readRefreshToken: store.readRefresh,
    writeTokens: store.writeTokens,
    writeFileToken: store.writeFileToken,
    writeXmppPassword: store.writeXmppPassword,
    clearSession: clearSession ?? () async => store.events.add('cleared'),
    log: (_) {},
    httpClient: MockClient(handler),
  );
}

http.Response json(int status, Map<String, Object?> body) =>
    http.Response(jsonEncode(body), status,
        headers: <String, String>{'content-type': 'application/json'});
