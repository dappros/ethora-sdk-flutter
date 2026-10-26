part of 'chat_component_controller.dart';

/// SASL recovery attempts in a row before the controller gives up and leaves
/// the connection in the error state (reset once XMPP is online again).
const int kMaxXmppAuthRecoveryAttempts = 3;

/// Token rotation write-back and XMPP credential recovery of
/// [ChatComponentController]. The rotation itself lives in [AuthRefresher].
extension ChatControllerAuth on ChatComponentController {
  /// [ApiClient.writeTokens]: persists a rotation and keeps the in-memory
  /// session user in step, so a later `_store.setUser(state.user)` can never
  /// write a burned token back. The refresh token goes first: it is the one a
  /// crash must not lose.
  Future<void> _writeRotatedTokens(
    String accessToken,
    String? refreshToken,
  ) async {
    final hasRefresh = refreshToken != null && refreshToken.isNotEmpty;
    if (hasRefresh) await _store.setRefreshToken(refreshToken);
    await _store.setToken(accessToken);
    if (_disposed) return;
    final current = state.value.user;
    if (current == null) return;
    state.value = state.value.copyWith(
      user: current.copyWith(
        token: accessToken,
        refreshToken: hasRefresh ? refreshToken : null,
      ),
    );
  }

  /// A refresh or recovery produced a fresh SASL password: store it, put it
  /// on the session user and on the live client for its next reconnect.
  Future<void> _onXmppPasswordRefreshed(String password) async {
    _xmpp?.updateXmppPassword(password);
    final current = state.value.user;
    if (current == null || _disposed) return;
    final updated = current.copyWith(xmppPassword: password);
    state.value = state.value.copyWith(user: updated);
    await _store.setUser(updated);
  }

  XmppCredentialRecovery _newXmppCredentialRecovery() {
    return XmppCredentialRecovery(
      refreshEnabled: () => config.refreshTokens?.enabled != false,
      forceRefresh: _apiClient.auth.refresh,
      fetchXmppToken: () async {
        final token = await _store.getToken();
        if (token == null || token.isEmpty) return null;
        try {
          return await _userApi.fetchXmppPassword(userToken: token);
        } catch (_) {
          return null;
        }
      },
      readStoredPassword: () async =>
          (await _store.getUser())?.xmppPassword ??
          state.value.user?.xmppPassword,
      persistPassword: _onXmppPasswordRefreshed,
    );
  }

  /// SASL `not-authorized`: re-mint the XMPP password (forced refresh, then
  /// `/v1/users/xmpp-token`, then the stored one) and reconnect with it.
  Future<void> _recoverXmppAuth(XmppClient xmpp) async {
    if (_disposed || !identical(xmpp, _xmpp)) return;
    if (_xmppAuthRecoveryAttempts >= kMaxXmppAuthRecoveryAttempts) {
      _log(ChatLogLevel.error, ChatLogCategory.xmpp,
          'XMPP credential recovery gave up after $_xmppAuthRecoveryAttempts attempts');
      return;
    }
    _xmppAuthRecoveryAttempts += 1;
    try {
      final credentials = await _xmppCredentialRecovery.recover();
      if (_disposed || !identical(xmpp, _xmpp)) return;
      if (credentials == null) {
        _log(ChatLogLevel.error, ChatLogCategory.xmpp,
            'XMPP credential recovery found no password');
        return;
      }
      _log(ChatLogLevel.info, ChatLogCategory.xmpp,
          'XMPP credential recovery via ${credentials.source.name}');
      xmpp.updateXmppPassword(credentials.password);
      await xmpp.connect();
      // The online handler resets the counter; still counting means this
      // reconnect failed again (and may have queued another attempt).
      if (_xmppAuthRecoveryAttempts == 0) {
        // Rooms are re-joined by the client's own reconnect callback (mid
        // session) or by the bootstrap that is awaiting this recovery.
        state.value = state.value.copyWith(clearErrorMessage: true);
      }
    } on RefreshFatalError {
      if (await _attemptHostRecovery() && identical(xmpp, _xmpp)) {
        // The host handed back a fresh session: reconnect with its password.
        final password = state.value.user?.xmppPassword;
        if (password != null && password.isNotEmpty) {
          xmpp.updateXmppPassword(password);
          await xmpp.connect();
        }
        return;
      }
      await _onSessionExpired();
    } catch (e) {
      _log(ChatLogLevel.error, ChatLogCategory.xmpp,
          'XMPP credential recovery failed: $e');
    }
  }

  /// Web Bug D: our refresh token being dead does not mean the reader is
  /// logged out. A host with `customLogin` or `jwtLogin` keeps its own session
  /// and can hand back a fresh Ethora one, so ask it before giving up.
  /// Single flight. True when a usable session (with XMPP credentials) was
  /// adopted; the stored tokens are then fresh.
  Future<bool> _attemptHostRecovery() {
    final running = _hostRecoveryInFlight;
    if (running != null) return running;
    final run =
        _runHostRecovery().whenComplete(() => _hostRecoveryInFlight = null);
    _hostRecoveryInFlight = run;
    return run;
  }

  Future<bool> _runHostRecovery() async {
    bool usable(ChatUser? user) =>
        user != null &&
        (user.xmppPassword ?? '').isNotEmpty &&
        (user.xmppUsername ?? user.walletAddress ?? '').isNotEmpty;

    Future<bool> adopt(ChatUser user, String via) async {
      await _applyLoggedInUser(user);
      _xmpp?.updateXmppPassword(user.xmppPassword!);
      _log(ChatLogLevel.info, ChatLogCategory.auth,
          'Session recovered via $via');
      return true;
    }

    final custom = config.customLogin;
    if (custom != null && custom.enabled) {
      try {
        final user = await custom.loginFunction();
        if (usable(user)) return adopt(user!, 'customLogin');
      } catch (e) {
        _log(ChatLogLevel.error, ChatLogCategory.auth,
            'customLogin recovery failed: $e');
      }
    }
    final jwt = config.jwtLogin;
    if (jwt != null && jwt.enabled) {
      try {
        final user = await _authService.loginWithJwt(jwt.token);
        if (usable(user)) return adopt(user, 'jwtLogin');
      } catch (e) {
        _log(ChatLogLevel.error, ChatLogCategory.auth,
            'jwtLogin recovery failed: $e');
      }
    }
    return false;
  }

  /// Bootstrap waits here so a recoverable SASL failure is healed before the
  /// rooms are joined.
  Future<void> _awaitXmppAuthRecovery() async {
    Future<void>? seen;
    while (_xmppAuthRecovery != null && !identical(_xmppAuthRecovery, seen)) {
      seen = _xmppAuthRecovery;
      await seen;
    }
  }
}
