import '../models/chat_message.dart';
import '../networking/stanza_parser.dart';

// Pure logic of "jump to message" (web `helpers/jumpWindow.ts`,
// `jumpThread.ts`, `useJumpToMessage.ts`). Nothing here touches the
// controller: the MAM fetcher is injected so it can be tested without a
// socket.

/// Messages shown above and below the target when a window opens.
const int kJumpWindowBefore = 10;
const int kJumpWindowAfter = 10;

/// Page size for loading more once the reader scrolls toward either edge.
const int kJumpWindowPage = 20;

/// The window is trimmed on the far side past this many messages.
const int kJumpWindowMaxMessages = 300;

/// A target already loaded and at most this far from the newest message is
/// reached by scrolling the live list. Farther is fetched as a window.
const int kNearLiveMessages = 300;

/// A jump request expires after this long.
const Duration kJumpTtl = Duration(seconds: 60);

/// A jump into a room that is still opening waits this long for its live
/// list before asking the archive directly.
const Duration kRoomOpeningGrace = Duration(seconds: 4);
const Duration kRoomOpeningPoll = Duration(milliseconds: 700);

/// Fallback paging: pages of [kJumpPageSize], at most [kMaxHistoryPages],
/// give up after [kMaxPageFailures] failures in a row.
const int kMaxHistoryPages = 40;
const int kJumpPageSize = 100;
const int kMaxPageFailures = 3;

/// How far apart the archive's timestamp and the transcript's may be for the
/// same message.
const int kContentMatchWindowMs = 5000;
const int kTimeLookupPage = 50;
const int kTimeLookupMaxPages = 4;

/// One page of a windowed MAM query, returned instead of stored.
class HistoryWindowPage {
  const HistoryWindowPage({
    this.ok = false,
    this.messages = const <ChatMessage>[],
    this.complete = false,
    this.first,
    this.last,
    this.modifiers = const <ParsedStanza>[],
  });

  /// False when the request failed or timed out.
  final bool ok;

  /// Ascending by time (oldest first), whichever direction was paged.
  final List<ChatMessage> messages;

  /// The server's `<fin complete>`: nothing more in that direction.
  final bool complete;

  /// RSM `<first>` and `<last>` archive ids (microseconds).
  final int? first;
  final int? last;

  /// Edits, deletes and reactions that arrived in the page.
  final List<ParsedStanza> modifiers;
}

/// Fetches one MAM page for a window. [before] and [after] are exclusive
/// archive ids; [start] and [end] are ISO instants.
typedef HistoryWindowFetcher = Future<HistoryWindowPage> Function(
  String roomJid,
  int max, {
  int? before,
  int? after,
  String? start,
  String? end,
});

/// A slice of archive around a jump target.
class JumpWindow {
  const JumpWindow({
    required this.roomJid,
    required this.messages,
    required this.targetId,
    this.olderCursor,
    this.hasOlder = false,
    this.newerCursor,
    this.hasNewer = false,
  });

  final String roomJid;

  /// Ascending by time.
  final List<ChatMessage> messages;

  /// Id of the message the jump named, as it appears in [messages].
  final String targetId;

  /// RSM cursor (microseconds) to continue older paging from.
  final int? olderCursor;
  final bool hasOlder;
  final int? newerCursor;
  final bool hasNewer;

  JumpWindow copyWith({
    List<ChatMessage>? messages,
    int? olderCursor,
    bool? hasOlder,
    int? newerCursor,
    bool? hasNewer,
  }) {
    return JumpWindow(
      roomJid: roomJid,
      messages: messages ?? this.messages,
      targetId: targetId,
      olderCursor: olderCursor ?? this.olderCursor,
      hasOlder: hasOlder ?? this.hasOlder,
      newerCursor: newerCursor ?? this.newerCursor,
      hasNewer: hasNewer ?? this.hasNewer,
    );
  }
}

sealed class JumpWindowResult {
  const JumpWindowResult();
}

/// The window around the target is ready to be shown.
class JumpWindowFound extends JumpWindowResult {
  const JumpWindowFound(this.window);
  final JumpWindow window;
}

/// The server answered, and the target is not in the archive.
class JumpWindowMissing extends JumpWindowResult {
  const JumpWindowMissing();
}

/// No usable id, or a request failed: use the paging path instead.
class JumpWindowUnavailable extends JumpWindowResult {
  const JumpWindowUnavailable();
}

/// What a hit with no archive id can be located by.
class JumpContent {
  const JumpContent({this.createdAtMs, this.body});

  final int? createdAtMs;
  final String? body;

  bool get usable => createdAtMs != null && (body ?? '').trim().isNotEmpty;
}

final RegExp _mamId = RegExp(r'^\d{13,}$');

/// True for an id that can be an archive id (microsecond stanza id).
bool isArchiveId(String? id) => id != null && _mamId.hasMatch(id);

/// The ids that can be archive ids, in order, without duplicates.
List<String> mamIdCandidates(Iterable<String> ids) {
  final seen = <String>{};
  return <String>[
    for (final id in ids)
      if (isArchiveId(id) && seen.add(id)) id,
  ];
}

/// Fetches about [kJumpWindowBefore] messages before the target, the target
/// and about [kJumpWindowAfter] after it: two MAM queries in parallel (the
/// target itself comes with the "after" page, asked from one microsecond
/// before it). Nothing is written anywhere here.
Future<JumpWindowResult> loadJumpWindow(
  HistoryWindowFetcher fetch,
  String roomJid,
  List<String> ids, {
  JumpContent? content,
}) async {
  final candidates = mamIdCandidates(ids);
  if (candidates.isEmpty) {
    return content != null && content.usable
        ? loadJumpWindowByTime(fetch, roomJid, content)
        : const JumpWindowUnavailable();
  }

  // Almost always one candidate; a second is only tried when the first one is
  // not an archive id after all (the server then does not return it).
  for (final candidate in candidates) {
    final id = int.parse(candidate);
    final results = await Future.wait(<Future<HistoryWindowPage>>[
      fetch(roomJid, kJumpWindowBefore, before: id),
      fetch(roomJid, kJumpWindowAfter + 1, after: id - 1),
    ]);
    final older = results[0];
    final newer = results[1];
    if (!older.ok || !newer.ok) return const JumpWindowUnavailable();

    final target = newer.messages.where((m) => m.id == candidate).firstOrNull;
    if (target == null) continue;

    final messages = applyWindowModifiers(
      sortByArchive(<ChatMessage>[...older.messages, ...newer.messages]),
      <ParsedStanza>[...older.modifiers, ...newer.modifiers],
    );
    return JumpWindowFound(JumpWindow(
      roomJid: roomJid,
      messages: messages,
      targetId: target.id,
      olderCursor: older.first ?? id,
      hasOlder: !older.complete && older.first != null,
      newerCursor: newer.last ?? id,
      hasNewer: !newer.complete && newer.last != null,
    ));
  }
  // None of the ids was an archive id. A hit that also knows its text and
  // time can still be located by them.
  if (content != null && content.usable) {
    return loadJumpWindowByTime(fetch, roomJid, content);
  }
  return const JumpWindowMissing();
}

/// For a hit with no usable archive id (older archive documents carry
/// neither a stanza id nor a message id): ask the server for the rows within
/// a few seconds of its timestamp (MAM start/end filter), find the one with
/// the same text, and continue as the id-based window does with that row's
/// id. 'Missing' only when the server said the range holds no such row.
Future<JumpWindowResult> loadJumpWindowByTime(
  HistoryWindowFetcher fetch,
  String roomJid,
  JumpContent content,
) async {
  final wanted = content.createdAtMs;
  final body = (content.body ?? '').trim();
  if (wanted == null || body.isEmpty) return const JumpWindowUnavailable();

  final start = DateTime.fromMillisecondsSinceEpoch(
    wanted - kContentMatchWindowMs,
    isUtc: true,
  ).toIso8601String();
  final end = DateTime.fromMillisecondsSinceEpoch(
    wanted + kContentMatchWindowMs,
    isUtc: true,
  ).toIso8601String();

  int? after;
  ChatMessage? best;
  for (var page = 0; page < kTimeLookupMaxPages; page += 1) {
    final result = await fetch(
      roomJid,
      kTimeLookupPage,
      start: start,
      end: end,
      after: after,
    );
    if (!result.ok) return const JumpWindowUnavailable();
    for (final message in result.messages) {
      if (message.text.trim() != body) continue;
      final gap = (message.createdAtMs - wanted).abs();
      if (gap > kContentMatchWindowMs) continue;
      if (best == null || gap < (best.createdAtMs - wanted).abs()) {
        best = message;
      }
    }
    if (best != null) break;
    if (result.complete || result.last == null) {
      return const JumpWindowMissing();
    }
    after = result.last;
  }
  if (best == null) return const JumpWindowUnavailable();
  if (!isArchiveId(best.id)) return const JumpWindowUnavailable();
  return loadJumpWindow(fetch, roomJid, <String>[best.id]);
}

/// The page above [window]; null when the request failed. A page that does
/// not move the cursor would be asked for again forever, so it ends paging.
Future<JumpWindow?> loadOlderWindowPage(
  HistoryWindowFetcher fetch,
  JumpWindow window,
) async {
  final cursor = window.olderCursor;
  if (cursor == null) return window.copyWith(hasOlder: false);
  final page = await fetch(window.roomJid, kJumpWindowPage, before: cursor);
  if (!page.ok) return null;
  final progressed = page.first != null && page.first! < cursor;
  final merged = mergeWindowMessages(
    applyWindowModifiers(page.messages, page.modifiers),
    window.messages,
  );
  var next = window.copyWith(
    messages: merged,
    olderCursor: progressed ? page.first : cursor,
    hasOlder: progressed && !page.complete,
  );
  if (next.messages.length > kJumpWindowMaxMessages) {
    // The reader is going up: drop the far (newest) side and page it again
    // if they come back down.
    final kept = next.messages.take(kJumpWindowMaxMessages).toList();
    next = next.copyWith(
      messages: kept,
      newerCursor: int.tryParse(kept.last.id) ?? next.newerCursor,
      hasNewer: true,
    );
  }
  return next;
}

/// The page below [window]; null when the request failed.
Future<JumpWindow?> loadNewerWindowPage(
  HistoryWindowFetcher fetch,
  JumpWindow window,
) async {
  final cursor = window.newerCursor;
  if (cursor == null) return window.copyWith(hasNewer: false);
  final page = await fetch(window.roomJid, kJumpWindowPage, after: cursor);
  if (!page.ok) return null;
  final progressed = page.last != null && page.last! > cursor;
  final merged = mergeWindowMessages(
    window.messages,
    applyWindowModifiers(page.messages, page.modifiers),
  );
  var next = window.copyWith(
    messages: merged,
    newerCursor: progressed ? page.last : cursor,
    hasNewer: progressed && !page.complete,
  );
  if (next.messages.length > kJumpWindowMaxMessages) {
    final kept = next.messages
        .skip(next.messages.length - kJumpWindowMaxMessages)
        .toList();
    next = next.copyWith(
      messages: kept,
      olderCursor: int.tryParse(kept.first.id) ?? next.olderCursor,
      hasOlder: true,
    );
  }
  return next;
}

/// [a] then [b], one entry per message id (the first wins), ascending.
List<ChatMessage> mergeWindowMessages(
  List<ChatMessage> a,
  List<ChatMessage> b,
) {
  final seen = <String>{};
  final merged = <ChatMessage>[
    for (final m in <ChatMessage>[...a, ...b])
      if (seen.add(m.id)) m,
  ];
  return sortByArchive(merged);
}

/// Ascending by archive id (microseconds), falling back to the message time
/// when an id is not numeric. Stable.
List<ChatMessage> sortByArchive(List<ChatMessage> messages) {
  int key(ChatMessage m) {
    final id = int.tryParse(m.id);
    return id != null && id > 0 ? id : m.createdAtMs * 1000;
  }

  final indexed = messages.asMap().entries.toList()
    ..sort((x, y) {
      final byKey = key(x.value).compareTo(key(y.value));
      return byKey != 0 ? byKey : x.key.compareTo(y.key);
    });
  return indexed.map((e) => e.value).toList();
}

/// Applies the edits, deletes and reactions that came with an archive page
/// to the page's own messages (they are not in the live list, so the
/// controller's handlers cannot reach them).
List<ChatMessage> applyWindowModifiers(
  List<ChatMessage> messages,
  List<ParsedStanza> modifiers,
) {
  if (modifiers.isEmpty) return messages;
  final result = List<ChatMessage>.of(messages);
  int indexOf(String targetId) =>
      result.indexWhere((m) => m.id == targetId || m.xmppId == targetId);
  for (final modifier in modifiers) {
    switch (modifier) {
      case ParsedEdit(:final targetId, :final text):
        final i = indexOf(targetId);
        if (i >= 0) result[i] = result[i].copyWith(text: text, isEdited: true);
      case ParsedDelete(:final targetId):
        final i = indexOf(targetId);
        if (i >= 0) {
          result[i] = result[i].copyWith(
            isDeleted: true,
            reactions: const <String, ChatReaction>{},
          );
        }
      case ParsedReaction(:final targetId, :final reactor, :final reaction):
        final i = indexOf(targetId);
        if (i < 0) continue;
        final current = result[i].reactions[reactor];
        final currentTs = timestampFromUnknown(current?.ts);
        final nextTs = timestampFromUnknown(reaction.ts);
        if (current != null &&
            currentTs > 0 &&
            nextTs > 0 &&
            nextTs < currentTs) {
          continue;
        }
        result[i] = result[i].copyWith(
          reactions: <String, ChatReaction>{
            ...result[i].reactions,
            reactor: reaction,
          },
        );
      default:
        break;
    }
  }
  return result;
}

/// Index of the message a jump names, or -1.
///
/// By id first (`id` is the archive id, `xmppId` the client message id). When
/// the request has no id at all, which is common for archive rows, by
/// content: same text, sent within a few seconds of the same time.
int findMessageIndex(
  List<ChatMessage> messages,
  List<String> ids, {
  JumpContent? content,
}) {
  if (ids.isNotEmpty) {
    final byId = messages.indexWhere(
      (m) => ids.contains(m.id) || (m.xmppId != null && ids.contains(m.xmppId)),
    );
    if (byId >= 0) return byId;
  }
  if (content == null || !content.usable) return -1;
  final wanted = content.createdAtMs!;
  final body = content.body!.trim();
  return messages.indexWhere(
    (m) =>
        m.text.trim() == body &&
        (m.createdAtMs - wanted).abs() <= kContentMatchWindowMs,
  );
}
