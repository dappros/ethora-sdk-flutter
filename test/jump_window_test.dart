import 'package:ethora_sdk_flutter/src/core/history_cursor.dart';
import 'package:ethora_sdk_flutter/src/core/jump_window.dart';
import 'package:ethora_sdk_flutter/src/models/chat_message.dart';
import 'package:ethora_sdk_flutter/src/models/chat_user.dart';
import 'package:ethora_sdk_flutter/src/networking/stanza_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _room = 'r@conference.x';
const _base = 1700000000000000; // microseconds

ChatMessage _msg(int n,
    {String? text, int? ms, bool isReply = false, String? main}) {
  final id = '${_base + n * 1000000}';
  return ChatMessage(
    id: id,
    roomJid: _room,
    text: text ?? 'message $n',
    user: const ChatUser(xmppUsername: 'a'),
    createdAtMs: ms ?? (_base ~/ 1000) + n * 1000,
    isReply: isReply,
    showInChannel: !isReply,
    mainMessage: main,
  );
}

/// A server archive that answers before, after and time-range queries the way
/// MAM does. Counts the calls.
class _Archive {
  _Archive(this.rows);

  final List<ChatMessage> rows;
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
  bool failAll = false;
  bool Function(Map<String, Object?> call)? failWhen;

  int _id(ChatMessage m) => int.parse(m.id);

  Future<HistoryWindowPage> fetch(
    String roomJid,
    int max, {
    int? before,
    int? after,
    String? start,
    String? end,
  }) async {
    final call = <String, Object?>{
      'max': max,
      'before': before,
      'after': after,
      'start': start,
      'end': end,
    };
    calls.add(call);
    if (failAll || (failWhen?.call(call) ?? false)) {
      return const HistoryWindowPage();
    }
    var pool = rows;
    if (start != null || end != null) {
      final s =
          start == null ? 0 : DateTime.parse(start).millisecondsSinceEpoch;
      final e =
          end == null ? 1 << 62 : DateTime.parse(end).millisecondsSinceEpoch;
      pool =
          pool.where((m) => m.createdAtMs >= s && m.createdAtMs <= e).toList();
    }
    List<ChatMessage> page;
    var complete = false;
    if (after != null) {
      final rest = pool.where((m) => _id(m) > after).toList();
      page = rest.take(max).toList();
      complete = page.length == rest.length;
    } else if (before != null) {
      final rest = pool.where((m) => _id(m) < before).toList();
      page = rest.length > max ? rest.sublist(rest.length - max) : rest;
      complete = page.length == rest.length;
    } else if (start != null || end != null) {
      page = pool.take(max).toList();
      complete = page.length == pool.length;
    } else {
      page = pool.length > max ? pool.sublist(pool.length - max) : pool;
      complete = page.length == pool.length;
    }
    return HistoryWindowPage(
      ok: true,
      messages: page,
      complete: complete,
      first: page.isEmpty ? null : _id(page.first),
      last: page.isEmpty ? null : _id(page.last),
    );
  }
}

List<ChatMessage> _rows(int count) =>
    [for (var i = 1; i <= count; i++) _msg(i)];

void main() {
  group('mamIdCandidates', () {
    test('keeps archive ids only, once', () {
      expect(
        mamIdCandidates(
            ['', '123', '1700000000000000', '1700000000000000', 'abc-def']),
        ['1700000000000000'],
      );
    });
  });

  group('loadJumpWindow', () {
    test('10 before, the target and 10 after, via two parallel queries',
        () async {
      final archive = _Archive(_rows(100));
      final target = archive.rows[49];
      final result = await loadJumpWindow(archive.fetch, _room, [target.id]);
      expect(result, isA<JumpWindowFound>());
      final window = (result as JumpWindowFound).window;
      expect(window.targetId, target.id);
      expect(window.messages.length, 21);
      expect(window.messages.first.id, archive.rows[39].id);
      expect(window.messages.last.id, archive.rows[59].id);
      expect(window.messages.indexWhere((m) => m.id == target.id), 10);
      expect(window.hasOlder, true);
      expect(window.hasNewer, true);
      expect(window.olderCursor, int.parse(archive.rows[39].id));
      expect(window.newerCursor, int.parse(archive.rows[59].id));

      // before: the target itself, after: one microsecond before it
      final id = int.parse(target.id);
      expect(archive.calls, hasLength(2));
      expect(
          archive.calls.any((c) => c['before'] == id && c['max'] == 10), true);
      expect(archive.calls.any((c) => c['after'] == id - 1 && c['max'] == 11),
          true);
    });

    test('a target at the end of the archive has no newer page', () async {
      final archive = _Archive(_rows(30));
      final result =
          await loadJumpWindow(archive.fetch, _room, [archive.rows.last.id]);
      final window = (result as JumpWindowFound).window;
      expect(window.hasNewer, false);
      expect(window.hasOlder, true);
      expect(window.messages.last.id, archive.rows.last.id);
    });

    test('a target at the start of the archive has no older page', () async {
      final archive = _Archive(_rows(30));
      final result =
          await loadJumpWindow(archive.fetch, _room, [archive.rows.first.id]);
      final window = (result as JumpWindowFound).window;
      expect(window.hasOlder, false);
      expect(window.hasNewer, true);
      expect(window.messages.first.id, archive.rows.first.id);
    });

    test('a target that is not in the archive is missing', () async {
      final archive = _Archive(_rows(30));
      final result =
          await loadJumpWindow(archive.fetch, _room, ['${_base + 5}']);
      expect(result, isA<JumpWindowMissing>());
    });

    test('a failed request is unavailable, not missing', () async {
      final archive = _Archive(_rows(30))..failAll = true;
      final result =
          await loadJumpWindow(archive.fetch, _room, [archive.rows[3].id]);
      expect(result, isA<JumpWindowUnavailable>());
    });

    test('ids that are not archive ids and no content are unavailable',
        () async {
      final archive = _Archive(_rows(30));
      final result = await loadJumpWindow(archive.fetch, _room, ['abc', '12']);
      expect(result, isA<JumpWindowUnavailable>());
      expect(archive.calls, isEmpty);
    });

    test('the second candidate is tried when the first is not in the archive',
        () async {
      final archive = _Archive(_rows(30));
      final result = await loadJumpWindow(
        archive.fetch,
        _room,
        ['${_base + 5}', archive.rows[10].id],
      );
      expect(result, isA<JumpWindowFound>());
      expect((result as JumpWindowFound).window.targetId, archive.rows[10].id);
    });

    test('edits, deletes and reactions that came with the pages are applied',
        () async {
      final archive = _Archive(_rows(30));
      final target = archive.rows[10];
      final result = await loadJumpWindow(
        (room, max, {before, after, start, end}) async {
          final page = await archive.fetch(room, max,
              before: before, after: after, start: start, end: end);
          if (after == null) return page;
          return HistoryWindowPage(
            ok: true,
            messages: page.messages,
            complete: page.complete,
            first: page.first,
            last: page.last,
            modifiers: [
              ParsedEdit(roomJid: _room, targetId: target.id, text: 'edited'),
              ParsedDelete(roomJid: _room, targetId: archive.rows[11].id),
            ],
          );
        },
        _room,
        [target.id],
      );
      final window = (result as JumpWindowFound).window;
      final edited = window.messages.firstWhere((m) => m.id == target.id);
      expect(edited.text, 'edited');
      expect(edited.isEdited, true);
      expect(
        window.messages
            .firstWhere((m) => m.id == archive.rows[11].id)
            .isDeleted,
        true,
      );
    });
  });

  group('loadJumpWindowByTime', () {
    test('finds the row by its time and text, then opens the id window',
        () async {
      final rows = _rows(60);
      // a row whose archive id the hit does not know: only time and body
      final wanted = rows[30];
      final archive = _Archive(rows);
      final result = await loadJumpWindow(
        archive.fetch,
        _room,
        const [],
        content: JumpContent(
          createdAtMs: wanted.createdAtMs + 1200,
          body: ' ${wanted.text} ',
        ),
      );
      expect(result, isA<JumpWindowFound>());
      expect((result as JumpWindowFound).window.targetId, wanted.id);
      final lookup = archive.calls.first;
      expect(lookup['max'], 50);
      final start = DateTime.parse(lookup['start']! as String);
      final end = DateTime.parse(lookup['end']! as String);
      expect(end.difference(start).inMilliseconds, 10000);
    });

    test('a row of the same text outside the 5 s window is not a match',
        () async {
      final rows = [
        _msg(1, text: 'hello', ms: 1000000),
        _msg(2, text: 'other', ms: 1003000),
      ];
      final archive = _Archive(rows);
      final result = await loadJumpWindowByTime(
        archive.fetch,
        _room,
        const JumpContent(createdAtMs: 1002000, body: 'hello'),
      );
      // hello is 2 s away: found
      expect(result, isA<JumpWindowFound>());

      final far = await loadJumpWindowByTime(
        _Archive([_msg(1, text: 'hello', ms: 1000000)]).fetch,
        _room,
        const JumpContent(createdAtMs: 1000000 + 8000, body: 'hello'),
      );
      expect(far, isA<JumpWindowMissing>());
    });

    test('picks the closest of several rows with the same text', () async {
      final rows = [
        _msg(1, text: 'ok', ms: 1000000),
        _msg(2, text: 'ok', ms: 1003000),
      ];
      final archive = _Archive(rows);
      final result = await loadJumpWindowByTime(
        archive.fetch,
        _room,
        const JumpContent(createdAtMs: 1002500, body: 'ok'),
      );
      expect((result as JumpWindowFound).window.targetId, rows[1].id);
    });

    test('pages through a busy range up to 4 pages of 50', () async {
      // 120 rows in the range, the wanted one is the last: 3 pages
      final rows = [
        for (var i = 1; i <= 119; i++)
          _msg(i, text: 'noise $i', ms: 5000000 + i),
        _msg(120, text: 'needle', ms: 5000200),
      ];
      final archive = _Archive(rows);
      final result = await loadJumpWindowByTime(
        archive.fetch,
        _room,
        const JumpContent(createdAtMs: 5000200, body: 'needle'),
      );
      expect(result, isA<JumpWindowFound>());
      final lookups = archive.calls.where((c) => c['start'] != null).toList();
      expect(lookups, hasLength(3));
      expect(lookups[0]['after'], isNull);
      expect(lookups[1]['after'], int.parse(rows[49].id));
      expect(lookups[2]['after'], int.parse(rows[99].id));
    });

    test('gives up as unavailable after 4 pages without a match', () async {
      final rows = [
        for (var i = 1; i <= 300; i++)
          _msg(i, text: 'noise $i', ms: 5000000 + i),
      ];
      final archive = _Archive(rows);
      final result = await loadJumpWindowByTime(
        archive.fetch,
        _room,
        const JumpContent(createdAtMs: 5000100, body: 'needle'),
      );
      expect(result, isA<JumpWindowUnavailable>());
      expect(archive.calls.where((c) => c['start'] != null), hasLength(4));
    });

    test('no usable time or text is unavailable', () async {
      final archive = _Archive(_rows(5));
      expect(
        await loadJumpWindowByTime(
            archive.fetch, _room, const JumpContent(body: 'x')),
        isA<JumpWindowUnavailable>(),
      );
      expect(
        await loadJumpWindowByTime(
            archive.fetch, _room, const JumpContent(createdAtMs: 1, body: ' ')),
        isA<JumpWindowUnavailable>(),
      );
    });

    test('a failed lookup is unavailable', () async {
      final archive = _Archive(_rows(5))..failAll = true;
      expect(
        await loadJumpWindowByTime(archive.fetch, _room,
            const JumpContent(createdAtMs: 1000, body: 'message 1')),
        isA<JumpWindowUnavailable>(),
      );
    });
  });

  group('window paging', () {
    test('older page prepends and moves the cursor back', () async {
      final archive = _Archive(_rows(100));
      final found =
          await loadJumpWindow(archive.fetch, _room, [archive.rows[60].id])
              as JumpWindowFound;
      final next = (await loadOlderWindowPage(archive.fetch, found.window))!;
      expect(next.messages.length, found.window.messages.length + 20);
      expect(next.messages.first.id, archive.rows[30].id);
      expect(next.olderCursor, int.parse(archive.rows[30].id));
      expect(next.hasOlder, true);
    });

    test('a page that does not move the cursor ends paging', () async {
      final archive = _Archive(_rows(100));
      final found =
          await loadJumpWindow(archive.fetch, _room, [archive.rows[60].id])
              as JumpWindowFound;
      final stuck = found.window.copyWith(olderCursor: 1);
      final next = (await loadOlderWindowPage(archive.fetch, stuck))!;
      expect(next.hasOlder, false);
      expect(next.olderCursor, 1);
    });

    test('newer page appends, and a failure returns null', () async {
      final archive = _Archive(_rows(100));
      final found =
          await loadJumpWindow(archive.fetch, _room, [archive.rows[20].id])
              as JumpWindowFound;
      final next = (await loadNewerWindowPage(archive.fetch, found.window))!;
      expect(next.messages.last.id, archive.rows[50].id);
      archive.failAll = true;
      expect(await loadNewerWindowPage(archive.fetch, next), isNull);
    });

    test('the far side is trimmed past 300 messages', () async {
      final archive = _Archive(_rows(900));
      var window =
          (await loadJumpWindow(archive.fetch, _room, [archive.rows[700].id])
                  as JumpWindowFound)
              .window;
      for (var i = 0; i < 16; i++) {
        window = (await loadOlderWindowPage(archive.fetch, window))!;
      }
      expect(window.messages.length, kJumpWindowMaxMessages);
      expect(window.hasNewer, true);
      expect(window.newerCursor, int.parse(window.messages.last.id));
      expect(window.messages.first.id, archive.rows[700 - 10 - 16 * 20].id);
    });
  });

  group('findMessageIndex', () {
    final list = [_msg(1), _msg(2), _msg(3)];

    test('by archive id or by the client message id', () {
      expect(findMessageIndex(list, [list[1].id]), 1);
      final withXmpp = [list[0], list[1].copyWith(xmppId: 'send-text-1')];
      expect(findMessageIndex(withXmpp, ['send-text-1']), 1);
      expect(findMessageIndex(list, ['nope']), -1);
    });

    test('by content when there is no id', () {
      final hit = JumpContent(
        createdAtMs: list[2].createdAtMs + 4000,
        body: ' ${list[2].text}',
      );
      expect(findMessageIndex(list, const [], content: hit), 2);
      final late = JumpContent(
        createdAtMs: list[2].createdAtMs + 6000,
        body: list[2].text,
      );
      expect(findMessageIndex(list, const [], content: late), -1);
    });
  });

  group('sorting and merging', () {
    test('sortByArchive orders by archive id and is stable', () {
      final sorted = sortByArchive([_msg(3), _msg(1), _msg(2)]);
      expect(
          sorted.map((m) => m.text), ['message 1', 'message 2', 'message 3']);
    });

    test('mergeWindowMessages keeps one entry per id', () {
      final merged =
          mergeWindowMessages([_msg(1), _msg(2)], [_msg(2), _msg(3)]);
      expect(
          merged.map((m) => m.text), ['message 1', 'message 2', 'message 3']);
    });
  });

  group('history cursor', () {
    const old = '1500000000000000';
    const mid = '1600000000000000';
    const newer = '1700000000000000';

    test('an older page moves the cursor back, never forward', () {
      expect(
        nextHistoryCursor(
            known: mid, pageFirst: old, olderPage: true, roomHadMessages: true),
        old,
      );
      expect(
        nextHistoryCursor(
            known: mid,
            pageFirst: newer,
            olderPage: true,
            roomHadMessages: true),
        mid,
      );
    });

    test(
        'a late LATEST page does not pull the cursor forward past an older one',
        () {
      expect(
        nextHistoryCursor(
            known: old,
            pageFirst: newer,
            olderPage: false,
            roomHadMessages: true),
        old,
      );
    });

    test('a latest page for a room with no messages sets the cursor', () {
      expect(
        nextHistoryCursor(
            known: old,
            pageFirst: newer,
            olderPage: false,
            roomHadMessages: false),
        newer,
      );
      expect(
        nextHistoryCursor(
            known: null,
            pageFirst: newer,
            olderPage: false,
            roomHadMessages: true),
        newer,
      );
    });

    test('an empty or junk first keeps the known cursor', () {
      expect(
        nextHistoryCursor(
            known: mid,
            pageFirst: null,
            olderPage: true,
            roomHadMessages: true),
        mid,
      );
      expect(
        nextHistoryCursor(
            known: mid,
            pageFirst: 'abc',
            olderPage: true,
            roomHadMessages: true),
        mid,
      );
    });

    test('the anchor is the older of the cursor and the oldest loaded row', () {
      expect(olderPageAnchor(cursor: old, oldestLoaded: mid), old);
      expect(olderPageAnchor(cursor: newer, oldestLoaded: mid), mid);
      expect(olderPageAnchor(cursor: null, oldestLoaded: mid), mid);
      expect(olderPageAnchor(cursor: old, oldestLoaded: null), old);
      expect(olderPageAnchor(cursor: null, oldestLoaded: null), isNull);
    });

    test('progress means the page moved the cursor back', () {
      expect(historyPageProgressed(anchor: mid, first: old), true);
      expect(historyPageProgressed(anchor: mid, first: mid), false);
      expect(historyPageProgressed(anchor: mid, first: null), false);
      expect(historyPageProgressed(anchor: null, first: mid), true);
    });
  });
}
