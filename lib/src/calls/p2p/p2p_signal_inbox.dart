// Routes incoming p2p signals to the call that owns them (web calls/p2p/
// signalInbox.ts).
//
// Signals can arrive before anyone is listening: the caller's offer and first
// candidates are on the wire while the callee is still on the ring screen (the
// controller only starts after Accept), and may even overtake the relayed
// call-token that tells the callee the call exists. So signals for a callId
// with no listener are held briefly and replayed in order when a controller
// attaches. The hold is small and bounded on purpose: a signal for a call that
// never materialises is just dropped when its time is up, so unknown callIds
// stay inert (they never raise UI and never grow memory without limit).

import 'p2p_signal.dart';

enum SignalDelivery { delivered, buffered, dropped }

typedef P2PSignalHandler = void Function(P2PSignal signal);

const int _closedMemory = 16;

class P2PSignalInbox {
  P2PSignalInbox({
    this.ttlMs = 20000,
    this.maxPendingCalls = 8,
    this.maxPerCall = 96,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// How long signals for a call with no listener are kept.
  final int ttlMs;

  /// Most distinct unclaimed callIds held at once (oldest dropped first).
  final int maxPendingCalls;

  /// Most signals kept per unclaimed call.
  final int maxPerCall;
  final int Function() _now;

  // Insertion ordered, so `.keys.first` is the oldest.
  final Map<String, ({int firstAt, List<P2PSignal> signals})> _pending =
      <String, ({int firstAt, List<P2PSignal> signals})>{};
  final Map<String, P2PSignalHandler> _handlers = <String, P2PSignalHandler>{};

  // Calls that already ended: late stragglers for them are dropped instead of
  // being buffered for a controller that will never come.
  final List<String> _closed = <String>[];

  void _sweep() {
    final cutoff = _now() - ttlMs;
    _pending.removeWhere((_, entry) => entry.firstAt < cutoff);
  }

  SignalDelivery receive(P2PSignal signal) {
    final handler = _handlers[signal.callId];
    if (handler != null) {
      handler(signal);
      return SignalDelivery.delivered;
    }
    if (_closed.contains(signal.callId)) return SignalDelivery.dropped;

    _sweep();
    var entry = _pending[signal.callId];
    if (entry == null) {
      if (_pending.length >= maxPendingCalls) {
        _pending.remove(_pending.keys.first);
      }
      entry = (firstAt: _now(), signals: <P2PSignal>[]);
      _pending[signal.callId] = entry;
    }
    if (entry.signals.length >= maxPerCall) return SignalDelivery.dropped;
    entry.signals.add(signal);
    return SignalDelivery.buffered;
  }

  /// Starts delivering a call's signals to [handler], replaying anything held
  /// for it first (in arrival order). Returns a detach function that also
  /// marks the call closed.
  void Function() attach(String callId, P2PSignalHandler handler) {
    _closed.remove(callId);

    _sweep();
    final held = _pending.remove(callId);
    _handlers[callId] = handler;
    if (held != null) {
      for (final signal in held.signals) {
        handler(signal);
      }
    }
    return () {
      if (identical(_handlers[callId], handler)) _handlers.remove(callId);
      close(callId);
    };
  }

  /// The call is over: forget held signals and drop future stragglers.
  void close(String callId) {
    _pending.remove(callId);
    if (!_closed.contains(callId)) {
      _closed.add(callId);
      if (_closed.length > _closedMemory) _closed.removeAt(0);
    }
  }

  void clear() {
    _pending.clear();
    _handlers.clear();
    _closed.clear();
  }
}
