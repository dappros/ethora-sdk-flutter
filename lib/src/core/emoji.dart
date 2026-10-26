import 'emoji_catalog.dart';

/// Web DEFAULT_QUICK_REACTIONS: the quick bar when the host sets none.
const List<String> kDefaultQuickReactions = <String>[
  '+1',
  'heart',
  'joy',
  'open_mouth',
  'cry',
  'pray',
];

/// Most shortcodes the quick bar shows.
const int kMaxQuickReactions = 8;

Map<String, EmojiCatalogEntry>? _byId;

Map<String, EmojiCatalogEntry> _index() {
  return _byId ??= <String, EmojiCatalogEntry>{
    for (final entry in kEmojiCatalog) entry.id: entry,
  };
}

/// Native glyph of a shortcode (web `getEmojiNativeById`). An unknown value
/// is returned as is, so a client that sends a raw glyph still renders.
String emojiGlyph(String id) => _index()[id]?.glyph ?? id;

/// Whether [id] is a shortcode of the catalog.
bool isKnownEmoji(String id) => _index().containsKey(id);

/// Catalog entries whose id or name contains [query] (case-insensitive).
List<EmojiCatalogEntry> searchEmojis(String query, {int limit = 120}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const <EmojiCatalogEntry>[];
  final out = <EmojiCatalogEntry>[];
  for (final entry in kEmojiCatalog) {
    if (entry.id.toLowerCase().contains(needle) ||
        entry.name.toLowerCase().contains(needle)) {
      out.add(entry);
      if (out.length >= limit) break;
    }
  }
  return out;
}

/// Picker categories in display order.
const List<String> kEmojiCategories = <String>[
  'people',
  'nature',
  'foods',
  'activity',
  'places',
  'objects',
  'symbols',
  'flags',
];

/// Resolves the quick bar for a config: the host list (first 8) or the
/// default bar.
List<String> resolveQuickReactions(List<String>? configured) {
  final list = (configured ?? const <String>[])
      .where((e) => e.trim().isNotEmpty)
      .take(kMaxQuickReactions)
      .toList();
  return list.isEmpty ? kDefaultQuickReactions : list;
}
