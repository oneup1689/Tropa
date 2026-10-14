import 'dart:io';

import 'package:flutter/material.dart';

import 'app_hooks.dart';
import 'l10n.dart';
import 'main.dart' show HomePage;
import 'map_page.dart';
import 'settings_page.dart';
import 'splash.dart';

/// The frame of the app: the bottom navigation (Trails, Map, Settings), the night gradient behind the tabs in the
/// dark theme and, on a cold start, the animated splash screen on top. Maps, routes, the backup and the log are in
/// Settings → Data; the planner is on the start card.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static bool _splashShown = false; // only once per process, not again after a theme or language change
  int _index = 0;
  bool _mapOpened = false; // the map is created on the first visit, not at the start of the app
  bool _splash = false;

  @override
  void initState() {
    super.initState();
    // Decide before marking it shown (a lazy field initialiser would run after the mark and never show the splash).
    _splash = !_splashShown && !Platform.environment.containsKey('FLUTTER_TEST');
    _splashShown = true;
    AppHooks.selectTab = (i) {
      if (mounted) setState(() => _index = i);
    };
  }

  @override
  void dispose() {
    AppHooks.selectTab = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    Widget body = IndexedStack(
      index: _index,
      children: [
        const HomePage(),
        if (_mapOpened || _index == 1) MapPage(tab: true, active: _index == 1, title: t('Карта')) else const SizedBox.shrink(),
        SettingsPage(),
      ],
    );
    if (dark) {
      // The tabs sit on the gradient of the posters: their own backgrounds become see-through.
      body = Theme(
        data: theme.copyWith(
          scaffoldBackgroundColor: Colors.transparent,
          appBarTheme: theme.appBarTheme.copyWith(backgroundColor: Colors.transparent),
        ),
        child: body,
      );
    }
    final scaffold = Scaffold(
      backgroundColor: dark ? Colors.transparent : null,
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() {
          _index = i;
          if (i == 1) _mapOpened = true;
        }),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.route_outlined), selectedIcon: const Icon(Icons.route), label: t('Тропы')),
          NavigationDestination(icon: const Icon(Icons.map_outlined), selectedIcon: const Icon(Icons.map), label: t('Карта')),
          NavigationDestination(icon: const Icon(Icons.tune), selectedIcon: const Icon(Icons.tune), label: t('Настройки')),
        ],
      ),
    );
    final framed = PopScope(
      // "Back" from another tab returns to History; History is a dead end for "Back" (only the Home button leaves the app).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != 0) setState(() => _index = 0);
      },
      child: dark
          ? DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0B3A2F), Color(0xFF071C2C)]),
              ),
              child: scaffold,
            )
          : scaffold,
    );
    if (!_splash) return framed;
    return Stack(children: [framed, Positioned.fill(child: TropaSplash(onDone: () => setState(() => _splash = false)))]);
  }
}
