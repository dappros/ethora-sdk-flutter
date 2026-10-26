import 'dart:async';

import 'package:ethora_sdk_flutter/src/core/message_search_session.dart';
import 'package:ethora_sdk_flutter/src/core/search_filters.dart';
import 'package:ethora_sdk_flutter/src/networking/message_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

MessageSearchHit _hit(String id) => MessageSearchHit(
      id: id,
      chatId: 'c',
      chatType: 'group',
      room: 'c@conference.x',
      from: 'a_u@x',
      fromUserId: 'u',
      body: 'body $id',
      messageId: '',
      stanzaId: '',
      createdAt: '2026-07-14T10:00:00Z',
    );

class _Call {
  _Call(this.q, this.chatId, this.fromUserId, this.since, this.until,
      this.offset);
  final String q;
  final String? chatId;
  final String? fromUserId;
  final String? since;
  final String? until;
  final int offset;
}

const _debounce = Duration(milliseconds: 20);
const _wait = Duration(milliseconds: 80);

void main() {
  late List<_Call> calls;
  late Future<MessageSearchPage> Function(_Call call) answer;

  MessageSearchSession make() {
    calls = <_Call>[];
    return MessageSearchSession(
      debounce: _debounce,
      search: ({
        required String q,
        String? chatId,
        String? fromUserId,
        String? since,
        String? until,
        required int offset,
        required int limit,
      }) {
        final call = _Call(q, chatId, fromUserId, since, until, offset);
        calls.add(call);
        return answer(call);
      },
    );
  }

  MessageSearchPage page(List<String> ids, {int total = 100, int offset = 0}) =>
      MessageSearchPage(
        items: ids.map(_hit).toList(),
        total: total,
        offset: offset,
        limit: 20,
        nextOffset: offset + ids.length,
      );

  setUp(() {
    answer = (_) async => page(['1', '2'], total: 2);
  });

  test('a query shorter than 2 characters is not searched', () async {
    final session = make();
    session.update(query: 'a');
    await Future<void>.delayed(_wait);
    expect(calls, isEmpty);
    expect(session.searchable, false);
    expect(session.status, MessageSearchStatus.idle);
    session.dispose();
  });

  test('typing is debounced into one call', () async {
    final session = make();
    session.update(query: 'he');
    session.update(query: 'hel');
    session.update(query: 'hell');
    session.update(query: 'hello');
    await Future<void>.delayed(_wait);
    expect(calls.map((c) => c.q), ['hello']);
    expect(session.status, MessageSearchStatus.done);
    expect(session.items.map((h) => h.id), ['1', '2']);
    session.dispose();
  });

  test('the query is trimmed', () async {
    final session = make();
    session.update(query: '  hello  ');
    await Future<void>.delayed(_wait);
    expect(calls.single.q, 'hello');
    session.dispose();
  });

  test('chat scope needs a room and sends chatId, all scope does not',
      () async {
    final session = make();
    session.update(query: 'hello', scope: SearchScope.chat);
    await Future<void>.delayed(_wait);
    expect(calls, isEmpty);
    session.update(roomName: 'app_room');
    await Future<void>.delayed(_wait);
    expect(calls.single.chatId, 'app_room');
    session.update(scope: SearchScope.all);
    await Future<void>.delayed(_wait);
    expect(calls.last.chatId, isNull);
    session.dispose();
  });

  test('filters ride on the request', () async {
    final session = make();
    session.update(
      query: 'hello',
      filters: const MessageSearchFilters(
        fromUserId: 'u7',
        sinceDay: '2026-07-01',
        untilDay: '2026-07-14',
      ),
    );
    await Future<void>.delayed(_wait);
    expect(calls.single.fromUserId, 'u7');
    expect(calls.single.since, dayStartIso('2026-07-01'));
    expect(calls.single.until, dayEndIso('2026-07-14'));
    session.dispose();
  });

  test('a backwards date range searches nothing', () async {
    final session = make();
    session.update(
      query: 'hello',
      filters: const MessageSearchFilters(
        sinceDay: '2026-07-15',
        untilDay: '2026-07-01',
      ),
    );
    await Future<void>.delayed(_wait);
    expect(calls, isEmpty);
    expect(session.searchable, false);
    session.dispose();
  });

  test('load more continues from nextOffset and de-duplicates', () async {
    answer = (call) async => call.offset == 0
        ? page(['1', '2', '3'], total: 5)
        : page(['3', '4', '5'], total: 5, offset: 3);
    final session = make();
    session.update(query: 'hello');
    await Future<void>.delayed(_wait);
    expect(session.hasMore, true);
    session.loadMore();
    await Future<void>.delayed(_wait);
    expect(calls.map((c) => c.offset), [0, 3]);
    expect(session.items.map((h) => h.id), ['1', '2', '3', '4', '5']);
    expect(session.hasMore, false);
    session.loadMore();
    await Future<void>.delayed(_wait);
    expect(calls, hasLength(2));
    session.dispose();
  });

  test('a slow older answer never overwrites a newer one', () async {
    final slow = Completer<MessageSearchPage>();
    answer = (call) =>
        call.q == 'he' ? slow.future : Future.value(page(['9'], total: 1));
    final session = make();
    session.update(query: 'he');
    await Future<void>.delayed(_wait);
    session.update(query: 'hello');
    await Future<void>.delayed(_wait);
    expect(session.items.map((h) => h.id), ['9']);
    slow.complete(page(['1'], total: 1));
    await Future<void>.delayed(_wait);
    expect(session.items.map((h) => h.id), ['9']);
    session.dispose();
  });

  test('an error can be retried', () async {
    var fail = true;
    answer = (_) async {
      if (fail) throw StateError('boom');
      return page(['1'], total: 1);
    };
    final session = make();
    session.update(query: 'hello');
    await Future<void>.delayed(_wait);
    expect(session.status, MessageSearchStatus.error);
    fail = false;
    session.retry();
    await Future<void>.delayed(_wait);
    expect(session.status, MessageSearchStatus.done);
    expect(session.items, hasLength(1));
    session.dispose();
  });

  test('clearing the query resets the results', () async {
    final session = make();
    session.update(query: 'hello');
    await Future<void>.delayed(_wait);
    expect(session.items, isNotEmpty);
    session.update(query: '');
    expect(session.items, isEmpty);
    expect(session.status, MessageSearchStatus.idle);
    session.dispose();
  });
}
