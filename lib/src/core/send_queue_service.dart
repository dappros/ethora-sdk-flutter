import 'dart:async';
import 'dart:collection';

class SendQueueEntry {
  SendQueueEntry({
    required this.id,
    required this.roomJid,
    required this.task,
    required this.completer,
    this.attempts = 0,
  });

  final String id;
  final String roomJid;
  final Future<bool> Function() task;
  final Completer<bool> completer;
  int attempts;
}

class SendQueueService {
  SendQueueService({this.maxRetries = 2});

  final int maxRetries;
  final Queue<SendQueueEntry> _queue = Queue<SendQueueEntry>();
  final Map<String, SendQueueEntry> _queuedById = <String, SendQueueEntry>{};
  final Set<String> _inFlightIds = <String>{};
  bool _processing = false;
  bool Function()? _canProcess;

  void bindConnectivity(bool Function() canProcess) {
    _canProcess = canProcess;
  }

  Future<bool> enqueue({
    required String id,
    required String roomJid,
    required Future<bool> Function() task,
  }) {
    final existing = _queuedById[id];
    if (existing != null) {
      return existing.completer.future;
    }
    if (_inFlightIds.contains(id)) {
      return Future<bool>.value(true);
    }

    final completer = Completer<bool>();
    final entry = SendQueueEntry(
      id: id,
      roomJid: roomJid,
      task: task,
      completer: completer,
    );
    _queuedById[id] = entry;
    _queue.add(entry);
    _pump();
    return completer.future;
  }

  void resume() {
    _pump();
  }

  void clear() {
    while (_queue.isNotEmpty) {
      final entry = _queue.removeFirst();
      _queuedById.remove(entry.id);
      if (!entry.completer.isCompleted) {
        entry.completer.complete(false);
      }
    }
    _inFlightIds.clear();
  }

  void _pump() {
    if (_processing) return;
    _processing = true;
    () async {
      try {
        while (_queue.isNotEmpty) {
          if (_canProcess != null && _canProcess!() == false) {
            break;
          }
          final entry = _queue.removeFirst();
          _queuedById.remove(entry.id);
          _inFlightIds.add(entry.id);
          entry.attempts += 1;

          var ok = false;
          try {
            ok = await entry.task();
          } catch (_) {
            ok = false;
          } finally {
            _inFlightIds.remove(entry.id);
          }

          if (ok) {
            if (!entry.completer.isCompleted) {
              entry.completer.complete(true);
            }
            continue;
          }

          if (entry.attempts <= maxRetries) {
            _queue.add(entry);
            _queuedById[entry.id] = entry;
            await Future<void>.delayed(const Duration(milliseconds: 120));
            continue;
          }

          if (!entry.completer.isCompleted) {
            entry.completer.complete(false);
          }
        }
      } finally {
        _processing = false;
      }
    }();
  }
}
