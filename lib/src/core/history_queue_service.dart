import 'dart:async';

enum HistorySource { active, sendAck, background, normal }

class HistoryTask {
  HistoryTask({
    required this.id,
    required this.roomJid,
    required this.source,
    required this.epoch,
    required this.createdAt,
    required this.run,
    required this.completer,
  });

  final String id;
  final String roomJid;
  final HistorySource source;
  final int epoch;
  final int createdAt;
  final Future<void> Function() run;
  final Completer<void> completer;
}

class HistoryQueueService {
  final List<HistoryTask> _queue = <HistoryTask>[];
  bool _running = false;
  int _highInFlight = 0;
  int _inFlight = 0;
  int maxInFlightHistory = 1;

  Future<void> enqueue(HistoryTask task) {
    _queue.add(task);
    _schedule();
    return task.completer.future;
  }

  void promoteRoom(String roomJid) {
    for (var i = 0; i < _queue.length; i += 1) {
      final task = _queue[i];
      if (task.roomJid == roomJid && task.source == HistorySource.background) {
        _queue[i] = HistoryTask(
          id: task.id,
          roomJid: task.roomJid,
          source: HistorySource.active,
          epoch: task.epoch,
          createdAt: task.createdAt,
          run: task.run,
          completer: task.completer,
        );
      }
    }
    _schedule();
  }

  void clear() {
    for (final task in _queue) {
      if (!task.completer.isCompleted) {
        task.completer.complete();
      }
    }
    _queue.clear();
  }

  void resume() {
    _schedule();
  }

  int _priority(HistorySource source) {
    switch (source) {
      case HistorySource.active:
        return 0;
      case HistorySource.sendAck:
        return 1;
      case HistorySource.normal:
        return 1;
      case HistorySource.background:
        return 2;
    }
  }

  void _schedule() {
    if (_running) return;
    _running = true;
    () async {
      try {
        while (_queue.isNotEmpty) {
          final hasHighPending = _queue.any(
            (task) => _priority(task.source) <= 1,
          );
          final canRunRegular = _inFlight < maxInFlightHistory;
          final canRunHighBypass = hasHighPending && _highInFlight < 1;
          if (!canRunRegular && !canRunHighBypass) {
            break;
          }

          _queue.sort((a, b) {
            final byPriority = _priority(
              a.source,
            ).compareTo(_priority(b.source));
            if (byPriority != 0) return byPriority;
            return a.createdAt.compareTo(b.createdAt);
          });
          final task = _queue.removeAt(0);

          _inFlight += 1;
          if (_priority(task.source) <= 1) {
            _highInFlight += 1;
          }

          try {
            await task.run();
            if (!task.completer.isCompleted) {
              task.completer.complete();
            }
          } catch (_) {
            if (!task.completer.isCompleted) {
              task.completer.complete();
            }
          } finally {
            _inFlight = (_inFlight - 1).clamp(0, 999999);
            if (_priority(task.source) <= 1) {
              _highInFlight = (_highInFlight - 1).clamp(0, 999999);
            }
          }
        }
      } finally {
        _running = false;
      }
    }();
  }
}
