import 'dart:async';
import 'dart:io';

import 'index/package_registry.dart';
import 'package_discovery.dart';
import 'utils/package_config.dart';

/// Unified file watcher for the entire root directory.
///
/// Watches for:
/// - `.dart` file changes → Incremental index updates
/// - `package_config.json` changes → Reload external dependencies
/// - `pubspec.yaml` changes → Re-discover packages (future)
///
/// ## Usage
///
/// ```dart
/// final watcher = RootWatcher(
///   rootPath: '/path/to/workspace',
///   registry: registry,
/// );
/// await watcher.start();
/// // ...
/// await watcher.stop();
/// ```
class RootWatcher {
  RootWatcher({
    required this.rootPath,
    required this.registry,
    this.onPackageChange,
    this.onDependencyChange,
  });

  /// The root path to watch.
  final String rootPath;

  /// The package registry to update.
  final PackageRegistry registry;

  /// Callback when a package's index changes.
  final void Function(String packageName)? onPackageChange;

  /// Callback when dependencies change.
  final void Function(String packageName)? onDependencyChange;

  StreamSubscription<FileSystemEvent>? _subscription;

  /// Track package_config.json content for diffing.
  final Map<String, String> _lastPackageConfigs = {};

  /// Whether the watcher is running.
  bool get isRunning => _subscription != null;

  /// Start watching.
  Future<void> start() async {
    if (_subscription != null) return;

    // Initialize package config snapshots
    for (final pkg in registry.localPackages.values) {
      final configPath = '${pkg.path}/.dart_tool/package_config.json';
      final file = File(configPath);
      if (await file.exists()) {
        _lastPackageConfigs[configPath] = await file.readAsString();
      }
    }

    // Watch root directory recursively
    final dir = Directory(rootPath);
    if (!await dir.exists()) return;

    _subscription = dir.watch(recursive: true).listen(
      _onFileChange,
      onError: (e) {
        // Ignore watch errors (e.g., permission denied)
      },
    );
  }

  /// Stop watching.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _lastPackageConfigs.clear();
  }

  void _onFileChange(FileSystemEvent event) {
    final path = event.path;

    // Skip ignored directories
    if (shouldIgnorePath(path, rootPath)) return;

    // Handle different file types
    if (path.endsWith('.dart')) {
      _handleDartChange(event);
    } else if (path.endsWith('package_config.json')) {
      _handleDependencyChange(path);
    } else if (path.endsWith('pubspec.yaml')) {
      _handlePubspecChange(path);
    }
  }

  /// Handle .dart file changes.
  void _handleDartChange(FileSystemEvent event) {
    final pkg = registry.findPackageForPath(event.path);
    if (pkg == null) return;

    // Delegate to the package's indexer
    switch (event.type) {
      case FileSystemEvent.create:
      case FileSystemEvent.modify:
        pkg.indexer.refreshFile(event.path);
        onPackageChange?.call(pkg.name);

      case FileSystemEvent.delete:
        // File deleted - mark as needing refresh (index will handle removal)
        pkg.indexer.refreshFile(event.path);
        onPackageChange?.call(pkg.name);

      case FileSystemEvent.move:
        // For moves, treat as delete + create
        final moveEvent = event as FileSystemMoveEvent;
        pkg.indexer.refreshFile(event.path); // Handle old path
        if (moveEvent.destination != null) {
          pkg.indexer.refreshFile(moveEvent.destination!);
        }
        onPackageChange?.call(pkg.name);
    }
  }

  /// Handle package_config.json changes.
  Future<void> _handleDependencyChange(String configPath) async {
    // Find which package this belongs to
    final packagePath =
        configPath.replaceAll('/.dart_tool/package_config.json', '');
    final pkg = registry.findPackageForPath(packagePath);
    if (pkg == null) return;

    final file = File(configPath);
    if (!await file.exists()) return;

    final newContent = await file.readAsString();
    final oldContent = _lastPackageConfigs[configPath];

    // Skip if no change
    if (oldContent == newContent) return;

    // Update snapshot
    _lastPackageConfigs[configPath] = newContent;

    // Parse old and new dependencies
    final oldDeps = oldContent != null
        ? _parseConfigContent(oldContent)
        : <ResolvedPackage>[];
    final newDeps = await parsePackageConfig(packagePath);

    // Diff and update
    await _updateDependencies(oldDeps, newDeps);

    onDependencyChange?.call(pkg.name);
  }

  List<ResolvedPackage> _parseConfigContent(String content) {
    // Simple parse of package_config.json content
    // This is a simplified version - the full implementation uses parsePackageConfig
    try {
      // For now, we just detect changes rather than parse content
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<void> _updateDependencies(
    List<ResolvedPackage> oldDeps,
    List<ResolvedPackage> newDeps,
  ) async {
    final oldKeys = oldDeps.map((d) => d.cacheKey).toSet();
    final newKeys = newDeps.map((d) => d.cacheKey).toSet();

    // Newly added dependencies
    for (final dep in newDeps) {
      if (oldKeys.contains(dep.cacheKey)) continue;

      // Try to load the new dependency
      switch (dep.source) {
        case DependencySource.hosted:
          if (dep.version != null) {
            await registry.loadHostedPackage(dep.name, dep.version!);
          }
        case DependencySource.git:
          await registry.loadGitPackage(dep.cacheKey);
        case DependencySource.path:
        case DependencySource.sdk:
          // Path deps are local packages, SDK handled separately
          break;
      }
    }

    // Removed dependencies - optionally unload
    for (final dep in oldDeps) {
      if (newKeys.contains(dep.cacheKey)) continue;

      // Could unload, but for now we keep them loaded for memory efficiency
      // registry.unloadHostedPackage(dep.name, dep.version ?? '');
    }
  }

  /// Handle pubspec.yaml changes.
  ///
  /// This could trigger re-discovery of packages if a new package is added,
  /// but for now we just log the change.
  Future<void> _handlePubspecChange(String pubspecPath) async {
    // For now, we don't automatically re-discover packages
    // This would require more complex logic to handle:
    // - New packages being added
    // - Packages being removed
    // - Package renames
    //
    // Users can restart the context to pick up structural changes
  }
}

