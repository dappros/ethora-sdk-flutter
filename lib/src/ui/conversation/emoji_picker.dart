import 'package:flutter/material.dart';

import '../../core/emoji.dart';
import '../../core/emoji_catalog.dart';
import '../../theme/chat_theme.dart';

/// Full emoji picker (web EmojiPicker): category tabs, search and a grid.
/// Pops with the chosen shortcode.
Future<String?> showEmojiPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _EmojiPickerSheet(),
  );
}

class _EmojiPickerSheet extends StatefulWidget {
  const _EmojiPickerSheet();

  @override
  State<_EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends State<_EmojiPickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _category = kEmojiCategories.first;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  IconData _iconFor(String category) {
    return switch (category) {
      'people' => Icons.emoji_emotions_outlined,
      'nature' => Icons.eco_outlined,
      'foods' => Icons.fastfood_outlined,
      'activity' => Icons.sports_soccer_outlined,
      'places' => Icons.location_city_outlined,
      'objects' => Icons.lightbulb_outline,
      'symbols' => Icons.favorite_border,
      _ => Icons.flag_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    final query = _search.text.trim();
    final entries = query.isNotEmpty
        ? searchEmojis(query)
        : kEmojiCatalog.where((e) => e.category == _category).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: ui.strings.t('search.placeholder'),
              ),
            ),
          ),
          if (query.isEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final category in kEmojiCategories)
                    IconButton(
                      onPressed: () => setState(() => _category = category),
                      isSelected: category == _category,
                      icon: Icon(
                        _iconFor(category),
                        color: category == _category
                            ? ui.theme.primary
                            : ui.theme.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 48,
              ),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => Navigator.of(context).pop(entry.id),
                  child: Center(
                    child: Text(
                      entry.glyph,
                      style: const TextStyle(fontSize: 26),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
