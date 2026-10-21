/// What [handlePushPayload] did with a tapped push.
enum PushPayloadOutcome { call, room, pending, unknown }

const Set<String> _callPushTypes = <String>{
  'call',
  'incoming-call',
  'call-token',
  'call-invite',
};

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _firstText(Map<String, dynamic> data, List<String> keys) {
  for (final key in keys) {
    final value = _text(data[key]);
    if (value != null) return value;
  }
  return null;
}

/// True for a call invite push: a marker field (`type`, `pushType`, ...) is
/// one of `call`, `incoming-call`, `call-token`, `call-invite`, or a callId
/// comes with a call-specific field.
bool isCallPush(Map<String, dynamic> data) {
  final marker = (_firstText(data, const <String>[
            'type',
            'pushType',
            'category',
            'messageType',
            'event',
          ]) ??
          '')
      .toLowerCase();
  if (_callPushTypes.contains(marker)) return true;
  // Web callPush.ts: a callId paired with a call-specific field also counts,
  // so a normal message push is never misread as a call.
  final callId =
      _firstText(data, const <String>['callId', 'callid', 'callID']) ?? '';
  final kind = (_firstText(data, const <String>['kind']) ?? '').toLowerCase();
  final hasCallField =
      (_firstText(data, const <String>['callToken', 'livekitToken']) ?? '')
              .isNotEmpty ||
          (_firstText(data, const <String>['callKind']) ?? '').isNotEmpty ||
          kind == 'audio' ||
          kind == 'video';
  return callId.isNotEmpty && hasCallField;
}

/// The room a chat push points at: the first of `jid`, `chatJid`, `roomJid`,
/// `roomJID`.
String? pushRoomJid(Map<String, dynamic> data) =>
    _firstText(data, const <String>['jid', 'chatJid', 'roomJid', 'roomJID']);

/// Bare room JID for a push value: a full JID loses its resource, a bare
/// local part gets the MUC [conference] domain.
String normalizePushRoomJid(String jid, String? conference) {
  final bare = jid.trim().split('/').first;
  if (bare.contains('@')) return bare;
  final domain = (conference ?? '').trim();
  return domain.isEmpty ? bare : '$bare@$domain';
}
