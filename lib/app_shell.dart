import 'dart:io';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'main.dart' show HomePage, HomePageState;
import 'maps_page.dart';
import 'routes_page.dart';
import 'settings_page.dart';
import 'splash.dart';

/// The frame of the app: the bottom navigation (Walks, Maps, Routes, Settings), the night gradient behind the tabs
/// in the dark theme and, on a cold start, the animated splash screen on top. The planner, the backup and the log
/// stay in the menu of the Walks screen.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static bool _splashShown = false; // only once per process, not again after a theme or language change
  int _index = 0;
  final _home = GlobalKey<HomePageState>();
  bool _splash = false;

  @override
  void initState() {
    super.initState();
    // Decide before marking it shown (a lazy field initialiser would run after the mark and never show the splash).
    _splash = !_splashShown && !Platform.environment.containsKey('FLUTTER_TEST');
    _splashShown = true;
  }

  /// "Go along this route" on the Routes tab: back to the walks and start the recording there.
  void _startRoute(int routeId) {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _home.currentState?.startAlongRoute(routeId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    Widget body = IndexedStack(
      index: _index,
      children: [HomePage(key: _home), MapsPage(), RoutesPage(onPick: _startRoute), SettingsPage()],
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
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.route_outlined), selectedIcon: const Icon(Icons.route), label: t('Прогулки')),
          NavigationDestination(icon: const Icon(Icons.map_outlined), selectedIcon: const Icon(Icons.map), label: t('Карты')),
          NavigationDestination(icon: const Icon(Icons.alt_route), selectedIcon: const Icon(Icons.alt_route), label: t('Маршруты')),
          NavigationDestination(icon: const Icon(Icons.tune), selectedIcon: const Icon(Icons.tune), label: t('Настройки')),
        ],
      ),
    );
    final framed = PopScope(
      // "Back" from another tab returns to the walks first.
      canPop: _index == 0,
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
