import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/help_page.dart';
import 'package:tropa/l10n_en.dart';

void main() {
  test('every question and answer of the help has an English text', () {
    for (final (q, a) in HelpPage.items()) {
      expect(enStrings.containsKey(q), isTrue, reason: q);
      expect(enStrings.containsKey(a), isTrue, reason: a);
    }
  });

  test('the help has no text about phone makers or battery rescue steps (decision of the owner)', () {
    for (final (q, a) in HelpPage.items()) {
      expect('$q $a'.contains('Xiaomi'), isFalse);
    }
  });
}
