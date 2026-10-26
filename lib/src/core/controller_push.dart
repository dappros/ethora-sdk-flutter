part of 'chat_component_controller.dart';

/// Push notifications of [ChatComponentController]. The SDK has no Firebase
/// dependency: the host obtains the device token and hands it over, and hands
/// a tapped notification's `data` map back via [handlePushPayload].
extension ChatControllerPush on ChatComponentController {
  /// Hands the device token to the SDK. Registers now when signed in,
  /// otherwise keeps it and registers after sign-in. [tokenType] defaults to
  /// auto-detection (64+ hex characters is APNs, else FCM); pass
  /// [PushTokenType.apnsVoip] for the PushKit token. Throws
  /// [PushRegistrationError] when the backend refuses it.
  Future<RegisterPushOutcome> registerPushToken(
    String token, {
    PushTokenType? tokenType,
  }) {
    return _push.registerPushToken(token, tokenType: tokenType);
  }

  /// Forgets the token(s) and removes them from the backend.
  Future<UnregisterPushOutcome> unregisterPushToken({
    PushTokenType? tokenType,
  }) {
    return _push.unregisterPushToken(tokenType: tokenType);
  }

  /// Call from the host's notification tap handler with the push `data`.
  /// Opens the room the push points at; when the room list does not have it
  /// yet it stays pending for 5 minutes. Call pushes go to [onCallPush].
  Future<PushPayloadOutcome> handlePushPayload(Map<String, dynamic> data) {
    return _push.handlePushPayload(data);
  }

  /// Host hook for call pushes: return true when the payload was consumed.
  CallPushHandler? get onCallPush => _push.onCallPush;
  set onCallPush(CallPushHandler? handler) => _push.onCallPush = handler;

  /// Asks `pushNotifications.getPushTokens` again and registers the result
  /// (for example after the OS rotated the token).
  Future<void> refreshPushTokens() => _push.refreshPushTokens();

  /// The user's own push switch (Settings toggle).
  bool get pushEnabledByUser => _push.manager.userEnabled;

  /// True when push is in use (configured or a token handed over) and not
  /// switched off with `pushNotifications.enabled: false`.
  bool get pushConfigured => _push.isConfigured;

  /// Turns push on or off for this user. Off releases the device on the
  /// backend but keeps the token for switching back on.
  Future<void> setPushEnabled(bool enabled) =>
      _push.manager.setUserEnabled(enabled);

  /// Loads the saved push switch (the settings screen calls this once).
  Future<void> loadPushPreferences() => _push.manager.loadPreferences();

  /// Tokens the host handed over.
  List<RegisteredPushToken> get registeredPushTokens => _push.manager.tokens;

  /// MucSub-subscribes a room that appeared after bootstrap.
  Future<void> subscribeRoomForPush(String roomJid) =>
      _push.subscribeRoomForPush(roomJid);
}
