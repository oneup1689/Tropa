import 'package:flutter/material.dart';

import 'brand.dart';

/// Colours of the app: the forest green and the orange of the logo, on a soft off-white (light) or a deep
/// forest night (dark). The same colours the posters use.
class TropaColors {
  TropaColors._();

  static const forest = Color(0xFF0E4D3A); // the poster gradient start: deep green
  static const forestDeep = Color(0xFF0B3D2E);
  static const mint = Color(0xFF6FD6A3);
  static const orange = Color(0xFFFF7043);
  static const terracotta = Color(0xFFC8553D);
  static const sand = Color(0xFFF2E8CF);
  static const paper = Color(0xFFF6F1E3); // light theme "Earth": warm paper
  static const night = Color(0xFF08211F); // dark theme "Night": between the poster gradient colours
}

/// Light theme "Earth": sand paper, deep-green text and actions, terracotta for the main call to action.
/// Dark theme "Night": the poster palette, mint for actions, orange for the call to action.
ColorScheme tropaScheme(Brightness b) {
  // The seed stays the old forest green so the derived tertiary (used for the healed track) does not shift.
  final base = ColorScheme.fromSeed(seedColor: const Color(0xFF1F6B4A), brightness: b);
  if (b == Brightness.light) {
    return base.copyWith(
      primary: TropaColors.forest,
      onPrimary: TropaColors.sand,
      primaryContainer: const Color(0xFFD9E7D6),
      onPrimaryContainer: TropaColors.forestDeep,
      secondary: TropaColors.terracotta,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFF6DDD2),
      onSecondaryContainer: const Color(0xFF5A1C08),
      surface: TropaColors.paper,
      onSurface: const Color(0xFF1A2A22),
      surfaceContainerLowest: const Color(0xFFFFFDF7),
      surfaceContainerLow: const Color(0xFFFFFBF0),
      surfaceContainer: const Color(0xFFF1EAD6),
      surfaceContainerHigh: const Color(0xFFEAE1C8),
      surfaceContainerHighest: const Color(0xFFE3D9BC),
      outlineVariant: const Color(0xFFE0D5B2),
    );
  }
  return base.copyWith(
    primary: TropaColors.mint,
    onPrimary: const Color(0xFF00382A),
    primaryContainer: const Color(0xFF14513F),
    onPrimaryContainer: const Color(0xFFBDF0D4),
    secondary: TropaColors.orange,
    onSecondary: const Color(0xFF3A1100),
    secondaryContainer: const Color(0xFF6A2A14),
    onSecondaryContainer: const Color(0xFFFFDBCF),
    surface: TropaColors.night,
    onSurface: const Color(0xFFE3EBE6),
    surfaceContainerLowest: const Color(0xFF061817),
    surfaceContainerLow: const Color(0xFF0F302B),
    surfaceContainer: const Color(0xFF133A34),
    surfaceContainerHigh: const Color(0xFF184540),
    surfaceContainerHighest: const Color(0xFF1F524A),
    outlineVariant: const Color(0xFF26584B),
  );
}

TextStyle _body(double size, double weight, {double? height, double? spacing}) => TextStyle(
      fontFamily: bodyFont,
      fontSize: size,
      height: height,
      letterSpacing: spacing,
      fontVariations: [FontVariation('wght', weight)],
    );

TextStyle _head(double size, double weight, {double? height}) => TextStyle(
      fontFamily: headingFont,
      fontSize: size,
      height: height ?? 1.2,
      fontVariations: [FontVariation('wght', weight)],
    );

ThemeData buildTheme(Brightness brightness) {
  final scheme = tropaScheme(brightness);
  final textTheme = TextTheme(
    displayLarge: _head(44, 700),
    displayMedium: _head(36, 700),
    displaySmall: _head(30, 700),
    headlineLarge: _head(28, 700),
    headlineMedium: _head(24, 700),
    headlineSmall: _head(20, 700),
    titleLarge: _head(18, 600),
    titleMedium: _body(16, 600),
    titleSmall: _body(14, 600),
    bodyLarge: _body(16, 400, height: 1.35),
    bodyMedium: _body(14, 400, height: 1.35),
    bodySmall: _body(12.5, 400, height: 1.3),
    labelLarge: _body(14, 600),
    labelMedium: _body(12.5, 500),
    labelSmall: _body(11, 500),
  ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  final shape22 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(22));
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: bodyFont,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: _head(19, 700).copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: scheme.outlineVariant.withAlpha(150)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 50),
        textStyle: _body(15, 600),
        padding: const EdgeInsets.symmetric(horizontal: 22),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 46),
        textStyle: _body(14.5, 600),
        side: BorderSide(color: scheme.outline.withAlpha(140)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: const StadiumBorder(), textStyle: _body(14.5, 600)),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.secondary,
      foregroundColor: scheme.onSecondary,
      shape: const StadiumBorder(),
      elevation: 3,
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: _body(13.5, 500).copyWith(color: scheme.onSurface),
      secondaryLabelStyle: _body(13.5, 500).copyWith(color: scheme.onPrimaryContainer),
      selectedColor: scheme.primaryContainer,
      showCheckmark: true,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        textStyle: _body(14, 600),
        foregroundColor: scheme.onSurface,
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: scheme.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: scheme.outlineVariant)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: scheme.primary, width: 2)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      titleTextStyle: _head(17, 700).copyWith(color: scheme.onSurface),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      showDragHandle: true,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: ListTileThemeData(shape: shape22, iconColor: scheme.primary),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.outline),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : scheme.surfaceContainerHighest),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.transparent : scheme.outlineVariant),
    ),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withAlpha(160), space: 24),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary, linearTrackColor: scheme.surfaceContainerHighest),
    sliderTheme: SliderThemeData(trackHeight: 5, activeTrackColor: scheme.primary, thumbColor: scheme.primary),
  );
}
