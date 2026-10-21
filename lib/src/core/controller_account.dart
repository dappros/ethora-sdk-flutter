part of 'chat_component_controller.dart';

/// Account settings of [ChatComponentController]: languages, password,
/// export and delete, and the full logout order (web `useLogout`).
extension ChatControllerAccount on ChatComponentController {
  /// Locale the UI captions use: the account's `appLanguage`, else
  /// `config.i18n.locale` (BCP-47; the base language is what is looked up).
  String? get uiLocale => state.value.user?.appLanguage ?? config.i18n?.locale;

  /// Language incoming messages are translated into: the account's
  /// `chatLanguage`, else the reader locale, else the UI locale.
  String? get translationLocale =>
      state.value.user?.chatLanguage ??
      config.translates?.readerLocale ??
      config.i18n?.locale;

  Future<void> _updateUser(ChatUser Function(ChatUser user) change) async {
    final current = state.value.user;
    if (current == null || _disposed) return;
    final updated = change(current);
    state.value = state.value.copyWith(user: updated);
    await _store.setUser(updated);
  }

  /// `PUT /v1/users {appLanguage}`, then the user and the UI locale follow.
  /// Throws [ApiException] when the server refuses.
  Future<void> setAppLanguage(String locale) async {
    final next = locale.trim();
    if (next.isEmpty) return;
    await _userApi.updateAppLanguage(next);
    await _updateUser((user) => user.copyWith(appLanguage: next));
  }

  /// `PUT /v1/users {chatLanguage}`: the language messages are translated
  /// into and the `source` sent with every text.
  Future<void> setChatLanguage(String locale) async {
    final next = locale.trim();
    if (next.isEmpty) return;
    await _userApi.updateChatLanguage(next);
    await _updateUser((user) => user.copyWith(chatLanguage: next));
  }

  /// `PUT /v2/users/me/password`. On failure an [ApiException] whose
  /// `reason` is the server's message.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return _userApi.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  /// `GET /v1/users/exportData`: the account data as JSON bytes.
  Future<List<int>> exportMyData() => _userApi.exportData();

  /// `DELETE /v1/users`, then the normal logout.
  Future<void> deleteAccount() async {
    await _userApi.deleteAccount();
    await logout();
  }

  /// Writes the open room's read marker to the private store when it has no
  /// unread (web `flushLastViewedToPrivateStore`, `onlyIfNoUnread`). Bounded
  /// by [timeout] so logout never hangs on a dead socket.
  Future<void> flushReadMarkers({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final xmpp = _xmpp;
    if (xmpp == null || xmpp.state != ChatConnectionState.online) return;
    final selected = state.value.selectedRoomJid;
    if (selected == null) return;
    final matches = state.value.rooms.where((room) => room.jid == selected);
    if (matches.isEmpty) return;
    final room = matches.first;
    if (room.unreadCount > 0) return;
    var newest = 0;
    for (final message
        in state.value.messagesByRoom[selected] ?? const <ChatMessage>[]) {
      if (message.pending || message.failed || message.system) continue;
      if (message.createdAtMs > newest) newest = message.createdAtMs;
    }
    if (newest <= room.lastViewedTimestamp) return;
    try {
      await _privateStoreSync
          .write(xmpp, roomJid: selected, timestamp: newest)
          .timeout(timeout);
    } catch (_) {
      // Best effort.
    }
  }

  /// Full logout in web order: `onBeforeLogout`; release the push
  /// registration (awaited) in parallel with the read marker flush; stop the
  /// refresh timer; disconnect XMPP; clear the runtime state and the stored
  /// session; `onAfterLogout`.
  Future<void> _runLogout() async {
    final hooks = config.logout;
    try {
      await hooks?.onBeforeLogout?.call();
    } catch (e) {
      _log(ChatLogLevel.error, ChatLogCategory.auth,
          'onBeforeLogout failed: $e');
    }
    _typingStopTimer?.cancel();
    await Future.wait(<Future<void>>[
      _push.releaseOnLogout(),
      flushReadMarkers(),
    ]);
    _apiClient.auth.stopProactive();
    _xmppAuthRecoveryAttempts = 0;
    final xmpp = _xmpp;
    _xmpp = null;
    await xmpp?.disconnect();
    _resetRuntimeState();
    await _store.clearSession();
    state.value = const ChatComponentState(
      isInitialized: false,
      requiresLogin: true,
      connectionState: ChatConnectionState.offline,
    );
    try {
      await hooks?.onAfterLogout?.call();
    } catch (e) {
      _log(
          ChatLogLevel.error, ChatLogCategory.auth, 'onAfterLogout failed: $e');
    }
  }
}
