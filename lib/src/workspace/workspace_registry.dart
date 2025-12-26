import 'dart:convert';
import 'dart:io';

import '../cache/cache_paths.dart';
import '../index/incremental_indexer.dart';
import '../index/scip_index.dart';
import 'workspace_detector.dart';

/// Manages local package indexes for mono repo workspaces.
///
/// The workspace registry stores indexes for local (path dependency) packages
/// in a central location for efficient cross-package queries.
///
/// ## Storage Layout
///
/// ```
/// /path/to/monorepo/.dart_context/
/// ├── workspace.json           # Workspace metadata
/// └── local/
///     ├── hologram_core/
///     │   ├── index.scip
///     │   └── manifest.json
///     └── hologram_shared/
///         ├── index.scip
///         └── manifest.json
/// ```
class WorkspaceRegistry {
  WorkspaceRegistry(this.workspace);

  /// The workspace info.
  final WorkspaceInfo workspace;

  /// Indexers for each package (keyed by package name).
  final Map<String, IncrementalScipIndexer> _indexers = {};

  /// Get the workspace root path.
  String get rootPath => workspace.rootPath;

  /// Get the registry directory path.
  String get registryPath => CachePaths.workspaceDir(rootPath);

  /// Get all package indexers.
  Map<String, IncrementalScipIndexer> get indexers =>
      Map.unmodifiable(_indexers);

  /// Initialize the workspace registry.
  ///
  /// This creates the registry directory and loads/creates indexes
  /// for all packages in the workspace.
  Future<void> initialize({
    bool useCache = true,
    void Function(String message)? onProgress,
  }) async {
    // Create registry directory
    await Directory(registryPath).create(recursive: true);

    // Save workspace metadata
    await _saveWorkspaceMetadata();

    // Initialize indexers for each package
    for (final pkg in workspace.packages) {
      onProgress?.call('Initializing ${pkg.name}...');

      final indexer = await IncrementalScipIndexer.open(
        pkg.absolutePath,
        useCache: useCache,
      );
      _indexers[pkg.name] = indexer;

      // Sync to registry
      await syncPackage(pkg.name);
    }

    onProgress?.call('Initialized ${_indexers.length} packages');
  }

  /// Sync a package's index to the workspace registry.
  ///
  /// Copies the package's index to the central registry location.
  Future<void> syncPackage(String packageName) async {
    final indexer = _indexers[packageName];
    if (indexer == null) return;

    final pkg = workspace.packages.firstWhere(
      (p) => p.name == packageName,
      orElse: () => throw StateError('Package $packageName not in workspace'),
    );

    final localDir = CachePaths.localPackageDir(rootPath, packageName);
    await Directory(localDir).create(recursive: true);

    // Copy index
    final sourceIndex = CachePaths.packageWorkingIndex(pkg.absolutePath);
    final destIndex = CachePaths.localPackageIndex(rootPath, packageName);

    if (await File(sourceIndex).exists()) {
      await File(sourceIndex).copy(destIndex);
    }

    // Write manifest
    await _writeManifest(localDir, pkg);
  }

  /// Load indexes for all packages from the registry.
  ///
  /// Returns a map of package name to loaded index.
  Future<Map<String, ScipIndex>> loadLocalPackages() async {
    final indexes = <String, ScipIndex>{};

    for (final pkg in workspace.packages) {
      final indexPath = CachePaths.localPackageIndex(rootPath, pkg.name);
      if (await File(indexPath).exists()) {
        final index = await ScipIndex.loadFromFile(
          indexPath,
          projectRoot: pkg.absolutePath,
          sourceRoot: pkg.absolutePath,
        );
        indexes[pkg.name] = index;
      }
    }

    return indexes;
  }

  /// Update a file in the appropriate package indexer.
  ///
  /// Returns the package name if the file was updated, null otherwise.
  Future<String?> updateFile(String filePath) async {
    // Find which package owns this file
    final pkg = workspace.findPackageForPath(filePath);
    if (pkg == null) return null;

    // Get the indexer for this package
    final indexer = _indexers[pkg.name];
    if (indexer == null) return null;

    // Update the indexer
    await indexer.refreshFile(filePath);

    // Sync to registry
    await syncPackage(pkg.name);

    return pkg.name;
  }

  /// Get the index for a specific package.
  ScipIndex? getPackageIndex(String packageName) {
    return _indexers[packageName]?.index;
  }

  /// Dispose all indexers.
  void dispose() {
    for (final indexer in _indexers.values) {
      indexer.dispose();
    }
    _indexers.clear();
  }

  Future<void> _saveWorkspaceMetadata() async {
    final metadata = {
      'type': workspace.type.name,
      'rootPath': workspace.rootPath,
      'packages': workspace.packages
          .map((p) => {
                'name': p.name,
                'relativePath': p.relativePath,
              })
          .toList(),
      'updatedAt': DateTime.now().toIso8601String(),
    };

    final file = File(CachePaths.workspaceMetadata(rootPath));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata),
    );
  }

  Future<void> _writeManifest(String localDir, WorkspacePackage pkg) async {
    final manifest = {
      'type': 'local',
      'name': pkg.name,
      'sourcePath': pkg.absolutePath,
      'relativePath': pkg.relativePath,
      'indexedAt': DateTime.now().toIso8601String(),
    };

    await File('$localDir/manifest.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }
}

/// Load workspace metadata from registry.
Future<Map<String, dynamic>?> loadWorkspaceMetadata(
    String workspaceRoot) async {
  final file = File(CachePaths.workspaceMetadata(workspaceRoot));
  if (!await file.exists()) return null;

  try {
    final content = await file.readAsString();
    return jsonDecode(content) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

