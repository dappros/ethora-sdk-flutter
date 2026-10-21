// The seam to the platform's native call UI: CallKit on iOS, the full-screen
// call notification / ConnectionService on Android. The bridge and the
// coordinator only see this interface, so the rules (when to show it, how its
// buttons map to the call) are unit tested under a fake; the real plugin
// lives in flutter_native_call_ui.dart.

import 'call_mode.dart';

/// What the native UI needs to know about a call.
class NativeCallInfo {
  const NativeCallInfo({
    required this.callId,
    required this.callerName,
    required this.kind,
    this.roomName = '',
    this.isGroup = false,
    this.extra = const <String, dynamic>{},
    this.accepted = false,
  });

  final String callId;
  final String callerName;
  final CallKind kind;
  final String roomName;
  final bool isGroup;

  /// Round-tripped through the platform: the push data the call came from, so
  /// an accept after a cold start can rebuild the call.
  final Map<String, dynamic> extra;

  /// The user already accepted it natively.
  final bool accepted;

  /// CallKit wants a UUID for a call.
  String get uuid => callUuid(callId);
}

enum NativeCallEventType { accept, decline, ended, timeout }

class NativeCallEvent {
  const NativeCallEvent({
    required this.type,
    required this.uuid,
    this.callId,
    this.extra = const <String, dynamic>{},
  });

  final NativeCallEventType type;
  final String uuid;

  /// From the round-tripped extra; null for a call this SDK did not report.
  final String? callId;
  final Map<String, dynamic> extra;
}

abstract class NativeCallUi {
  Stream<NativeCallEvent> get events;

  /// Rings: CallKit on iOS, a full-screen notification on Android.
  Future<void> showIncoming(NativeCallInfo info);

  /// Registers an active call so the OS keeps the process alive and shows an
  /// ongoing-call notification (Android). A no-op where the app keeps running
  /// through the audio background mode (iOS).
  Future<void> startOngoing(NativeCallInfo info);

  /// Media is flowing.
  Future<void> markConnected(NativeCallInfo info);

  /// Dismisses the ring or the ongoing call.
  Future<void> end(NativeCallInfo info);

  /// Calls the native layer still has, for a cold start after an accept.
  Future<List<NativeCallInfo>> activeCalls();
}

/// A stable UUID for [callId] (name based, SHA-1 style layout, version 5
/// nibble), so the same call always maps to the same CallKit id. Not a
/// cryptographic hash: it only has to be deterministic and well spread.
String callUuid(String callId) {
  int fnv(String text, int offset) {
    var hash = offset;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash;
  }

  String hex(int value, int width) =>
      (value & ((1 << (width * 4)) - 1)).toRadixString(16).padLeft(width, '0');

  final a = fnv(callId, 0xcbf29ce484222325);
  final b = fnv('$callId#', 0x84222325cbf29ce4);
  final timeLow = hex(a >>> 32, 8);
  final timeMid = hex(a >>> 16, 4);
  final timeHi = '5${hex(a, 3)}';
  final variant = (0x8 | ((b >>> 60) & 0x3)).toRadixString(16);
  final clockSeq = '$variant${hex(b >>> 48, 3)}';
  final node = hex(b, 12);
  return '$timeLow-$timeMid-$timeHi-$clockSeq-$node';
}
