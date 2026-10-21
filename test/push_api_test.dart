import 'dart:convert';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support_auth.dart';

class _Call {
  _Call(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

void main() {
  late List<_Call> calls;

  PushApi build(
    http.Response Function(_Call call) answer, {
    http.Client? gateway,
  }) {
    calls = <_Call>[];
    final store = FakeTokenStore(token: 'user-token');
    final api = buildApiClient(
      store: store,
      handler: (request) async {
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        final call =
            _Call(request.method, request.url.path, request.headers, body);
        calls.add(call);
        return answer(call);
      },
    );
    return PushApi(
      apiClient: api,
      gatewayClient: gateway,
      deviceType: () => 'ios',
    );
  }

  group('detectPushTokenType', () {
    test('64+ hex characters is APNs, anything else FCM', () {
      expect(detectPushTokenType('a' * 64), PushTokenType.apns);
      expect(detectPushTokenType('AB12' * 20), PushTokenType.apns);
      expect(detectPushTokenType('fcm:APA91bH-token_value'), PushTokenType.fcm);
      expect(detectPushTokenType('abc123'), PushTokenType.fcm);
    });
  });

  group('register', () {
    test('POST /v1/push/subscription/{appId} with tokenType', () async {
      final api = build((_) => json(200, <String, Object?>{}));
      await api.register(
        appId: 'app 1',
        token: 'tok',
        tokenType: PushTokenType.apnsVoip,
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'POST');
      expect(calls.single.path, '/v1/push/subscription/app%201');
      expect(calls.single.headers['Authorization'], 'user-token');
      expect(calls.single.body, <String, dynamic>{
        'registrationToken': 'tok',
        'deviceType': 'ios',
        'tokenType': 'apns-voip',
      });
    });

    test('422 "not allowed" retries once without tokenType', () async {
      final api = build((call) {
        if (call.body.containsKey('tokenType')) {
          return json(422, <String, Object?>{
            'error': '"tokenType" is not allowed',
          });
        }
        return json(200, <String, Object?>{});
      });
      await api.register(
          appId: 'app', token: 'tok', tokenType: PushTokenType.fcm);
      expect(calls, hasLength(2));
      expect(calls[1].body, <String, dynamic>{
        'registrationToken': 'tok',
        'deviceType': 'ios',
      });
    });

    test('another 422 is an error without a retry', () async {
      final api = build(
        (_) =>
            json(422, <String, Object?>{'error': 'registrationToken is empty'}),
      );
      await expectLater(
        api.register(appId: 'app', token: 'tok', tokenType: PushTokenType.fcm),
        throwsA(isA<PushRegistrationError>()
            .having((e) => e.status, 'status', 422)),
      );
      expect(calls, hasLength(1));
    });

    test('the VoIP slot is never downgraded', () async {
      final api = build(
        (_) =>
            json(422, <String, Object?>{'error': 'tokenType is not allowed'}),
      );
      await expectLater(
        api.register(
            appId: 'app', token: 'tok', tokenType: PushTokenType.apnsVoip),
        throwsA(isA<PushRegistrationError>()),
      );
      expect(calls, hasLength(1));
    });

    test('a failing retry surfaces its status', () async {
      final api = build((call) {
        if (call.body.containsKey('tokenType')) {
          return json(422, <String, Object?>{'error': 'tokenType not allowed'});
        }
        return json(500, <String, Object?>{'error': 'down'});
      });
      await expectLater(
        api.register(appId: 'app', token: 'tok', tokenType: PushTokenType.apns),
        throwsA(isA<PushRegistrationError>()
            .having((e) => e.status, 'status', 500)),
      );
    });
  });

  group('unregister', () {
    test('DELETE /v1/push/subscription/{appId} with the token', () async {
      final api = build((_) => json(200, <String, Object?>{}));
      await api.unregister(appId: 'app', token: 'tok');
      expect(calls.single.method, 'DELETE');
      expect(calls.single.path, '/v1/push/subscription/app');
      expect(calls.single.body, <String, dynamic>{'registrationToken': 'tok'});
    });

    test('404 falls back to DELETE /v1/users/endpoints', () async {
      final api = build((call) => call.path.contains('/push/subscription')
          ? json(404, <String, Object?>{'error': 'not found'})
          : json(200, <String, Object?>{}));
      await api.unregister(appId: 'app', token: 'tok');
      expect(calls, hasLength(2));
      expect(calls[1].method, 'DELETE');
      expect(calls[1].path, '/v1/users/endpoints');
      expect(calls[1].body, <String, dynamic>{'endpoint': 'tok'});
    });

    test('other failures do not fall back', () async {
      final api = build((_) => json(500, <String, Object?>{'error': 'down'}));
      await expectLater(
        api.unregister(appId: 'app', token: 'tok'),
        throwsA(isA<PushRegistrationError>()),
      );
      expect(calls, hasLength(1));
    });
  });

  group('gateway', () {
    test('POST {apiUrl}/subscriptions with Bearer and the full jid', () async {
      late http.Request seen;
      final gateway = MockClient((request) async {
        seen = request;
        return http.Response('{}', 200);
      });
      final api = build((_) => fail('REST must not be used'), gateway: gateway);
      await api.subscribeToGateway(
        apiUrl: 'https://push.example.test/api/v1/',
        authToken: 'user-token',
        projectName: 'proj',
        token: 'tok',
        xmppUser: 'alice',
        xmppHost: 'xmpp.example.test',
      );
      expect(seen.url.toString(),
          'https://push.example.test/api/v1/subscriptions');
      expect(seen.headers['Authorization'], 'Bearer user-token');
      expect(jsonDecode(seen.body), <String, dynamic>{
        'projectName': 'proj',
        'registrationToken': 'tok',
        'deviceType': 'ios',
        'jid': 'alice@xmpp.example.test',
      });
      expect(calls, isEmpty);
    });

    test('a refused gateway call is a PushRegistrationError', () async {
      final gateway =
          MockClient((_) async => http.Response('{"error":"nope"}', 403));
      final api = build((_) => fail('unused'), gateway: gateway);
      await expectLater(
        api.subscribeToGateway(
          apiUrl: 'https://push.example.test/api/v1',
          authToken: 't',
          projectName: 'p',
          token: 'tok',
          xmppUser: 'alice@host',
          xmppHost: 'other',
        ),
        throwsA(isA<PushRegistrationError>()
            .having((e) => e.status, 'status', 403)),
      );
    });
  });
}
