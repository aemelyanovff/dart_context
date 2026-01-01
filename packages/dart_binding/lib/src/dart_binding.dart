import 'dart:async';

import 'package:scip_server/scip_server.dart' as scip_server;

import 'cache/cache_paths.dart';
import 'incremental_indexer.dart';
import 'package_discovery.dart';

/// Dart language binding for scip_server.
///
/// Provides Dart-specific implementation of:
/// - Package discovery (pubspec.yaml detection)
/// - Incremental indexing (using Dart analyzer)
/// - Cache management
///
/// ## Usage
///
/// ```dart
/// final binding = DartBinding();
///
/// // Discover packages in a directory
/// final packages = await binding.discoverPackages('/path/to/project');
///
/// // Create an indexer for a package
/// final indexer = await binding.createIndexer('/path/to/package');
/// final index = indexer.index;
///
/// // Query the index
/// final executor = QueryExecutor(index);
/// final result = await executor.execute('def MyClass');
/// ```
class DartBinding implements scip_server.LanguageBinding {
  @override
  String get languageId => 'dart';

  @override
  List<String> get extensions => const ['.dart'];

  @override
  String get packageFile => 'pubspec.yaml';

  @override
  bool get supportsIncremental => true;

  @override
  String get globalCachePath => CachePaths.globalCacheDir;

  @override
  Future<List<scip_server.DiscoveredPackage>> discoverPackages(
    String rootPath,
  ) async {
    final discovery = PackageDiscovery();
    final result = await discovery.discoverPackages(rootPath);

    return result.packages.map((pkg) {
      return scip_server.DiscoveredPackage(
        name: pkg.name,
        path: pkg.path,
        version: '0.0.0', // Version is not available in LocalPackage
      );
    }).toList();
  }

  @override
  Future<scip_server.PackageIndexer> createIndexer(
    String packagePath, {
    bool useCache = true,
  }) async {
    final indexer = await IncrementalScipIndexer.open(
      packagePath,
      useCache: useCache,
    );
    return DartPackageIndexer(indexer);
  }
}

/// Dart-specific package indexer wrapping [IncrementalScipIndexer].
class DartPackageIndexer implements scip_server.PackageIndexer {
  DartPackageIndexer(this._indexer);

  final IncrementalScipIndexer _indexer;
  final _updateController =
      StreamController<scip_server.IndexUpdate>.broadcast();

  @override
  scip_server.ScipIndex get index => _indexer.index;

  @override
  Stream<scip_server.IndexUpdate> get updates => _updateController.stream;

  @override
  Future<void> updateFile(String path) async {
    try {
      await _indexer.refreshFile(path);
      final symbolCount = _indexer.index.symbolsInFile(path).length;
      _updateController.add(scip_server.FileUpdatedUpdate(
        path: path,
        symbolCount: symbolCount,
      ));
    } catch (e) {
      _updateController.add(scip_server.IndexErrorUpdate(
        message: e.toString(),
        path: path,
      ));
    }
  }

  @override
  Future<void> removeFile(String path) async {
    try {
      // Note: ScipIndex doesn't have a public removeFile method.
      // File removal is handled internally by the indexer's file watcher.
      // For now, we just notify about the removal.
      // TODO: Add removeFile method to ScipIndex or expose from indexer
      _updateController.add(scip_server.FileRemovedUpdate(path: path));
    } catch (e) {
      _updateController.add(scip_server.IndexErrorUpdate(
        message: e.toString(),
        path: path,
      ));
    }
  }

  @override
  Future<void> dispose() async {
    await _updateController.close();
    await _indexer.dispose();
  }

  /// Access to the underlying indexer for Dart-specific operations.
  IncrementalScipIndexer get dartIndexer => _indexer;
}

/// Create a DartBinding for use with scip_server.
DartBinding createDartBinding() => DartBinding();
