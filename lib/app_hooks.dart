/// Entry points of the main tabs that other screens (Settings → Data) need to reach without owning the tabs.
/// The tabs register themselves when they are created.
class AppHooks {
  AppHooks._();

  /// Starts a recording that follows the imported route [id] (registered by the History tab).
  static Future<void> Function(int routeId, {bool reverse})? startAlongRoute;

  /// Reloads the list of walks (after a backup was restored).
  static Future<void> Function()? reloadWalks;

  /// Switches the bottom navigation to the tab with this index (0 History, 1 Map, 2 Settings).
  static void Function(int index)? selectTab;
}
