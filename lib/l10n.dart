import 'package:flutter/foundation.dart';

import 'l10n_en.dart';

/// Interface languages. The texts in the code are Russian; the English ones are looked up by the Russian text
/// (see l10n_en.dart). A text without a translation is shown in Russian, so a missing entry never breaks anything.
enum AppLang { ru, en }

class L10n {
  L10n._();

  static AppLang current = AppLang.ru;

  /// Changes whenever the language changes; the app rebuilds itself from it.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void set(AppLang lang) {
    if (lang == current) return;
    current = lang;
    revision.value++;
  }

  /// Language chosen by the phone: Russian for Russian (and Ukrainian, Belarusian, Kazakh) phones, English otherwise.
  static AppLang fromSystem(String? languageCode) {
    const ruLike = {'ru', 'uk', 'be', 'kk'};
    return ruLike.contains(languageCode) ? AppLang.ru : AppLang.en;
  }

  static String tr(String ru, [Map<String, Object?>? args]) {
    var s = current == AppLang.en ? (enStrings[ru] ?? ru) : ru;
    if (args != null) {
      args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
    }
    return s;
  }

  /// Short code for the native service, which shows its own notifications.
  static String get code => current == AppLang.en ? 'en' : 'ru';
}

/// Translates a Russian text; `{name}` placeholders are filled from [args].
String t(String ru, [Map<String, Object?>? args]) => L10n.tr(ru, args);

/// The right word form for a number. Russian has three forms (1 маршрут, 2 маршрута, 5 маршрутов), English two.
String plural(int n, String one, String few, String many, {String? en1, String? enN}) {
  if (L10n.current == AppLang.en) return n == 1 ? (en1 ?? one) : (enN ?? many);
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

const _monthsRu = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
const _monthsEn = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _monthsShortRu = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
const _monthsShortEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Month name for dates in a sentence ("12 октября" / "October 12"); [month] is 1..12.
String monthName(int month) => (L10n.current == AppLang.en ? _monthsEn : _monthsRu)[month - 1];

String monthShort(int month) => (L10n.current == AppLang.en ? _monthsShortEn : _monthsShortRu)[month - 1];

/// "12 октября 2026" / "October 12, 2026".
String longDate(int day, int month, int year) =>
    L10n.current == AppLang.en ? '${monthName(month)} $day, $year' : '$day ${monthName(month)} $year';

/// "12 октября" / "October 12".
String dayMonth(int day, int month) => L10n.current == AppLang.en ? '${monthName(month)} $day' : '$day ${monthName(month)}';
