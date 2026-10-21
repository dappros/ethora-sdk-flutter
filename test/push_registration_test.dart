import 'dart:convert';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/push/push_registration.dart';
import 'package:ethora_sdk_flutter/src/push/push_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support_auth.dart';

void main() {
  late List<String> calls;
  late PushSession session;
  late MemoryPushStorage storage;
  late PushRegistrationManager manager;
  late http.Response Function(
      String method, String path, Map<String, dynamic> body) answer;

  const signedIn = PushSession(
    authToken: 'user-token',
    appId: 'app-1',
    xmppUsername: 'alice',
    xmppHost: 'xmpp.example.test',
    projectName: '',
    gatewayUrl: '',
    configEnabled: true,
  );
  const signedOut = PushSession(
    authToken: '',
    appId: '',
    xmppUsername: '',
    xmppHost: 'xmpp.example.test',
    projectName: '',
    gatewayUrl: '',
    configEnabled: true,
  );

  setUp(() {
    calls = <String>[];
    session = signedIn;
    storage = MemoryPushStorage();
    answer = (_, __, ___) => json(200, <String, Object?>{});
    final api = buildApiClient(
      store: FakeTokenStore(token: 'user-token'),
      handler: (request) async {
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        calls.add('${request.method} ${request.url.path} '
            '${body['tokenType'] ?? body['registrationToken'] ?? body['endpoint']}');
        return answer(request.method, request.url.path, body);
      },
    );
    manager = PushRegistrationManager(
      api: PushApi(apiClient: api, deviceType: () => 'android'),
      readSession: () async => session,
      storage: storage,
    );
  });

  test('registers straight away when signed in', () async {
    final outcome = await manager.register('fcm-token');
    expect(outcome, RegisterPushOutcome.registered);
    expect(calls, <String>['POST /v1/push/subscription/app-1 fcm']);
  });

  test('a token before sign-in is held and registered afterwards', () async {
    session = signedOut;
    expect(await manager.register('fcm-token'), RegisterPushOutcome.deferred);
    expect(calls, isEmpty);
    expect(manager.tokens.single.token, 'fcm-token');

    session = signedIn;
    await manager.syncHeldTokens();
    expect(calls, <String>['POST /v1/push/subscription/app-1 fcm']);

    // Already registered for this user: no second call.
    await manager.syncHeldTokens();
    expect(calls, hasLength(1));
  });

  test('chat and voip are separate slots', () async {
    await manager.register('a' * 64);
    await manager.register('voip-token', tokenType: PushTokenType.apnsVoip);
    expect(calls, <String>[
      'POST /v1/push/subscription/app-1 apns',
      'POST /v1/push/subscription/app-1 apns-voip',
    ]);
    expect(manager.tokens.map((t) => t.tokenType), <PushTokenType>[
      PushTokenType.apns,
      PushTokenType.apnsVoip,
    ]);
  });

  test('a replaced chat token releases the old one first', () async {
    await manager.register('old-token');
    calls.clear();
    await manager.register('new-token');
    expect(calls, <String>[
      'DELETE /v1/push/subscription/app-1 old-token',
      'POST /v1/push/subscription/app-1 fcm',
    ]);
  });

  test('config enabled false is a no-op', () async {
    session = const PushSession(
      authToken: 'user-token',
      appId: 'app-1',
      xmppUsername: 'alice',
      xmppHost: 'h',
      projectName: '',
      gatewayUrl: '',
      configEnabled: false,
    );
    expect(await manager.register('fcm-token'), RegisterPushOutcome.disabled);
    expect(calls, isEmpty);
  });

  test('release (logout) deletes both slots, awaited, and forgets on request',
      () async {
    await manager.register('chat-token');
    await manager.register('voip-token', tokenType: PushTokenType.apnsVoip);
    calls.clear();
    await manager.releaseAndForget();
    expect(
        calls,
        unorderedEquals(<String>[
          'DELETE /v1/push/subscription/app-1 chat-token',
          'DELETE /v1/push/subscription/app-1 voip-token',
        ]));
    expect(manager.tokens, isEmpty);
    expect(manager.hasServerRegistration, isFalse);
  });

  test('release swallows server failures so logout never stalls', () async {
    await manager.register('chat-token');
    answer = (_, __, ___) => json(500, <String, Object?>{'error': 'down'});
    await manager.release();
    expect(manager.hasServerRegistration, isFalse);
  });

  test('unregister forgets the token and removes it, with the 404 fallback',
      () async {
    await manager.register('chat-token');
    calls.clear();
    answer = (method, path, _) => path.contains('/push/subscription')
        ? json(404, <String, Object?>{'error': 'gone'})
        : json(200, <String, Object?>{});
    final outcome = await manager.unregister();
    expect(outcome, UnregisterPushOutcome.unregistered);
    expect(calls, <String>[
      'DELETE /v1/push/subscription/app-1 chat-token',
      'DELETE /v1/users/endpoints chat-token',
    ]);
    expect(manager.tokens, isEmpty);
  });

  test('unregister with nothing registered only forgets', () async {
    session = signedOut;
    await manager.register('chat-token');
    expect(await manager.unregister(), UnregisterPushOutcome.forgotten);
    expect(manager.tokens, isEmpty);
  });

  test('the user switch off releases but keeps the token; on re-registers',
      () async {
    await manager.register('chat-token');
    calls.clear();
    await manager.setUserEnabled(false);
    expect(calls, <String>['DELETE /v1/push/subscription/app-1 chat-token']);
    expect(manager.tokens, hasLength(1));
    expect(storage.values[kPushEnabledKey], 'false');

    calls.clear();
    expect(await manager.register('chat-token'), RegisterPushOutcome.disabled);
    await manager.setUserEnabled(true);
    expect(calls, <String>['POST /v1/push/subscription/app-1 fcm']);
    expect(storage.values[kPushEnabledKey], 'true');
  });

  test('the saved switch is read back', () async {
    storage.values[kPushEnabledKey] = 'false';
    await manager.loadPreferences();
    expect(manager.userEnabled, isFalse);
  });

  test('gateway mode needs a project name and skips the REST call', () async {
    session = const PushSession(
      authToken: 'user-token',
      appId: '',
      xmppUsername: 'alice',
      xmppHost: 'xmpp.example.test',
      projectName: '',
      gatewayUrl: 'https://push.example.test/api/v1',
      configEnabled: true,
    );
    // Not ready without a project name: the token waits.
    expect(await manager.register('fcm-token'), RegisterPushOutcome.deferred);
    expect(calls, isEmpty);
  });

  test('an empty token is rejected', () async {
    await expectLater(manager.register('  '), throwsArgumentError);
  });

  group('getPushTokens hook', () {
    PushRegistrationManager withHook(
      Future<List<PushTokenRegistration>> Function() hook, {
      DateTime Function()? now,
    }) {
      final api = buildApiClient(
        store: FakeTokenStore(token: 'user-token'),
        handler: (request) async {
          final body = request.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(request.body) as Map<String, dynamic>;
          calls.add('${request.method} ${request.url.path} '
              '${body['tokenType'] ?? body['registrationToken']}');
          return json(200, <String, Object?>{});
        },
      );
      return PushRegistrationManager(
        api: PushApi(apiClient: api, deviceType: () => 'ios'),
        readSession: () async => session,
        storage: storage,
        tokenHook: hook,
        now: now,
      );
    }

    test(
        'runs once per account when the session is ready and registers both '
        'slots', () async {
      var hookCalls = 0;
      manager = withHook(() async {
        hookCalls += 1;
        return const <PushTokenRegistration>[
          PushTokenRegistration(token: 'chat-token'),
          PushTokenRegistration(
            token: 'voip-token',
            tokenType: PushTokenType.apnsVoip,
          ),
        ];
      });
      session = signedOut;
      await manager.syncHeldTokens();
      expect(hookCalls, 0);
      expect(calls, isEmpty);

      session = signedIn;
      await manager.syncHeldTokens();
      expect(hookCalls, 1);
      expect(calls, <String>[
        'POST /v1/push/subscription/app-1 fcm',
        'POST /v1/push/subscription/app-1 apns-voip',
      ]);

      await manager.syncHeldTokens();
      expect(hookCalls, 1);
    });

    test('refreshFromHook asks again and registers a rotated token', () async {
      var token = 'token-one';
      manager = withHook(
        () async =>
            <PushTokenRegistration>[PushTokenRegistration(token: token)],
      );
      await manager.syncHeldTokens();
      calls.clear();
      token = 'token-two';
      await manager.refreshFromHook();
      expect(calls, <String>[
        'DELETE /v1/push/subscription/app-1 token-one',
        'POST /v1/push/subscription/app-1 fcm',
      ]);
    });

    test('a failing hook is retried only after 30 seconds', () async {
      var clock = DateTime(2026, 10, 21, 12);
      var hookCalls = 0;
      manager = withHook(() async {
        hookCalls += 1;
        if (hookCalls == 1) throw Exception('no token yet');
        return const <PushTokenRegistration>[
          PushTokenRegistration(token: 'late-token'),
        ];
      }, now: () => clock);
      await manager.syncHeldTokens();
      expect(hookCalls, 1);
      clock = clock.add(const Duration(seconds: 10));
      await manager.syncHeldTokens();
      expect(hookCalls, 1);
      clock = clock.add(const Duration(seconds: 25));
      await manager.syncHeldTokens();
      expect(hookCalls, 2);
      expect(calls, <String>['POST /v1/push/subscription/app-1 fcm']);
    });

    test('blank tokens from the hook are ignored', () async {
      manager = withHook(
        () async => const <PushTokenRegistration>[
          PushTokenRegistration(token: '  '),
        ],
      );
      await manager.syncHeldTokens();
      expect(manager.tokens, isEmpty);
      expect(calls, isEmpty);
    });
  });
}
