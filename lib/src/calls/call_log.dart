// Call log entries (web helpers/callLogMessage.ts). The server broadcasts a
// `call-state` system message into the room when a call concludes. It carries
//   type="call-state" callId="..." durationMs="<ms>"
//   callerXmppUsername="<who started the call>" isSystemMessage="true"
// and renders as a Telegram/WhatsApp style line:
//   - duration > 0:  "Outgoing call · 12 sec" / "Incoming call · 1 min"
//   - duration == 0: "No answer" (we called) / "Missed call" (they called)
// Direction comes from callerXmppUsername vs the signed-in user. The label is
// built at render time from the meta, so a language switch re-translates
// entries that were already received.

import '../i18n/chat_i18n.dart';
import '../models/chat_message.dart';
import '../models/chat_user.dart';
import 'call_mode.dart';

class CallLogInfo {
  const CallLogInfo({
    required this.callId,
    required this.outgoing,
    required this.durationMs,
    required this.kind,
  });

  final String callId;

  /// We started the call. With no caller info it defaults to incoming (a
  /// safer label than claiming we dialled).
  final bool outgoing;
  final int durationMs;
  final CallKind kind;

  bool get missed => durationMs <= 0;

  /// The log meta of [message], or null when it is not a call log entry.
  /// [selfXmppUsername] is the signed-in user's xmpp username.
  static CallLogInfo? fromMessage(
    ChatMessage message, {
    required String selfXmppUsername,
  }) {
    final data = message.data;
    if ((data['type'] ?? '').toLowerCase() != 'call-state') return null;
    final caller = (data['callerXmppUsername'] ?? '').split('@').first.trim();
    final self = selfXmppUsername.split('@').first.trim();
    return CallLogInfo(
      callId: (data['callId'] ?? data['callid'] ?? '').trim(),
      outgoing: caller.isNotEmpty && caller == self,
      durationMs: int.tryParse(data['durationMs'] ?? '') ?? 0,
      kind: callKindFromName(data['kind']) ?? CallKind.video,
    );
  }

  /// "Outgoing call · 12 sec", "Missed call", "No answer".
  String label(ChatStrings strings) {
    if (durationMs <= 0) {
      return strings.t(outgoing ? 'call.noAnswer' : 'call.missed');
    }
    final totalSeconds = (durationMs / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final duration = totalSeconds < 60
        ? strings.t('call.durationSec', <String, Object>{'n': totalSeconds})
        : seconds == 0
            ? strings.t('call.durationMin', <String, Object>{'n': minutes})
            : strings.t(
                'call.durationMinSec',
                <String, Object>{'m': minutes, 's': seconds},
              );
    final direction = strings.t(outgoing ? 'call.outgoing' : 'call.incoming');
    return '$direction · $duration';
  }
}

/// True for a server call log message.
bool isCallLogMessage(ChatMessage message) =>
    (message.data['type'] ?? '').toLowerCase() == 'call-state';

/// The call log entry built on this device when a call ends (web
/// buildLocalCallLogMessage). The authoritative entry is the server
/// `call-state` broadcast, but it is not guaranteed to arrive, so this keeps
/// the chat log working regardless. [callLogIndexFor] / [mergeCallLog]
/// collapse it with the server copy by callId, so it never doubles.
///
/// The id is `calllog-<callId>`, deterministic, so a re-fire for the same
/// call lands on the same entry.
ChatMessage buildLocalCallLogMessage({
  required String roomJid,
  required String callId,
  required bool outgoing,
  required int durationMs,
  required CallKind kind,
  required String selfXmppUsername,

  /// Who started the call (their xmpp username), used for the direction.
  /// Defaults to us for an outgoing call.
  String? callerXmppUsername,
  required int nowMs,
}) {
  final self = selfXmppUsername.split('@').first;
  final caller = outgoing ? self : (callerXmppUsername ?? '').split('@').first;
  final duration = durationMs < 0 ? 0 : durationMs;
  return ChatMessage(
    id: callId.isEmpty ? 'calllog-$nowMs' : 'calllog-$callId',
    roomJid: roomJid,
    text: 'call-state',
    user: ChatUser(id: self, username: self, xmppUsername: self),
    createdAtMs: nowMs,
    timestamp: nowMs,
    system: true,
    data: <String, String>{
      'type': 'call-state',
      'isSystemMessage': 'true',
      'callId': callId,
      'durationMs': '$duration',
      'callerXmppUsername': caller,
      'kind': kind.name,
    },
  );
}

/// Index of the entry in [messages] that logs the same call as [incoming], or
/// -1 (web dedupes by `callLog.callId` in addRoomMessage).
int callLogIndexFor(List<ChatMessage> messages, ChatMessage incoming) {
  if (!isCallLogMessage(incoming)) return -1;
  final callId =
      (incoming.data['callId'] ?? incoming.data['callid'] ?? '').trim();
  if (callId.isEmpty) return -1;
  return messages.indexWhere(
    (m) =>
        isCallLogMessage(m) &&
        (m.data['callId'] ?? m.data['callid'] ?? '').trim() == callId,
  );
}

/// Which of two entries for the same call survives: the one with the larger
/// duration; on a tie the server copy (it carries the authoritative caller
/// and timestamp).
ChatMessage mergeCallLog(ChatMessage existing, ChatMessage incoming) {
  int duration(ChatMessage m) => int.tryParse(m.data['durationMs'] ?? '') ?? 0;
  bool local(ChatMessage m) => m.id.startsWith('calllog-');
  final a = duration(existing);
  final b = duration(incoming);
  if (b > a) return incoming;
  if (a > b) return existing;
  return local(existing) && !local(incoming) ? incoming : existing;
}
