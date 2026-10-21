import 'strings_extra.dart';
import 'strings_table.dart';

/// UI caption lookup, resolved like the web SDK (`src/i18n/strings.ts`).
///
/// The locale reduces to its base language ("fr-CA" gives "fr"). Missing keys
/// fall back to English, then to the raw key, so nothing renders blank. Host
/// overrides from `config.i18n.strings` win over both.
class ChatStrings {
  ChatStrings._(this.locale, this._table);

  /// Resolves the table for [locale] with host [overrides] merged on top.
  factory ChatStrings.resolve(
    String? locale,
    Map<String, String>? overrides,
  ) {
    return ChatStrings._(
      toBaseLanguage(locale),
      resolveStringTable(locale, overrides),
    );
  }

  /// Base language in use, e.g. "fr".
  final String locale;
  final Map<String, String> _table;

  /// Caption for [key]. `{name}` placeholders are filled from [vars].
  String t(String key, [Map<String, Object>? vars]) {
    return interpolate(_table[key] ?? key, vars);
  }

  @override
  bool operator ==(Object other) =>
      other is ChatStrings &&
      other.locale == locale &&
      _sameTable(other._table, _table);

  @override
  int get hashCode => Object.hash(locale, _table.length);

  static bool _sameTable(Map<String, String> a, Map<String, String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// Built-in language used when a locale has no table.
const String kDefaultUiLanguage = 'en';

/// Reduce a BCP-47 locale ("fr-CA") to its lowercase base language ("fr").
String toBaseLanguage(String? locale) {
  final raw = (locale ?? kDefaultUiLanguage).trim();
  final base = raw.split('-').first.trim().toLowerCase();
  return base.isEmpty ? kDefaultUiLanguage : base;
}

/// Effective string table for [locale]: the built-in table for its base
/// language, English for any missing key, then [overrides] on top.
Map<String, String> resolveStringTable(
  String? locale,
  Map<String, String>? overrides,
) {
  final base = toBaseLanguage(locale);
  final table = kBuiltinStrings[base] ?? kBuiltinStrings[kDefaultUiLanguage]!;
  return <String, String>{
    ...kBuiltinStrings[kDefaultUiLanguage]!,
    ...table,
    ...?kExtraStrings[kDefaultUiLanguage],
    ...?kExtraStrings[base],
    ...?overrides,
  };
}

/// Replace `{name}` placeholders with values from [vars]. Unknown names are
/// left as they are.
String interpolate(String template, [Map<String, Object>? vars]) {
  if (vars == null || vars.isEmpty) return template;
  return template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (match) {
    final name = match.group(1)!;
    return vars.containsKey(name) ? '${vars[name]}' : match.group(0)!;
  });
}

/// Languages the host can pick for the UI, in the built-in table.
const List<String> kBuiltinUiLanguages = <String>['en', 'fr', 'es', 'pt', 'ht', 'zh'];
