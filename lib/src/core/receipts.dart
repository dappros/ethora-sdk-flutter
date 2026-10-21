import 'dart:async';

import '../models/chat_component_config.dart';
import '../models/chat_message.dart';
import '../models/chat_room.dart';
import '../networking/stanza_parser.dart';

const int _dayMs = 24 * 60 * 60 * 1000;

/// Other members of the room (the sender excluded). The larger of the true
/// `usersCnt` and the loaded member list wins; 0 when the size is unknown.
int roomOtherMembers(ChatRoom? room) {
  final size = room == null ? 0 : room.displayUserCount;
  return size > 0 ? size - 1 : 0;
}

bool _isPrivate(ChatRoom? room) => room?.type == 'private';

/// Web `shouldSendDelivery`: whether this client acks [message] with a
/// XEP-0184 `<received/>`. The caller already excluded own messages and
/// history replays.
bool shouldSendDelivery({
  required ChatRoom? room,
  required ChatMessage message,
  required ReceiptsConfig config,
  required int nowMs,
}) {
  if (config.mode == 'off') return false;
  if (message.id.isEmpty || message.system) return false;
  if (config.mode == 'all') return true;
  if (_isPrivate(room)) return true;
  if (roomOtherMembers(room) > config.deliveryMaxRoomSize) return false;
  final ts = message.timestamp ?? message.createdAtMs;
  if (ts > 0 && nowMs - ts > config.maxAgeDays * _dayMs) return false;
  return true;
}

/// Web `shouldSendRead`: whether this client broadcasts the XEP-0333 read
/// marker for [room].
bool shouldSendRead({required ChatRoom? room, required ReceiptsConfig config}) {
  if (config.mode == 'off') return false;
  if (config.mode == 'all') return true;
  if (_isPrivate(room)) return true;
  return roomOtherMembers(room) <= config.readMaxRoomSize;
}

/// Coalesces delivery receipts per room (web `DeliveryReceiptBatcher`). The
/// first message while no window is open is acked at once; later ones in the
/// window keep only the newest, acked when the window closes.
class DeliveryReceiptBatcher {
  DeliveryReceiptBatcher({
    required this.send,
    Timer Function(Duration, void Function())? timerFactory,
    int Function()? now,
    this.maxAckedIds = 5000,
  })  : _timerFactory = timerFactory ?? ((d, f) => Timer(d, f)),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final void Function(String roomJid, String messageId) send;
  final int maxAckedIds;
  final Timer Function(Duration, void Function()) _timerFactory;
  final int Function() _now;
  final Map<String, _RoomAck> _rooms = <String, _RoomAck>{};
  final Set<String> _acked = <String>{};

  void enqueue(
    String roomJid,
    String messageId,
    int coalesceMs, {
    int? timestamp,
  }) {
    if (roomJid.isEmpty || messageId.isEmpty) return;
    final key = '$roomJid\n$messageId';
    if (_acked.contains(key)) return;
    final ts = timestamp ?? _now();
    final state = _rooms.putIfAbsent(roomJid, _RoomAck.new)
      ..coalesceMs = coalesceMs;
    if (ts < state.lastAckedTs) return;
    if (state.timer != null) {
      final pending = state.pending;
      if (pending == null || ts >= pending.timestamp) {
        state.pending = _PendingAck(messageId, ts);
      }
      return;
    }
    _ack(roomJid, state, messageId, ts);
  }

  void _ack(String roomJid, _RoomAck state, String messageId, int ts) {
    _remember('$roomJid\n$messageId');
    if (ts > state.lastAckedTs) state.lastAckedTs = ts;
    send(roomJid, messageId);
    if (state.coalesceMs <= 0) return;
    state.timer = _timerFactory(
      Duration(milliseconds: state.coalesceMs),
      () => _onWindowEnd(roomJid),
    );
  }

  void _onWindowEnd(String roomJid) {
    final state = _rooms[roomJid];
    if (state == null) return;
    state.timer = null;
    final pending = state.pending;
    state.pending = null;
    if (pending == null) return;
    if (_acked.contains('$roomJid\n${pending.messageId}')) return;
    _ack(roomJid, state, pending.messageId, pending.timestamp);
  }

  void _remember(String key) {
    _acked.add(key);
    if (_acked.length > maxAckedIds) _acked.remove(_acked.first);
  }

  /// Cancels every window and held message (disconnect). Acked ids are kept
  /// so a reconnect replay does not ack them twice.
  void clear() {
    for (final state in _rooms.values) {
      state.timer?.cancel();
    }
    _rooms.clear();
  }

  void dispose() {
    clear();
    _acked.clear();
  }
}

class _PendingAck {
  _PendingAck(this.messageId, this.timestamp);
  final String messageId;
  final int timestamp;
}

class _RoomAck {
  Timer? timer;
  _PendingAck? pending;
  int lastAckedTs = 0;
  int coalesceMs = 1500;
}

/// Rate-limits the XEP-0333 read marker of one room (web
/// `DisplayedMarkerThrottle`): the first mark goes out at once, marks inside
/// [minInterval] are held and only the newest id is sent when the interval
/// ends. [dispose] flushes a held mark first.
class DisplayedMarkerThrottle {
  DisplayedMarkerThrottle({
    required this.send,
    this.minInterval = const Duration(seconds: 3),
    Timer Function(Duration, void Function())? timerFactory,
    int Function()? now,
  })  : _timerFactory = timerFactory ?? ((d, f) => Timer(d, f)),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final void Function(String messageId) send;
  final Duration minInterval;
  final Timer Function(Duration, void Function()) _timerFactory;
  final int Function() _now;
  int _lastSentAt = 0;
  String? _held;
  String? _lastSentId;
  Timer? _timer;

  void mark(String messageId) {
    if (messageId.isEmpty || messageId == _lastSentId) return;
    final elapsed = _now() - _lastSentAt;
    if (_timer == null && elapsed >= minInterval.inMilliseconds) {
      _emit(messageId);
      return;
    }
    _held = messageId;
    _timer ??= _timerFactory(
      Duration(
        milliseconds: (minInterval.inMilliseconds - elapsed)
            .clamp(0, minInterval.inMilliseconds),
      ),
      _flush,
    );
  }

  void _flush() {
    _timer = null;
    final held = _held;
    _held = null;
    if (held != null && held != _lastSentId) _emit(held);
  }

  void _emit(String id) {
    _lastSentAt = _now();
    _lastSentId = id;
    send(id);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    final held = _held;
    _held = null;
    if (held != null && held != _lastSentId) _emit(held);
  }
}

/// Tick state of one own message (web `ReceiptState`).
class ReceiptState {
  const ReceiptState({
    this.seenBy = const <String>[],
    this.deliveredBy = const <String>[],
  });

  /// Other members who have read the message.
  final List<String> seenBy;

  /// Other members who received it (readers included).
  final List<String> deliveredBy;

  bool get seen => seenBy.isNotEmpty;
  bool get delivered => deliveredBy.isNotEmpty;
}

/// Computes the tick state of [messages][index] for the author [me] (a
/// local part). `seen` when another user's read watermark is at or after
/// this message; `delivered` when anyone else received it or read it.
ReceiptState computeReceiptState({
  required List<ChatMessage> messages,
  required int index,
  required ChatRoom? room,
  required String me,
}) {
  final message = messages[index];
  final seen = <String>[];
  final watermarks = room?.lastDisplayedByUser ?? const <String, String>{};
  watermarks.forEach((user, markerId) {
    if (user.toLowerCase() == me.toLowerCase()) return;
    final position = messages.indexWhere((m) => m.id == markerId);
    var covers = false;
    if (position >= 0) {
      covers = position >= index;
    } else {
      final markerTs = timestampFromUnknown(markerId);
      final ts = message.timestamp ?? message.createdAtMs;
      covers = markerTs > 0 && ts > 0 && markerTs >= ts;
    }
    if (covers) seen.add(user);
  });
  final delivered = <String>{
    ...seen,
    for (final user in message.receivedBy.keys)
      if (user.toLowerCase() != me.toLowerCase()) user,
  }.toList();
  return ReceiptState(seenBy: seen, deliveredBy: delivered);
}
