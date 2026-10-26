import '../i18n/chat_i18n.dart';
import '../models/chat_message.dart';

/// Result of [resolveMessageTranslation] (web `ResolvedMessageTranslation`).
class ResolvedMessageTranslation {
  const ResolvedMessageTranslation({
    required this.needsTranslation,
    required this.hasTranslation,
    required this.originalText,
    required this.displayText,
  });

  /// A known source language that differs from the reader's, with real text.
  final bool needsTranslation;

  /// A non-identical translation is already attached to the message.
  final bool hasTranslation;
  final String originalText;

  /// The translation when [hasTranslation], else the original.
  final String displayText;
}

final RegExp _letter = RegExp(r'\p{L}', unicode: true);

/// Web `resolveMessageTranslation`: pure lookup of the translation the
/// server attached (`<translations>`) for [readerLocale]. Regions are
/// ignored (en-US vs en-CA is not a translation job).
ResolvedMessageTranslation resolveMessageTranslation(
  ChatMessage message,
  String? readerLocale,
) {
  final original = message.text;
  final source = message.langSource;
  final targetBase = toBaseLanguage(readerLocale ?? 'en');
  final sourceBase = toBaseLanguage(source);
  final trimmed = original.trim();
  final needs = trimmed.isNotEmpty &&
      (source ?? '').isNotEmpty &&
      sourceBase != targetBase &&
      _letter.hasMatch(trimmed);
  String? result;
  if (needs) {
    result = message.translations[readerLocale ?? ''] ??
        message.translations[targetBase];
  }
  final real = result != null && result.trim() != trimmed;
  return ResolvedMessageTranslation(
    needsTranslation: needs,
    hasTranslation: real,
    originalText: original,
    displayText: real ? result : original,
  );
}
