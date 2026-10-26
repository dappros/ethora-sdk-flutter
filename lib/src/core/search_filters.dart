// Filter and display helpers of message search (web
// `MessageSearchModal/searchFilters.ts`, `snippet.ts`).

final RegExp _dayShape = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// True for a real calendar day written `YYYY-MM-DD`. `2026-02-31` is NOT a
/// day (no roll-over into March).
bool isValidDay(String? day) => _parseDay(day) != null;

DateTime? _parseDay(String? day, {bool endOfDay = false}) {
  final match = _dayShape.firstMatch(day ?? '');
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final date = int.parse(match.group(3)!);
  final parsed = endOfDay
      ? DateTime(year, month, date, 23, 59, 59, 999)
      : DateTime(year, month, date);
  if (parsed.year != year || parsed.month != month || parsed.day != date) {
    return null;
  }
  return parsed;
}

/// `2026-07-14` to that day's first instant in the reader's time zone, as an
/// ISO 8601 UTC string.
String? dayStartIso(String? day) => _parseDay(day)?.toUtc().toIso8601String();

/// The day's LAST instant, not just the date. The server reads a bare date in
/// `until` as midnight at the start of that day, which would silently
/// exclude the whole day the reader picked.
String? dayEndIso(String? day) =>
    _parseDay(day, endOfDay: true)?.toUtc().toIso8601String();

/// True when both days are set and the range runs backwards. Compared as
/// text, which orders `YYYY-MM-DD` correctly.
bool isBackwardsRange(String? from, String? to) =>
    (from ?? '').isNotEmpty &&
    (to ?? '').isNotEmpty &&
    from!.compareTo(to!) > 0;

/// Sender, since and until chosen in the filter panel.
class MessageSearchFilters {
  const MessageSearchFilters({
    this.fromUserId,
    this.sinceDay = '',
    this.untilDay = '',
  });

  /// A room member's `_id`.
  final String? fromUserId;

  /// `YYYY-MM-DD` as typed. An invalid or empty value means no bound.
  final String sinceDay;
  final String untilDay;

  bool get backwards => isBackwardsRange(sinceDay, untilDay);

  /// Count shown on the filter toggle.
  int get activeCount =>
      ((fromUserId ?? '').isNotEmpty ? 1 : 0) +
      (sinceDay.isNotEmpty ? 1 : 0) +
      (untilDay.isNotEmpty ? 1 : 0);

  /// Sent as `since`. A backwards range searches nothing, so no bound.
  String? get since => backwards ? null : dayStartIso(sinceDay);
  String? get until => backwards ? null : dayEndIso(untilDay);

  MessageSearchFilters copyWith({
    String? fromUserId,
    bool clearSender = false,
    String? sinceDay,
    String? untilDay,
  }) {
    return MessageSearchFilters(
      fromUserId: clearSender ? null : (fromUserId ?? this.fromUserId),
      sinceDay: sinceDay ?? this.sinceDay,
      untilDay: untilDay ?? this.untilDay,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MessageSearchFilters &&
      other.fromUserId == fromUserId &&
      other.sinceDay == sinceDay &&
      other.untilDay == untilDay;

  @override
  int get hashCode => Object.hash(fromUserId, sinceDay, untilDay);
}

/// A person the sender filter can pick.
class SearchPerson {
  const SearchPerson({required this.id, required this.name});
  final String id;
  final String name;
}

/// Up to [limit] people whose name contains [needle], best matches first (a
/// name that STARTS with it ranks above one that merely contains it). Rooms
/// can have thousands of members, so this never returns them all.
List<SearchPerson> matchPeople(
  Iterable<SearchPerson> people,
  String needle, {
  int limit = 8,
}) {
  final wanted = needle.trim().toLowerCase();
  if (wanted.isEmpty) return const <SearchPerson>[];
  final starts = <SearchPerson>[];
  final contains = <SearchPerson>[];
  final seen = <String>{};
  for (final person in people) {
    if (person.id.isEmpty || person.name.isEmpty || seen.contains(person.id)) {
      continue;
    }
    final at = person.name.toLowerCase().indexOf(wanted);
    if (at == -1) continue;
    seen.add(person.id);
    (at == 0 ? starts : contains).add(person);
    if (starts.length >= limit) break;
  }
  return <SearchPerson>[...starts, ...contains].take(limit).toList();
}

/// A run of a snippet, [match] is the part to emphasise.
class SnippetPart {
  const SnippetPart(this.text, {required this.match});
  final String text;
  final bool match;

  @override
  bool operator ==(Object other) =>
      other is SnippetPart && other.text == text && other.match == match;

  @override
  int get hashCode => Object.hash(text, match);

  @override
  String toString() => 'SnippetPart($text, match: $match)';
}

const int _contextBefore = 36;
const int _maxLength = 150;

/// The part of a message worth showing for a hit: a window around the first
/// match, cut on word boundaries with ellipses, split into matching and
/// non-matching runs. Plain substring, case-insensitive; the query is never
/// used as a pattern.
List<SnippetPart> buildSnippet(String body, String query) {
  final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  final needle = query.trim().toLowerCase();
  if (text.isEmpty) return const <SnippetPart>[];

  final at = needle.isEmpty ? -1 : text.toLowerCase().indexOf(needle);

  var start = 0;
  if (at > _contextBefore) {
    start = at - _contextBefore;
    final space = text.indexOf(' ', start);
    if (space != -1 && space < at) start = space + 1;
  }
  var end = start + _maxLength < text.length ? start + _maxLength : text.length;
  if (end < text.length) {
    final space = text.lastIndexOf(' ', end);
    if (space > start + _maxLength / 2 && space > at + needle.length) {
      end = space;
    }
  }

  final prefix = start > 0 ? '…' : '';
  final suffix = end < text.length ? '…' : '';
  final slice = text.substring(start, end);

  if (at == -1 || at < start || at + needle.length > end) {
    return <SnippetPart>[SnippetPart('$prefix$slice$suffix', match: false)];
  }

  final from = at - start;
  final parts = <SnippetPart>[];
  if (prefix.isNotEmpty || from > 0) {
    parts.add(SnippetPart('$prefix${slice.substring(0, from)}', match: false));
  }
  parts.add(
      SnippetPart(slice.substring(from, from + needle.length), match: true));
  final rest = slice.substring(from + needle.length);
  if (rest.isNotEmpty || suffix.isNotEmpty) {
    parts.add(SnippetPart('$rest$suffix', match: false));
  }
  return parts;
}
