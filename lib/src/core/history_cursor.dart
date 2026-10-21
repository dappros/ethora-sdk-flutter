// Older-history paging cursor of a room (web `historyCursor`, the rules
// pinned by `xmppClient.mamCursor.test.ts`).
//
// The cursor is the server's own RSM `<first>` of the oldest contiguous page
// loaded, an archive id in microseconds. It is NOT derived from the messages
// that got displayed: a page can be made entirely of reactions, receipts or
// deleted rows, display nothing, and still be followed by plenty of history.

/// True for a value that can be an archive cursor (microsecond ids are far
/// above 1e14; client-side ids and timestamps in ms are not).
bool isArchiveCursor(String? value) {
  final n = int.tryParse(value ?? '');
  return n != null && n > 100000000000000;
}

/// The cursor after a MAM page answered.
///
/// - an empty `<first>` keeps the known cursor;
/// - an older page (asked with `before`) moves the cursor back, never forward;
/// - a LATEST page must not pull the cursor forward past an older one when the
///   room already had messages (a late latest-page answer would make the list
///   ask for the page it already holds);
/// - a latest page for a room with no messages sets the cursor from the page.
String? nextHistoryCursor({
  required String? known,
  required String? pageFirst,
  required bool olderPage,
  required bool roomHadMessages,
}) {
  if (!isArchiveCursor(pageFirst)) return known;
  if (!isArchiveCursor(known)) return pageFirst;
  final knownN = int.parse(known!);
  final firstN = int.parse(pageFirst!);
  if (olderPage) return firstN < knownN ? pageFirst : known;
  final keepOlder = roomHadMessages && knownN < firstN;
  return keepOlder ? known : pageFirst;
}

/// The id to ask the next older page `before`: the smaller (older) of the
/// server's cursor and the oldest archived message already loaded. Null when
/// neither exists (ask for the latest page).
String? olderPageAnchor({String? cursor, String? oldestLoaded}) {
  final a = isArchiveCursor(cursor) ? int.parse(cursor!) : null;
  // The loaded ids were already filtered to archive ids by the caller.
  final b = int.tryParse(oldestLoaded ?? '');
  if (a == null && b == null) return null;
  if (a == null) return oldestLoaded;
  if (b == null) return cursor;
  return a <= b ? cursor : oldestLoaded;
}

/// True when an older page moved the cursor back from [anchor]. A page that
/// does not would be asked for again forever.
bool historyPageProgressed({required String? anchor, required String? first}) {
  if (!isArchiveCursor(first)) return false;
  if (!isArchiveCursor(anchor)) return true;
  return int.parse(first!) < int.parse(anchor!);
}
