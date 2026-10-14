import 'dart:io';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'main.dart' show HomePage;
import 'maps_page.dart';
import 'settings_page.dart';
import 'splash.dart';

/// The frame of the app: the bottom navigation (Walks, Maps, Settings) and, on a cold start, the animated splash
/// screen on top. Routes, the planner, the backup and the log stay in the menu of the Walks screen.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static bool _splashShown = false; // only once per process, not again after a theme or language change
  int _index = 0;
  bool _splash = false;

  @override
  void initState() {
    super.initState();
    // Decide before marking it shown (a lazy field initialiser would run after the mark and never show the splash).
    _splash = !_splashShown && !Platform.environment.containsKey('FLUTTER_TEST');
    _splashShown = true;
  }

  @override
  Widget build(BuildContext context) {
    final shell = PopScope(
      // "Back" from Maps or Settings returns to the walks first.
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != 0) setState(() => _index = 0);
      },
      child: Scaffold(
        body: IndexedStack(index: _index, children: [HomePage(), MapsPage(), SettingsPage()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            NavigationDestination(icon: const Icon(Icons.route_outlined), selectedIcon: const Icon(Icons.route), label: t('Прогулки')),
            NavigationDestination(icon: const Icon(Icons.map_outlined), selectedIcon: const Icon(Icons.map), label: t('Карты')),
            NavigationDestination(icon: const Icon(Icons.tune), selectedIcon: const Icon(Icons.tune), label: t('Настройки')),
          ],
        ),
      ),
    );
    if (!_splash) return shell;
    return Stack(children: [shell, Positioned.fill(child: TropaSplash(onDone: () => setState(() => _splash = false)))]);
  }
}
