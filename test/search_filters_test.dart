import 'package:ethora_sdk_flutter/src/core/search_filters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('day validation', () {
    test('accepts real days and rejects roll-over', () {
      expect(isValidDay('2026-07-14'), true);
      expect(isValidDay('2024-02-29'), true);
      expect(isValidDay('2026-02-29'), false);
      expect(isValidDay('2026-02-31'), false);
      expect(isValidDay('2026-13-01'), false);
      expect(isValidDay('2026-7-4'), false);
      expect(isValidDay('14/07/2026'), false);
      expect(isValidDay(''), false);
      expect(isValidDay(null), false);
    });

    test('start and end of day are the local day bounds in UTC', () {
      final start = DateTime.parse(dayStartIso('2026-07-14')!);
      final end = DateTime.parse(dayEndIso('2026-07-14')!);
      expect(start.isUtc, true);
      expect(start.toLocal(), DateTime(2026, 7, 14));
      expect(end.toLocal(), DateTime(2026, 7, 14, 23, 59, 59, 999));
      expect(dayStartIso('2026-02-31'), isNull);
      expect(dayEndIso('nope'), isNull);
    });

    test('a backwards range is detected', () {
      expect(isBackwardsRange('2026-07-15', '2026-07-14'), true);
      expect(isBackwardsRange('2026-07-14', '2026-07-14'), false);
      expect(isBackwardsRange('2026-07-14', ''), false);
      expect(isBackwardsRange('', '2026-07-14'), false);
    });
  });

  group('MessageSearchFilters', () {
    test('counts active filters and builds the bounds', () {
      const filters = MessageSearchFilters(
        fromUserId: 'u1',
        sinceDay: '2026-07-01',
        untilDay: '2026-07-14',
      );
      expect(filters.activeCount, 3);
      expect(filters.since, dayStartIso('2026-07-01'));
      expect(filters.until, dayEndIso('2026-07-14'));
      expect(const MessageSearchFilters().activeCount, 0);
    });

    test('a backwards range sends no dates', () {
      const filters =
          MessageSearchFilters(sinceDay: '2026-07-15', untilDay: '2026-07-01');
      expect(filters.backwards, true);
      expect(filters.since, isNull);
      expect(filters.until, isNull);
    });

    test('an invalid typed day means no bound', () {
      const filters = MessageSearchFilters(sinceDay: '2026-02-31');
      expect(filters.since, isNull);
    });

    test('value equality', () {
      expect(
        const MessageSearchFilters(sinceDay: 'a'),
        const MessageSearchFilters(sinceDay: 'a'),
      );
      expect(
        const MessageSearchFilters(sinceDay: 'a') ==
            const MessageSearchFilters(sinceDay: 'b'),
        false,
      );
    });
  });

  group('matchPeople', () {
    const people = [
      SearchPerson(id: '1', name: 'Anna Smith'),
      SearchPerson(id: '2', name: 'Joanna Doe'),
      SearchPerson(id: '3', name: 'Bob'),
      SearchPerson(id: '1', name: 'Anna Smith'),
    ];

    test('starts-with ranks above contains and duplicates collapse', () {
      final result = matchPeople(people, 'ann');
      expect(result.map((p) => p.id), ['1', '2']);
    });

    test('blank needle matches nothing and limit applies', () {
      expect(matchPeople(people, '  '), isEmpty);
      expect(matchPeople(people, 'a', limit: 1), hasLength(1));
    });
  });

  group('buildSnippet', () {
    test('splits around the first match, case-insensitive', () {
      final parts = buildSnippet('Say Hello to everyone', 'hello');
      expect(parts, [
        const SnippetPart('Say ', match: false),
        const SnippetPart('Hello', match: true),
        const SnippetPart(' to everyone', match: false),
      ]);
    });

    test('the query is never a pattern', () {
      final parts = buildSnippet('cost (a.b) now', '(a.b)');
      expect(parts.where((p) => p.match).single.text, '(a.b)');
    });

    test('a long body is cut with ellipses around the match', () {
      final body =
          '${List.filled(60, 'word').join(' ')} needle ${List.filled(60, 'tail').join(' ')}';
      final parts = buildSnippet(body, 'needle');
      expect(parts.first.text.startsWith('…'), true);
      expect(parts.last.text.endsWith('…'), true);
      expect(parts.any((p) => p.match && p.text == 'needle'), true);
      final total = parts.fold<int>(0, (n, p) => n + p.text.length);
      expect(total, lessThan(190));
    });

    test('no match returns the text unmarked, empty body returns nothing', () {
      expect(buildSnippet('plain text', 'zzz'), [
        const SnippetPart('plain text', match: false),
      ]);
      expect(buildSnippet('   ', 'a'), isEmpty);
    });
  });
}
