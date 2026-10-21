import 'dart:async';
import 'dart:convert';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support_auth.dart';

http.Response _refreshError(String code, {int status = 401}) =>
    json(status, <String, Object?>{'code': code});

void main() {
  group('parseRefreshErrorCode', () {
    test('reads every payload shape', () {
      expect(
        parseRefreshErrorCode(body: '{"code":"REFRESH_IN_PROGRESS"}'),
        RefreshErrorCode.inProgress,
      );
      expect(
        parseRefreshErrorCode(
            body: '{"error":{"code":"REFRESH_TOKEN_NOT_FOUND"}}'),
        RefreshErrorCode.notFound,
      );
      expect(
        parseRefreshErrorCode(
            body: '{"errors":[{"code":"REFRESH_TOKEN_REUSE_DETECTED"}]}'),
        RefreshErrorCode.reuseDetected,
      );
      expect(
        parseRefreshErrorCode(
            body: '{"error":"REFRESH_TOKEN_ALREADY_ROTATED"}'),
        RefreshErrorCode.alreadyRotated,
      );
      expect(
        parseRefreshErrorCode(
            body: '{"message":"failed: REFRESH_IN_PROGRESS, retry"}'),
        RefreshErrorCode.inProgress,
      );
      expect(
        parseRefreshErrorCode(
          body: 'not json',
          headers: <String, String>{'X-Error-Code': 'REFRESH_TOKEN_NOT_FOUND'},
        ),
        RefreshErrorCode.notFound,
      );
    });

    test('unknown or absent codes are null', () {
      expect(parseRefreshErrorCode(body: '{"code":"SOMETHING_ELSE"}'), isNull);
      expect(parseRefreshErrorCode(body: ''), isNull);
      expect(parseRefreshErrorCode(body: '{"code":42}'), isNull);
    });
  });

  group('JWT expiry', () {
    test('jwtExpiryMs reads exp', () {
      expect(jwtExpiryMs(fakeJwt(expSeconds: 1700000000)), 1700000000000);
    });

    test('opaque tokens have no expiry and never need a refresh', () {
      expect(jwtExpiryMs('opaque-token'), isNull);
      expect(jwtExpiryMs(''), isNull);
      expect(jwtExpiryMs(null), isNull);
      expect(jwtNeedsRefresh('opaque-token'), isFalse);
    });

    test('needs a refresh once within the skew of exp', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
      expect(
        jwtNeedsRefresh(fakeJwt(expSeconds: 1000 + 600), now: now),
        isFalse,
      );
      expect(
        jwtNeedsRefresh(fakeJwt(expSeconds: 1000 + 30), now: now),
        isTrue,
      );
      expect(
        jwtNeedsRefresh(fakeJwt(expSeconds: 1000 - 5), now: now),
        isTrue,
      );
    });
  });

  group('AuthRefresher', () {
    late FakeTokenStore store;
    late List<String> log;
    late List<Duration> sleeps;
    late int posts;

    AuthRefresher build(
      Future<http.Response> Function(String refreshToken) post, {
      RefreshFunction? host,
    }) {
      return AuthRefresher(
        readStoredTokens: () async => AuthTokens(
            token: store.token ?? '', refreshToken: store.refreshToken ?? ''),
        persistTokens: (tokens) async {
          await store.writeTokens(tokens.token, tokens.refreshToken);
          log.add('persisted:${tokens.refreshToken}');
        },
        postRefresh: (refreshToken) {
          posts += 1;
          return post(refreshToken);
        },
        hostRefresh: () => host,
        sleep: (delay) async => sleeps.add(delay),
      );
    }

    setUp(() {
      store = FakeTokenStore();
      log = <String>[];
      sleeps = <Duration>[];
      posts = 0;
    });

    test('persists the new refresh token before returning', () async {
      final refresher = build((refreshToken) async {
        expect(refreshToken, 'refresh-1');
        return json(200, <String, Object?>{
          'token': 'access-2',
          'refreshToken': 'refresh-2',
          'fileToken': 'ft-2',
          'xmppPassword': 'xmpp-2',
        });
      });
      final result = await refresher.refresh();
      log.add('returned');
      expect(log, <String>['persisted:refresh-2', 'returned']);
      expect(store.refreshToken, 'refresh-2');
      expect(result.token, 'access-2');
      expect(result.fileToken, 'ft-2');
      expect(result.xmppPassword, 'xmpp-2');
    });

    test('concurrent callers share one request', () async {
      final refresher = build((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return json(200, <String, Object?>{
          'token': 'access-2',
          'refreshToken': 'refresh-2',
        });
      });
      final results = await Future.wait(<Future<AuthTokens>>[
        refresher.refresh(),
        refresher.refresh(),
        refresher.refresh(),
      ]);
      expect(posts, 1);
      expect(results.map((r) => r.refreshToken).toSet(), <String>{'refresh-2'});
      // A later call starts a new rotation.
      await refresher.refresh();
      expect(posts, 2);
    });

    test('a response without both tokens is an error, nothing persisted',
        () async {
      final refresher = build(
        (_) async => json(200, <String, Object?>{'token': 'only-access'}),
      );
      await expectLater(refresher.refresh(), throwsStateError);
      expect(log, isEmpty);
      expect(store.refreshToken, 'refresh-1');
    });

    test(
        'REFRESH_IN_PROGRESS retries 3 times with growing delay, then adopts '
        'a newer stored token', () async {
      final refresher = build((_) async {
        if (posts == 3) {
          // Another writer rotated while we were retrying.
          store.token = 'access-other';
          store.refreshToken = 'refresh-other';
        }
        return _refreshError('REFRESH_IN_PROGRESS');
      });
      final result = await refresher.refresh();
      expect(posts, 3);
      expect(sleeps, hasLength(2));
      expect(sleeps[0].inMilliseconds, inInclusiveRange(300, 449));
      expect(sleeps[1].inMilliseconds, inInclusiveRange(600, 749));
      expect(result.refreshToken, 'refresh-other');
    });

    test('REFRESH_IN_PROGRESS with nothing newer passes through, no logout',
        () async {
      final refresher =
          build((_) async => _refreshError('REFRESH_IN_PROGRESS'));
      await expectLater(
        refresher.refresh(),
        throwsA(isA<RefreshHttpException>()),
      );
      expect(posts, 3);
    });

    test('REFRESH_IN_PROGRESS that clears up succeeds on the retry', () async {
      final refresher = build((_) async {
        if (posts < 2) return _refreshError('REFRESH_IN_PROGRESS');
        return json(200, <String, Object?>{
          'token': 'access-2',
          'refreshToken': 'refresh-2',
        });
      });
      final result = await refresher.refresh();
      expect(posts, 2);
      expect(result.refreshToken, 'refresh-2');
    });

    test('ALREADY_ROTATED adopts a newer stored token', () async {
      final refresher = build((_) async {
        store.token = 'access-other';
        store.refreshToken = 'refresh-other';
        return _refreshError('REFRESH_TOKEN_ALREADY_ROTATED');
      });
      final result = await refresher.refresh();
      expect(result.refreshToken, 'refresh-other');
      expect(posts, 1);
    });

    test('ALREADY_ROTATED with nothing newer is fatal', () async {
      final refresher =
          build((_) async => _refreshError('REFRESH_TOKEN_ALREADY_ROTATED'));
      await expectLater(
        refresher.refresh(),
        throwsA(isA<RefreshFatalError>()
            .having((e) => e.code, 'code', RefreshErrorCode.alreadyRotated)),
      );
    });

    test('REUSE_DETECTED and NOT_FOUND are fatal at once', () async {
      for (final code in <String>[
        'REFRESH_TOKEN_REUSE_DETECTED',
        'REFRESH_TOKEN_NOT_FOUND',
      ]) {
        posts = 0;
        final refresher = build((_) async => _refreshError(code));
        await expectLater(
          refresher.refresh(),
          throwsA(isA<RefreshFatalError>()
              .having((e) => e.code.wire, 'code', code)),
        );
        expect(posts, 1);
      }
    });

    test('a plain 401, a 5xx and a network error are NOT fatal', () async {
      for (final response in <http.Response>[
        http.Response('nope', 401),
        http.Response('boom', 500),
      ]) {
        final refresher = build((_) async => response);
        await expectLater(
          refresher.refresh(),
          throwsA(isA<RefreshHttpException>()
              .having((e) => e.statusCode, 'status', response.statusCode)),
        );
      }
      final network = build((_) async => throw Exception('offline'));
      await expectLater(
          network.refresh(), throwsA(isNot(isA<RefreshFatalError>())));
      expect(store.refreshToken, 'refresh-1');
    });

    test('a missing refresh token is not fatal', () async {
      store.refreshToken = '';
      final refresher = build((_) async => http.Response('', 500));
      await expectLater(refresher.refresh(), throwsStateError);
      expect(posts, 0);
    });

    test('refreshFunction replaces the built-in endpoint', () async {
      final refresher = build(
        (_) async => fail('the built-in endpoint must not be called'),
        host: () async => const RefreshResult(
          accessToken: 'host-access',
          refreshToken: 'host-refresh',
          fileToken: 'host-ft',
          xmppPassword: 'host-xmpp',
        ),
      );
      final result = await refresher.refresh();
      expect(posts, 0);
      expect(result.token, 'host-access');
      expect(result.refreshToken, 'host-refresh');
      expect(result.fileToken, 'host-ft');
      expect(result.xmppPassword, 'host-xmpp');
      expect(log, <String>['persisted:host-refresh']);
    });

    test('refreshFunction without a refreshToken keeps the stored one',
        () async {
      final refresher = build(
        (_) async => fail('unused'),
        host: () async => const RefreshResult(accessToken: 'host-access'),
      );
      final result = await refresher.refresh();
      expect(result.refreshToken, 'refresh-1');
      expect(store.token, 'host-access');
    });

    test('refreshFunction returning nothing is an error', () async {
      final refresher =
          build((_) async => fail('unused'), host: () async => null);
      await expectLater(refresher.refresh(), throwsStateError);
      expect(log, isEmpty);
    });

    test('refreshQuietly never throws and skips a still valid token', () async {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      store.token = fakeJwt(expSeconds: nowSeconds + 3600);
      final refresher = build((_) async => http.Response('boom', 500));
      expect(await refresher.refreshQuietly(), isNotNull);
      expect(posts, 0);
      // Forced: tries the endpoint, swallows the failure.
      expect(await refresher.refreshQuietly(force: true), isNull);
      expect(posts, 1);
    });

    test('ensureFresh rotates an expiring token and swallows non-fatal errors',
        () async {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      store.token = fakeJwt(expSeconds: nowSeconds + 10);
      final refresher = build((_) async => http.Response('boom', 500));
      await refresher.ensureFresh();
      expect(posts, 1);

      final fatal =
          build((_) async => _refreshError('REFRESH_TOKEN_NOT_FOUND'));
      await expectLater(fatal.ensureFresh(), throwsA(isA<RefreshFatalError>()));
    });
  });

  group('proactive timer', () {
    test('rotates shortly before exp and re-arms itself', () async {
      final store = FakeTokenStore();
      const skew = Duration(hours: 1);
      final expSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;
      // "now" is 40 ms before the moment the rotation is due.
      final due = expSeconds * 1000 - skew.inMilliseconds;
      var clock = DateTime.fromMillisecondsSinceEpoch(due - 40);
      store.token = fakeJwt(expSeconds: expSeconds);
      var posts = 0;
      final refresher = AuthRefresher(
        readStoredTokens: () async => AuthTokens(
            token: store.token ?? '', refreshToken: store.refreshToken ?? ''),
        persistTokens: (tokens) async {
          store.token = tokens.token;
          store.refreshToken = tokens.refreshToken;
        },
        postRefresh: (_) async {
          posts += 1;
          // The new token is good for another two hours.
          clock = DateTime.fromMillisecondsSinceEpoch(due - 40);
          return json(200, <String, Object?>{
            'token': fakeJwt(expSeconds: expSeconds + 7200),
            'refreshToken': 'refresh-2',
          });
        },
        now: () => clock,
        skew: skew,
        minProactiveDelay: const Duration(milliseconds: 10),
      );
      await refresher.scheduleProactive();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      refresher.stopProactive();
      expect(posts, greaterThanOrEqualTo(1));
      expect(store.refreshToken, 'refresh-2');
    });

    test('an opaque token arms nothing', () async {
      final store = FakeTokenStore();
      var posts = 0;
      final refresher = AuthRefresher(
        readStoredTokens: () async =>
            AuthTokens(token: store.token ?? '', refreshToken: 'r'),
        persistTokens: (_) async {},
        postRefresh: (_) async {
          posts += 1;
          return http.Response('', 500);
        },
        minProactiveDelay: const Duration(milliseconds: 1),
      );
      await refresher.scheduleProactive();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(posts, 0);
    });

    test('a fatal verdict from the timer reports onFatal', () async {
      final store = FakeTokenStore();
      const skew = Duration(hours: 1);
      final expSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;
      store.token = fakeJwt(expSeconds: expSeconds);
      final fatal = Completer<RefreshFatalError>();
      final refresher = AuthRefresher(
        readStoredTokens: () async =>
            AuthTokens(token: store.token ?? '', refreshToken: 'r'),
        persistTokens: (_) async {},
        postRefresh: (_) async => _refreshError('REFRESH_TOKEN_NOT_FOUND'),
        onFatal: fatal.complete,
        now: () => DateTime.fromMillisecondsSinceEpoch(
            expSeconds * 1000 - skew.inMilliseconds - 20),
        skew: skew,
        minProactiveDelay: const Duration(milliseconds: 10),
      );
      await refresher.scheduleProactive();
      final error = await fatal.future.timeout(const Duration(seconds: 2));
      expect(error.code, RefreshErrorCode.notFound);
      refresher.stopProactive();
    });
  });

  group('ApiClient refresh contract', () {
    test(
        'POST /v1/users/login/refresh with the refresh token as '
        'Authorization and an empty JSON body', () async {
      final store = FakeTokenStore();
      http.Request? refreshRequest;
      var mainCalls = 0;
      final api = buildApiClient(
        store: store,
        handler: (request) async {
          if (request.url.path == '/v1/users/login/refresh') {
            refreshRequest = request;
            return json(200, <String, Object?>{
              'token': 'access-2',
              'refreshToken': 'refresh-2',
              'fileToken': 'ft-2',
              'xmppPassword': 'xmpp-2',
            });
          }
          mainCalls += 1;
          if (mainCalls == 1) return http.Response('unauthorized', 401);
          expect(request.headers['Authorization'], 'access-2');
          return json(200, <String, Object?>{'ok': true});
        },
      );
      final response = await api.get('/chats/my');
      expect(response['ok'], true);
      expect(mainCalls, 2);
      expect(refreshRequest!.headers['Authorization'], 'refresh-1');
      expect(jsonDecode(refreshRequest!.body), isEmpty);
      // Refresh token first, then the rest.
      expect(store.events, <String>[
        'tokens:access-2:refresh-2',
        'fileToken:ft-2',
        'xmppPassword:xmpp-2',
      ]);
    });

    test('a fatal verdict clears the session and throws RefreshFatalError',
        () async {
      final store = FakeTokenStore();
      final api = buildApiClient(
        store: store,
        handler: (request) async {
          if (request.url.path.endsWith('/login/refresh')) {
            return _refreshError('REFRESH_TOKEN_REUSE_DETECTED');
          }
          return http.Response('unauthorized', 401);
        },
      );
      await expectLater(
          api.get('/chats/my'), throwsA(isA<RefreshFatalError>()));
      expect(store.events, contains('cleared'));
    });

    test('a refresh outage keeps the session and surfaces the 401', () async {
      final store = FakeTokenStore();
      final api = buildApiClient(
        store: store,
        handler: (request) async {
          if (request.url.path.endsWith('/login/refresh')) {
            return http.Response('boom', 503);
          }
          return http.Response('unauthorized', 401);
        },
      );
      await expectLater(
        api.get('/chats/my'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(store.events, isNot(contains('cleared')));
      expect(store.refreshToken, 'refresh-1');
    });

    test('a 401 after the retry is surfaced, not retried again', () async {
      final store = FakeTokenStore();
      var mainCalls = 0;
      var refreshCalls = 0;
      final api = buildApiClient(
        store: store,
        handler: (request) async {
          if (request.url.path.endsWith('/login/refresh')) {
            refreshCalls += 1;
            return json(200, <String, Object?>{
              'token': 'access-$refreshCalls',
              'refreshToken': 'refresh-$refreshCalls',
            });
          }
          mainCalls += 1;
          return http.Response('unauthorized', 401);
        },
      );
      await expectLater(api.get('/chats/my'), throwsA(isA<ApiException>()));
      expect(mainCalls, 2);
      expect(refreshCalls, 1);
    });

    test('a failed login is not run through the refresh path', () async {
      final store = FakeTokenStore();
      var refreshCalls = 0;
      final api = buildApiClient(
        store: store,
        handler: (request) async {
          if (request.url.path.endsWith('/login/refresh')) refreshCalls += 1;
          return http.Response('bad credentials', 401);
        },
      );
      await expectLater(
        api.post('/users/login-with-email',
            body: <String, dynamic>{'email': 'a', 'password': 'b'}),
        throwsA(isA<ApiException>()),
      );
      expect(refreshCalls, 0);
      expect(store.events, isEmpty);
    });

    test('refreshTokens.enabled false never rotates', () async {
      final store = FakeTokenStore();
      var refreshCalls = 0;
      final api = buildApiClient(
        store: store,
        config: const ChatComponentConfig(
          baseUrl: 'https://api.example.test/v1',
          refreshTokens: RefreshTokensConfig(enabled: false),
        ),
        handler: (request) async {
          if (request.url.path.endsWith('/login/refresh')) refreshCalls += 1;
          return http.Response('unauthorized', 401);
        },
      );
      await expectLater(api.get('/chats/my'), throwsA(isA<ApiException>()));
      expect(refreshCalls, 0);
    });

    test('refreshFunction takes over the 401 path', () async {
      final store = FakeTokenStore();
      var mainCalls = 0;
      final api = buildApiClient(
        store: store,
        config: ChatComponentConfig(
          baseUrl: 'https://api.example.test/v1',
          refreshTokens: RefreshTokensConfig(
            enabled: true,
            refreshFunction: () async => const RefreshResult(
              accessToken: 'host-access',
              refreshToken: 'host-refresh',
            ),
          ),
        ),
        handler: (request) async {
          expect(request.url.path, isNot(endsWith('/login/refresh')));
          mainCalls += 1;
          if (mainCalls == 1) return http.Response('unauthorized', 401);
          expect(request.headers['Authorization'], 'host-access');
          return json(200, <String, Object?>{'ok': true});
        },
      );
      expect((await api.get('/chats/my'))['ok'], true);
      expect(store.refreshToken, 'host-refresh');
    });

    test('an expiring access token is rotated before the request goes out',
        () async {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final store = FakeTokenStore(
        token: fakeJwt(expSeconds: nowSeconds + 5),
      );
      final order = <String>[];
      final api = buildApiClient(
        store: store,
        handler: (request) async {
          if (request.url.path.endsWith('/login/refresh')) {
            order.add('refresh');
            return json(200, <String, Object?>{
              'token': 'access-2',
              'refreshToken': 'refresh-2',
            });
          }
          order.add('request:${request.headers['Authorization']}');
          return json(200, <String, Object?>{'ok': true});
        },
      );
      await api.get('/chats/my');
      expect(order, <String>['refresh', 'request:access-2']);
    });
  });
}
