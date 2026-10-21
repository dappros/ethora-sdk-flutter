import 'dart:async';

import 'auth_refresh.dart';

/// Where a recovered XMPP password came from.
enum XmppCredentialSource {
  /// The forced token refresh returned a fresh `xmppPassword`.
  refresh,

  /// `POST /v1/users/xmpp-token`.
  xmppToken,

  /// Nothing newer was available: the stored password, as a last resort.
  stored,
}

class XmppCredentials {
  const XmppCredentials(this.password, this.source);

  final String password;
  final XmppCredentialSource source;
}

/// XMPP credential recovery after SASL `not-authorized`, like web
/// `xmppCredentials.ts` `recoverXmppCredentials`:
///
///  1. when token refresh is enabled, a FORCED refresh (use its
///     `xmppPassword` when it returns one);
///  2. `POST /v1/users/xmpp-token` with body `{}` and `Authorization:
///     {userToken}` -> `{success, xmppPassword}`;
///  3. the stored password, as a last resort.
///
/// Single flight: several reconnect paths can ask at once and share one run.
/// A [RefreshFatalError] from step 1 is rethrown (the session is dead and the
/// caller must log out); any other failure falls through to the next step.
class XmppCredentialRecovery {
  XmppCredentialRecovery({
    required this.refreshEnabled,
    required this.forceRefresh,
    required this.fetchXmppToken,
    required this.readStoredPassword,
    required this.persistPassword,
  });

  /// True when `config.refreshTokens` does not switch refresh off.
  final bool Function() refreshEnabled;

  /// Forced rotation ([AuthRefresher.refresh]); throws like it does.
  final Future<AuthTokens> Function() forceRefresh;

  /// POSTs `/v1/users/xmpp-token` and returns `xmppPassword`, or null.
  final Future<String?> Function() fetchXmppToken;
  final Future<String?> Function() readStoredPassword;

  /// Writes the recovered password to the store and the session user.
  final Future<void> Function(String password) persistPassword;

  Future<XmppCredentials?>? _inflight;

  Future<XmppCredentials?> recover() {
    final inflight = _inflight;
    if (inflight != null) return inflight;
    final run = _recover().whenComplete(() => _inflight = null);
    _inflight = run;
    return run;
  }

  Future<XmppCredentials?> _recover() async {
    if (refreshEnabled()) {
      try {
        final tokens = await forceRefresh();
        final fresh = tokens.xmppPassword;
        if (fresh != null && fresh.isNotEmpty) {
          await persistPassword(fresh);
          return XmppCredentials(fresh, XmppCredentialSource.refresh);
        }
      } on RefreshFatalError {
        rethrow;
      } catch (_) {
        // Network blip or a pass-through error: try the next step.
      }
    }

    try {
      final fresh = await fetchXmppToken();
      if (fresh != null && fresh.isNotEmpty) {
        await persistPassword(fresh);
        return XmppCredentials(fresh, XmppCredentialSource.xmppToken);
      }
    } catch (_) {
      // Never throws: a failure here must not turn a recoverable blip into
      // a dead session.
    }

    final stored = await readStoredPassword();
    if (stored != null && stored.isNotEmpty) {
      return XmppCredentials(stored, XmppCredentialSource.stored);
    }
    return null;
  }
}
