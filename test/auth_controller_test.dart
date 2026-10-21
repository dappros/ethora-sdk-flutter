import 'dart:convert';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';
import 'support_auth.dart';

const XmppSettings _xmppSettings = XmppSettings(
  xmppServerUrl: 'wss://xmpp.test/ws',
  host: 'xmpp.test',
  conference: 'conference.xmpp.test',
);

class _RecordingStore extends InMemoryStore {
  _RecordingStore(this.events);

  final List<String> events;

  @override
  Future<void> clearSession() async {
    events.add('store.clearSession');
    await super.clearSession();
  }
}

/// First connect fails SASL with `not-authorized`, the next ones succeed.
class _SaslFailingXmpp extends FakeXmppClient {
  _SaslFailingXmpp({
    required super.settings,
    required super.user,
    required super.log,
    required this.events,
    this.failFirst = 1,
  });

  final List<String> events;
  final int failFirst;
  final List<String?> passwordsSeen = <String?>[];
  int connects = 0;

  @override
  Future<void> connect() async {
    connects += 1;
    passwordsSeen.add(user.xmppPassword);
    events.add('xmpp.connect');
    if (connects <= failFirst) {
      onAuthFailed?.call(XmppAuthException('not-authorized'));
      return;
    }
    onConnectionChanged?.call(ChatConnectionState.online);
  }

  @override
  Future<void> disconnect() async {
    events.add('xmpp.disconnect');
    await super.disconnect();
  }
}

ApiClient _api(
  InMemoryStore store,
  List<String> events,
  http.Response Function(http.Request request) answer,
) {
  return ApiClient(
    config: const ChatComponentConfig(baseUrl: 'https://api.example.test/v1'),
    readAccessToken: store.getToken,
    readRefreshToken: store.getRefreshToken,
    writeTokens: (access, refresh) async {
      await store.setToken(access);
      if (refresh != null) await store.setRefreshToken(refresh);
    },
    clearSession: store.clearSession,
    log: (_) {},
    httpClient: MockClient((request) async {
      events.add('${request.method} ${request.url.path}');
      return answer(request);
    }),
  );
}

InMemoryStore _signedInStore(List<String> events) => _RecordingStore(events)
  ..token = 'access-1'
  ..refreshToken = 'refresh-1'
  ..user = const ChatUser(
    id: 'u1',
    appId: 'app-1',
    username: 'tester',
    token: 'access-1',
    refreshToken: 'refresh-1',
    xmppUsername: 'tester',
    xmppPassword: 'old-password',
  );

void main() {
  test(
      'SASL not-authorized: forced refresh, then xmpp-token, then reconnect '
      'with the fresh password', () async {
    final events = <String>[];
    final store = _signedInStore(events);
    late _SaslFailingXmpp xmpp;
    final controller = ChatComponentController(
      config: const ChatComponentConfig(
        disableRooms: true,
        xmppSettings: _xmppSettings,
      ),
      store: store,
      apiClient: _api(store, events, (request) {
        if (request.url.path == '/v1/users/login/refresh') {
          return json(200, <String, Object?>{
            'token': 'access-2',
            'refreshToken': 'refresh-2',
          });
        }
        if (request.url.path == '/v1/users/xmpp-token') {
          expect(request.headers['Authorization'], 'access-2');
          return json(200, <String, Object?>{
            'success': true,
            'xmppPassword': 'fresh-password',
          });
        }
        return json(200, <String, Object?>{});
      }),
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(),
      xmppClientFactory: ({required settings, required user, required log}) =>
          xmpp = _SaslFailingXmpp(
        settings: settings,
        user: user,
        log: log,
        events: events,
      ),
    );

    await controller.initialize();

    expect(events, <String>[
      'xmpp.connect',
      'POST /v1/users/login/refresh',
      'POST /v1/users/xmpp-token',
      'xmpp.connect',
    ]);
    expect(xmpp.passwordsSeen, <String?>['old-password', 'fresh-password']);
    expect(store.user!.xmppPassword, 'fresh-password');
    expect(controller.state.value.user!.xmppPassword, 'fresh-password');
    expect(controller.state.value.isInitialized, isTrue);
    expect(controller.state.value.errorMessage, isNull);
    controller.dispose();
  });

  test('a dead refresh token during SASL recovery logs the user out', () async {
    final events = <String>[];
    final store = _signedInStore(events);
    final controller = ChatComponentController(
      config: const ChatComponentConfig(
        disableRooms: true,
        xmppSettings: _xmppSettings,
      ),
      store: store,
      apiClient: _api(store, events, (request) {
        if (request.url.path == '/v1/users/login/refresh') {
          return json(401, <String, Object?>{
            'code': 'REFRESH_TOKEN_REUSE_DETECTED',
          });
        }
        return json(200, <String, Object?>{});
      }),
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(),
      xmppClientFactory: ({required settings, required user, required log}) =>
          _SaslFailingXmpp(
        settings: settings,
        user: user,
        log: log,
        events: events,
      ),
    );

    await controller.initialize();

    expect(events, contains('store.clearSession'));
    expect(events, isNot(contains('POST /v1/users/xmpp-token')));
    expect(controller.state.value.requiresLogin, isTrue);
    expect(store.user, isNull);
    controller.dispose();
  });

  test('SASL recovery gives up after three attempts', () async {
    final events = <String>[];
    final store = _signedInStore(events);
    late _SaslFailingXmpp xmpp;
    final controller = ChatComponentController(
      config: const ChatComponentConfig(
        disableRooms: true,
        xmppSettings: _xmppSettings,
        refreshTokens: RefreshTokensConfig(enabled: false),
      ),
      store: store,
      apiClient: _api(store, events, (request) {
        return json(200, <String, Object?>{'xmppPassword': 'still-bad'});
      }),
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(),
      xmppClientFactory: ({required settings, required user, required log}) =>
          xmpp = _SaslFailingXmpp(
        settings: settings,
        user: user,
        log: log,
        events: events,
        failFirst: 100,
      ),
    );
    await controller.initialize();
    // 1 original connect + 3 recovery reconnects.
    expect(xmpp.connects, 4);
    controller.dispose();
  });

  test(
      'logout runs in order: before hook, push release, disconnect, store '
      'clear, after hook', () async {
    final events = <String>[];
    final store = _signedInStore(events);
    final controller = ChatComponentController(
      config: ChatComponentConfig(
        appId: 'app-1',
        disableRooms: true,
        xmppSettings: _xmppSettings,
        pushNotifications: const PushNotificationsConfig(),
        logout: ChatLogoutConfig(
          onBeforeLogout: () async => events.add('hook.before'),
          onAfterLogout: () async => events.add('hook.after'),
        ),
      ),
      store: store,
      apiClient: _api(store, events, (_) => json(200, <String, Object?>{})),
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(),
      xmppClientFactory: ({required settings, required user, required log}) =>
          _SaslFailingXmpp(
        settings: settings,
        user: user,
        log: log,
        events: events,
        failFirst: 0,
      ),
    );

    await controller.initialize();
    final outcome = await controller.registerPushToken('fcm-token');
    expect(outcome, RegisterPushOutcome.registered);
    events.clear();

    await controller.logout();

    expect(events, <String>[
      'hook.before',
      'DELETE /v1/push/subscription/app-1',
      'xmpp.disconnect',
      'store.clearSession',
      'hook.after',
    ]);
    expect(controller.state.value.requiresLogin, isTrue);
    expect(controller.registeredPushTokens, isEmpty);
    controller.dispose();
  });

  test('a failing push release does not block logout', () async {
    final events = <String>[];
    final store = _signedInStore(events);
    final controller = ChatComponentController(
      config: const ChatComponentConfig(
        appId: 'app-1',
        disableRooms: true,
        xmppSettings: _xmppSettings,
        pushNotifications: PushNotificationsConfig(),
      ),
      store: store,
      apiClient: _api(store, events, (request) {
        if (request.method == 'DELETE') {
          return json(500, <String, Object?>{'error': 'down'});
        }
        return json(200, <String, Object?>{});
      }),
      authService: FakeAuthService(),
      roomsService: FakeRoomsService(),
      xmppClientFactory: ({required settings, required user, required log}) =>
          _SaslFailingXmpp(
        settings: settings,
        user: user,
        log: log,
        events: events,
        failFirst: 0,
      ),
    );
    await controller.initialize();
    await controller.registerPushToken('fcm-token');
    await controller.logout();
    expect(events, contains('store.clearSession'));
    expect(controller.state.value.requiresLogin, isTrue);
    controller.dispose();
  });

  group('host recovery (web Bug D)', () {
    ChatUser recovered() => const ChatUser(
          id: 'u1',
          appId: 'app-1',
          username: 'tester',
          token: 'access-9',
          refreshToken: 'refresh-9',
          xmppUsername: 'tester',
          xmppPassword: 'host-password',
        );

    test('customLogin re-establishes the session instead of logging out',
        () async {
      final events = <String>[];
      final store = _signedInStore(events);
      late _SaslFailingXmpp xmpp;
      var loginCalls = 0;
      final controller = ChatComponentController(
        config: ChatComponentConfig(
          disableRooms: true,
          xmppSettings: _xmppSettings,
          customLogin: CustomLoginConfig(
            enabled: true,
            loginFunction: () async {
              loginCalls += 1;
              return recovered();
            },
          ),
        ),
        store: store,
        apiClient: _api(store, events, (request) {
          if (request.url.path == '/v1/users/login/refresh') {
            return json(401, <String, Object?>{
              'code': 'REFRESH_TOKEN_NOT_FOUND',
            });
          }
          return json(200, <String, Object?>{});
        }),
        authService: FakeAuthService(),
        roomsService: FakeRoomsService(),
        xmppClientFactory: ({required settings, required user, required log}) =>
            xmpp = _SaslFailingXmpp(
          settings: settings,
          user: user,
          log: log,
          events: events,
        ),
      );

      await controller.initialize();

      expect(loginCalls, 1);
      expect(events, isNot(contains('store.clearSession')));
      expect(controller.state.value.requiresLogin, isFalse);
      expect(store.token, 'access-9');
      expect(xmpp.passwordsSeen.last, 'host-password');
      controller.dispose();
    });

    test('a request 401 with a dead refresh token is retried after recovery',
        () async {
      final events = <String>[];
      var recoveries = 0;
      var mainCalls = 0;
      final store = _signedInStore(events);
      final api = ApiClient(
        config:
            const ChatComponentConfig(baseUrl: 'https://api.example.test/v1'),
        readAccessToken: store.getToken,
        readRefreshToken: store.getRefreshToken,
        writeTokens: (_, __) async {},
        clearSession: store.clearSession,
        log: (_) {},
        hostRecovery: () async {
          recoveries += 1;
          await store.setToken('access-9');
          return true;
        },
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/users/login/refresh') {
            return json(401, <String, Object?>{
              'code': 'REFRESH_TOKEN_REUSE_DETECTED',
            });
          }
          mainCalls += 1;
          if (mainCalls == 1) return http.Response('unauthorized', 401);
          expect(request.headers['Authorization'], 'access-9');
          return json(200, <String, Object?>{'ok': true});
        }),
      );
      expect((await api.get('/chats/my'))['ok'], true);
      expect(recoveries, 1);
      expect(events, isNot(contains('store.clearSession')));
    });

    test('without a way back the session ends', () async {
      final events = <String>[];
      final store = _signedInStore(events);
      final api = ApiClient(
        config:
            const ChatComponentConfig(baseUrl: 'https://api.example.test/v1'),
        readAccessToken: store.getToken,
        readRefreshToken: store.getRefreshToken,
        writeTokens: (_, __) async {},
        clearSession: store.clearSession,
        log: (_) {},
        hostRecovery: () async => false,
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/users/login/refresh') {
            return json(401, <String, Object?>{
              'code': 'REFRESH_TOKEN_REUSE_DETECTED',
            });
          }
          return http.Response('unauthorized', 401);
        }),
      );
      await expectLater(
          api.get('/chats/my'), throwsA(isA<RefreshFatalError>()));
      expect(events, contains('store.clearSession'));
    });
  });

  group('account', () {
    test(
        'setAppLanguage and setChatLanguage send one field each and update '
        'the user', () async {
      final events = <String>[];
      final bodies = <Map<String, dynamic>>[];
      final store = _signedInStore(events);
      final controller = ChatComponentController(
        config: const ChatComponentConfig(
          disableRooms: true,
          xmppSettings: _xmppSettings,
          i18n: ChatI18nConfig(locale: 'en'),
        ),
        store: store,
        apiClient: _api(store, events, (request) {
          if (request.method == 'PUT') {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          }
          return json(200, <String, Object?>{});
        }),
        authService: FakeAuthService(),
        roomsService: FakeRoomsService(),
        xmppClientFactory: FakeXmppClient.new,
      );
      await controller.initialize();
      expect(controller.uiLocale, 'en');

      await controller.setAppLanguage('fr-CA');
      await controller.setChatLanguage('es-US');

      expect(bodies, <Map<String, dynamic>>[
        <String, dynamic>{'appLanguage': 'fr-CA'},
        <String, dynamic>{'chatLanguage': 'es-US'},
      ]);
      expect(events.where((e) => e == 'PUT /v1/users'), hasLength(2));
      expect(controller.state.value.user!.appLanguage, 'fr-CA');
      expect(controller.state.value.user!.chatLanguage, 'es-US');
      expect(controller.uiLocale, 'fr-CA');
      expect(controller.translationLocale, 'es-US');
      expect(store.user!.appLanguage, 'fr-CA');
      controller.dispose();
    });

    test('changePassword surfaces the server reason', () async {
      final events = <String>[];
      final store = _signedInStore(events);
      final controller = ChatComponentController(
        config: const ChatComponentConfig(
          disableRooms: true,
          xmppSettings: _xmppSettings,
        ),
        store: store,
        apiClient: _api(store, events, (request) {
          expect(request.url.path, '/v2/users/me/password');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['currentPassword'] == 'wrong') {
            return json(400, <String, Object?>{
              'message': 'Current password is incorrect',
            });
          }
          return json(200, <String, Object?>{});
        }),
        authService: FakeAuthService(),
        roomsService: FakeRoomsService(),
        xmppClientFactory: FakeXmppClient.new,
      );
      await controller.initialize();
      await controller.changePassword(
        currentPassword: 'right',
        newPassword: 'new-password',
      );
      await expectLater(
        controller.changePassword(
          currentPassword: 'wrong',
          newPassword: 'new-password',
        ),
        throwsA(isA<ApiException>().having(
            (e) => e.reason, 'reason', 'Current password is incorrect')),
      );
      controller.dispose();
    });

    test('deleteAccount calls DELETE /v1/users and then logs out', () async {
      final events = <String>[];
      final store = _signedInStore(events);
      final controller = ChatComponentController(
        config: const ChatComponentConfig(
          disableRooms: true,
          xmppSettings: _xmppSettings,
        ),
        store: store,
        apiClient: _api(store, events, (_) => json(200, <String, Object?>{})),
        authService: FakeAuthService(),
        roomsService: FakeRoomsService(),
        xmppClientFactory: FakeXmppClient.new,
      );
      await controller.initialize();
      events.clear();
      await controller.deleteAccount();
      expect(events.first, 'DELETE /v1/users');
      expect(events, contains('store.clearSession'));
      expect(controller.state.value.requiresLogin, isTrue);
      controller.dispose();
    });
  });
}
