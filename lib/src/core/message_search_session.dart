import 'dart:async';

import 'package:flutter/foundation.dart';

import '../networking/message_search_service.dart';
import 'search_filters.dart';

/// Shortest query that is searched (web `MIN_QUERY_LENGTH`).
const int kMinSearchQueryLength = 2;

/// Pause after the last keystroke before the request goes out.
const Duration kSearchDebounce = Duration(milliseconds: 300);

enum SearchScope { chat, all }

enum MessageSearchStatus { idle, loading, loadingMore, done, error }

/// One search call. The session never builds the query itself, so tests and
/// hosts can inject any backend.
typedef MessageSearchFn = Future<MessageSearchPage> Function({
  required String q,
  String? chatId,
  String? fromUserId,
  String? since,
  String? until,
  required int offset,
  required int limit,
});

/// Debounced search with paging (web `useMessageSearch`).
///
/// A newer query (or scope, or filter) supersedes the request in flight, and
/// a response that arrives after it was superseded is dropped, so a slow
/// answer to "he" can never overwrite the results for "hello".
class MessageSearchSession extends ChangeNotifier {
  MessageSearchSession({
    required MessageSearchFn search,
    this.debounce = kSearchDebounce,
    this.minLength = kMinSearchQueryLength,
    this.pageSize = kMessageSearchPageSize,
  }) : _search = search;

  final MessageSearchFn _search;
  final Duration debounce;
  final int minLength;
  final int pageSize;

  String _query = '';
  SearchScope _scope = SearchScope.all;
  String? _roomName;
  MessageSearchFilters _filters = const MessageSearchFilters();

  MessageSearchStatus _status = MessageSearchStatus.idle;
  List<MessageSearchHit> _items = const <MessageSearchHit>[];
  int _total = 0;
  int _nextOffset = 0;
  Timer? _timer;
  int _requestId = 0;
  bool _disposed = false;

  String get query => _query;
  SearchScope get scope => _scope;
  MessageSearchFilters get filters => _filters;
  MessageSearchStatus get status => _status;
  List<MessageSearchHit> get items => _items;
  int get total => _total;
  int get nextOffset => _nextOffset;

  String get _trimmed => _query.trim();

  /// A backwards date range has no honest result, so it searches nothing
  /// instead of quietly dropping the dates.
  bool get searchable =>
      !_filters.backwards &&
      _trimmed.length >= minLength &&
      (_scope == SearchScope.all || (_roomName ?? '').isNotEmpty);

  bool get hasMore => _nextOffset < _total;

  /// Sets any of the inputs. A change schedules one debounced search.
  void update({
    String? query,
    SearchScope? scope,
    String? roomName,
    MessageSearchFilters? filters,
  }) {
    var changed = false;
    if (query != null && query != _query) {
      _query = query;
      changed = true;
    }
    if (scope != null && scope != _scope) {
      _scope = scope;
      changed = true;
    }
    if (roomName != null && roomName != _roomName) {
      _roomName = roomName;
      changed = true;
    }
    if (filters != null && filters != _filters) {
      _filters = filters;
      changed = true;
    }
    if (!changed) return;
    _reschedule();
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (!searchable) {
      _requestId += 1;
      _status = MessageSearchStatus.idle;
      _items = const <MessageSearchHit>[];
      _total = 0;
      _nextOffset = 0;
      _notify();
      return;
    }
    // Keep showing the previous results while the next ones are awaited.
    _timer = Timer(debounce, () => unawaited(_run(0)));
    _notify();
  }

  Future<void> _run(int offset) async {
    final id = ++_requestId;
    _status = offset > 0
        ? MessageSearchStatus.loadingMore
        : MessageSearchStatus.loading;
    _notify();
    try {
      final page = await _search(
        q: _trimmed,
        chatId: _scope == SearchScope.chat ? _roomName : null,
        fromUserId: _filters.fromUserId,
        since: _filters.since,
        until: _filters.until,
        offset: offset,
        limit: pageSize,
      );
      if (id != _requestId || _disposed) return;
      final append = offset > 0;
      final seen = <String>{
        if (append) ..._items.map((hit) => hit.key),
      };
      final fresh = page.items.where((hit) => seen.add(hit.key)).toList();
      _items = append ? <MessageSearchHit>[..._items, ...fresh] : fresh;
      _total = page.total;
      _nextOffset = page.nextOffset;
      _status = MessageSearchStatus.done;
    } catch (_) {
      if (id != _requestId || _disposed) return;
      _status = MessageSearchStatus.error;
    }
    _notify();
  }

  /// Next page, only when the previous one finished and more is on the server.
  void loadMore() {
    if (_status != MessageSearchStatus.done || !hasMore) return;
    unawaited(_run(_nextOffset));
  }

  /// Repeats the search from the first page (after an error).
  void retry() {
    if (!searchable) return;
    _timer?.cancel();
    unawaited(_run(0));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
