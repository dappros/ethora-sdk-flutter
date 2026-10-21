import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> calls;
  late String? storedPassword;

  XmppCredentialRecovery build({
    bool refreshEnabled = true,
    Future<AuthTokens> Function()? forceRefresh,
    Future<String?> Function()? fetchXmppToken,
  }) {
    return XmppCredentialRecovery(
      refreshEnabled: () => refreshEnabled,
      forceRefresh: () {
        calls.add('refresh');
        return (forceRefresh ??
            () async => const AuthTokens(token: 't', refreshToken: 'r'))();
      },
      fetchXmppToken: () {
        calls.add('xmpp-token');
        return (fetchXmppToken ?? () async => null)();
      },
      readStoredPassword: () async {
        calls.add('stored');
        return storedPassword;
      },
      persistPassword: (password) async => calls.add('persist:$password'),
    );
  }

  setUp(() {
    calls = <String>[];
    storedPassword = 'old-password';
  });

  test('order: forced refresh, then xmpp-token, then the stored password',
      () async {
    final recovery = build();
    final credentials = await recovery.recover();
    expect(calls, <String>['refresh', 'xmpp-token', 'stored']);
    expect(credentials!.password, 'old-password');
    expect(credentials.source, XmppCredentialSource.stored);
  });

  test('uses the xmppPassword the refresh returned and stops there', () async {
    final recovery = build(
      forceRefresh: () async => const AuthTokens(
        token: 't',
        refreshToken: 'r',
        xmppPassword: 'from-refresh',
      ),
    );
    final credentials = await recovery.recover();
    expect(calls, <String>['refresh', 'persist:from-refresh']);
    expect(credentials!.source, XmppCredentialSource.refresh);
  });

  test('falls to xmpp-token when the refresh has no password', () async {
    final recovery = build(fetchXmppToken: () async => 'from-token');
    final credentials = await recovery.recover();
    expect(calls, <String>['refresh', 'xmpp-token', 'persist:from-token']);
    expect(credentials!.password, 'from-token');
    expect(credentials.source, XmppCredentialSource.xmppToken);
  });

  test('a failed refresh falls through to xmpp-token', () async {
    final recovery = build(
      forceRefresh: () async => throw Exception('offline'),
      fetchXmppToken: () async => 'from-token',
    );
    final credentials = await recovery.recover();
    expect(calls, <String>['refresh', 'xmpp-token', 'persist:from-token']);
    expect(credentials!.source, XmppCredentialSource.xmppToken);
  });

  test('refresh disabled skips straight to xmpp-token', () async {
    final recovery =
        build(refreshEnabled: false, fetchXmppToken: () async => 'from-token');
    await recovery.recover();
    expect(calls, <String>['xmpp-token', 'persist:from-token']);
  });

  test('a fatal refresh verdict propagates so the caller logs out', () async {
    final recovery = build(
      forceRefresh: () async =>
          throw RefreshFatalError(RefreshErrorCode.notFound),
    );
    await expectLater(recovery.recover(), throwsA(isA<RefreshFatalError>()));
    expect(calls, <String>['refresh']);
  });

  test('a throwing xmpp-token call does not kill recovery', () async {
    final recovery = build(fetchXmppToken: () async => throw Exception('500'));
    final credentials = await recovery.recover();
    expect(credentials!.source, XmppCredentialSource.stored);
  });

  test('nothing at all is null', () async {
    storedPassword = null;
    expect(await build().recover(), isNull);
  });

  test('concurrent recoveries share one run', () async {
    final recovery = build(fetchXmppToken: () async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'from-token';
    });
    final results = await Future.wait(
        <Future<XmppCredentials?>>[recovery.recover(), recovery.recover()]);
    expect(calls.where((c) => c == 'refresh'), hasLength(1));
    expect(results.map((r) => r!.password).toSet(), <String>{'from-token'});
  });
}
