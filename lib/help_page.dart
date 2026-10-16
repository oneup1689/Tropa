import 'package:flutter/material.dart';

import 'l10n.dart';
import 'settings.dart';

/// The help screen: short, friendly answers to what a newcomer asks first. Plain text, the same in both languages
/// (the Russian text is the key of the English one in l10n_en.dart).
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  /// (question, answer). Pro-only notes are added at build time, see [items].
  static List<(String, String)> items() => [
        (
          'Как начать запись?',
          'Нажмите «Начать запись» на главном экране. Приложение попросит доступ к геолокации: выберите «Разрешить всегда», '
              'тогда запись не прервётся, когда экран погаснет. Остановить запись можно той же кнопкой.'
        ),
        (
          'Нужен ли интернет?',
          'Нет: запись и карты работают без интернета. Он нужен только чтобы скачать карту и для постера: погода, высоты и '
              'название места берутся из сети.'
        ),
        (
          'Как скачать карту?',
          'Настройки → Данные → Карты, дальше выберите страну или регион. Перед загрузкой приложение покажет размер. '
              'Карта нужна, чтобы смотреть маршрут и делать постер, для самой записи она не нужна.'
        ),
        (
          'Как идти по маршруту?',
          'Откройте вкладку «Тропы» → «Маршруты», выберите маршрут и нажмите «Идти по маршруту». Приложение подскажет повороты '
              'голосом и вибрацией, а на карте будет видно, где вы. Если вы далеко от старта, выберите «Ждать у старта»: запись '
              'и навигация начнутся сами, когда вы подойдёте.'
        ),
        (
          'Как записывать без кнопки?',
          'Нажмите значок календаря на главной карточке и включите «Начинать запись автоматически»: запись начнётся сама, '
              'когда вы пойдёте. Там же можно запланировать прогулку на нужное время.'
        ),
        (
          'Заметки, фото и видео',
          'Во время записи кнопка «Заметка» сохраняет текст, фото или видео в том месте, где вы стоите. Фото и видео лежат в '
              'галерее телефона, в альбоме Tropa. Заметку можно добавить и после прогулки: откройте прогулку в списке и нажмите '
              '«Добавить заметку».'
        ),
        (
          'Как сделать постер?',
          'Откройте прогулку и нажмите «Постер». Выберите формат, что показать и фон (карта или стиль Tropa), нажмите «Создать», '
              'а потом «Сохранить» или «Поделиться». Цвет линии приложение подбирает само.'
        ),
        (
          'Как сохранить прогулки и перенести на другой телефон?',
          'Настройки → Данные → «Резервная копия» собирает все прогулки в один файл. На новом телефоне откройте '
              '«Восстановить из копии» и выберите этот файл: повторов не будет.'
        ),
        (
          'Что уходит в интернет?',
          'Прогулки хранятся только на вашем телефоне. В сеть уходят лишь запросы для постера (погода, высоты и название места '
              'для координат этого места) и загрузка карт. Без вашего действия приложение ничего не отправляет.'
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final items = HelpPage.items();
    return Scaffold(
      appBar: AppBar(title: Text(t('Справка'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
          child: Text(t('Коротко о том, как всё устроено. Нажмите на вопрос, чтобы увидеть ответ.'),
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        ),
        for (final (q, a) in items)
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(t(q), style: text.titleSmall),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(t(a), style: text.bodyMedium)],
            ),
          ),
        if (AppSettings.instance.pro)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(t('В режиме «Профи» в настройках больше параметров: обрезка начала и конца маршрута, разбиение на прогулки, копия в аккаунте Google и другие.'),
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
      ]),
    );
  }
}
