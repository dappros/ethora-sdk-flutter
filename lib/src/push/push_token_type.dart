/// Kind of device token. `apnsVoip` is the PushKit token used for incoming
/// call pushes; it lives in its own registration slot.
enum PushTokenType {
  apns('apns'),
  apnsVoip('apns-voip'),
  fcm('fcm');

  const PushTokenType(this.wire);

  /// Value of the `tokenType` field on the wire.
  final String wire;

  /// Chat and VoIP tokens are registered independently.
  PushSlot get slot => this == apnsVoip ? PushSlot.voip : PushSlot.chat;
}

enum PushSlot { chat, voip }

final RegExp _apnsToken = RegExp(r'^[0-9a-f]{64,}$', caseSensitive: false);

/// 64+ hex characters is an APNs token; anything else is FCM (RN
/// `detectPushTokenType`).
PushTokenType detectPushTokenType(String token) {
  return _apnsToken.hasMatch(token.trim())
      ? PushTokenType.apns
      : PushTokenType.fcm;
}
