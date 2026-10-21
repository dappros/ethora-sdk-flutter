import 'package:ethora_sdk_flutter/src/i18n/chat_i18n.dart';
import 'package:ethora_sdk_flutter/src/i18n/strings_extra.dart';
import 'package:ethora_sdk_flutter/src/ui/search/message_hits_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every Flutter-only caption exists in all six languages', () {
    final english = kExtraStrings['en']!.keys.toSet();
    for (final lang in <String>['fr', 'es', 'pt', 'ht', 'zh']) {
      final keys = kExtraStrings[lang]!.keys.toSet();
      expect(english.difference(keys), isEmpty,
          reason: '$lang is missing keys');
      expect(keys.difference(english), isEmpty, reason: '$lang has extra keys');
    }
  });

  test('keys stay sorted inside each language', () {
    for (final entry in kExtraStrings.entries) {
      final keys = entry.value.keys.toList();
      expect(keys, <String>[...keys]..sort(), reason: '${entry.key} order');
    }
  });

  test('the push, copy, call and media captions are translated', () {
    for (final lang in <String>['fr', 'es', 'pt', 'ht', 'zh']) {
      final strings = ChatStrings.resolve(lang, null);
      for (final key in <String>[
        'settings.push.title',
        'action.copy',
        'call.accept',
        'media.openInBrowser',
      ]) {
        expect(strings.t(key), isNot(ChatStrings.resolve('en', null).t(key)),
            reason: '$lang $key');
      }
    }
  });

  test('hit dates use the reader language for the month', () {
    final iso = DateTime(2026, 2, 3, 12).toUtc().toIso8601String();
    final now = DateTime(2026, 6, 1);
    expect(formatHitWhen(iso, now: now), '3 Feb');
    expect(
      formatHitWhen(iso, now: now, strings: ChatStrings.resolve('fr', null)),
      '3 févr.',
    );
    expect(
      formatHitWhen(iso, now: now, strings: ChatStrings.resolve('zh', null)),
      '3 2月',
    );
  });
}
