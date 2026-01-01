import 'dart:async';

import 'package:dart_binding/dart_binding.dart'
    hide IndexUpdate, InitialIndexUpdate, FileUpdatedUpdate, FileRemovedUpdate, IndexErrorUpdate;
import 'package:scip_server/scip_server.dart'
    hide IndexUpdate, InitialIndexUpdate, FileUpdatedUpdate, FileRemovedUpdate, IndexErrorUpdate;

// Use dart_binding's IndexUpdate types (they have more info)
import 'package:dart_binding/dart_binding.dart' show IndexUpdate;

import 'root_watcher.dart';

/// Lightweight semantic code intelligence for Dart.
///
/// Provides incremental indexing and a query DSL for navigating
/// Dart codebases.
///
/// ## Usage
///
/// ```dart
/// final context = await DartContext.open('/path/to/project');
///
/// // Query with DSL
/// final result = await context.query('def AuthRepository');
/// print(result.toText());
///
/// // Watch for updates
/// context.updates.listen((update) {
///   print('Index updated: $update');
/// });
///
/// // Cleanup
/// await context.dispose();
/// ```
///
/// ## Works with any folder structure
///
/// The unified architecture works for:
/// - Single packages
/// - Melos mono repos
/// - Dart pub workspaces
/// - Any folder with multiple packages
class DartContext {
  DartContext._({
    required this.rootPath,
    required PackageRegistry registry,
    required QueryExecutor executor,
    RootWatcher? watcher,
    DiscoveryResult? discovery,
  })  : _registry = registry,
        _executor = executor,
        _watcher = watcher,
        _discovery = discovery;

  /// The root path for this context.
  final String rootPath;

  /// Alias for [rootPath] for backward compatibility.
  @Deprecated('Use rootPath instead')
  String get projectRoot => rootPath;

  /// Primary index for direct programmatic queries.
  ///
  /// Returns the first local package's index, or an empty index if none.
  /// For multi-package workspaces, consider using [registry] directly.
  ScipIndex get index {
    final packages = _registry.localPackages.values.toList();
    if (packages.isEmpty) return ScipIndex.empty(projectRoot: rootPath);
    return packages.first.indexer.index;
  }

  final PackageRegistry _registry;
  final QueryExecutor _executor;
  final RootWatcher? _watcher;
  final DiscoveryResult? _discovery;

  /// Open a Dart project or workspace.
  ///
  /// This will:
  /// 1. Recursively discover all packages in the path
  /// 2. Create indexers for each package
  /// 3. Load from cache (if valid and [useCache] is true)
  /// 4. Start file watching (if [watch] is true)
  /// 5. Load pre-indexed dependencies (if [loadDependencies] is true)
  ///
  /// Works for any folder structure:
  /// - Single packages
  /// - Melos mono repos
  /// - Dart pub workspaces
  /// - Any folder with multiple packages
  ///
  /// Example:
  /// ```dart
  /// // Open a single package
  /// final context = await DartContext.open('/path/to/package');
  ///
  /// // Open a mono repo with cross-package queries
  /// final context = await DartContext.open(
  ///   '/path/to/monorepo',
  ///   loadDependencies: true,
  /// );
  /// ```
  static Future<DartContext> open(
    String projectPath, {
    bool watch = true,
    bool useCache = true,
    bool loadDependencies = false,
    void Function(String message)? onProgress,
  }) async {
    // 1. Discover all packages
    onProgress?.call('Discovering packages...');
    final packageDiscovery = PackageDiscovery();
    final discovery = await packageDiscovery.discoverPackages(projectPath);

    // 2. Create registry
    final registry = PackageRegistry(rootPath: discovery.rootPath);

    // 3. Initialize local packages
    await registry.initializeLocalPackages(
      discovery.packages,
      useCache: useCache,
      onProgress: onProgress,
    );

    // 4. Load external dependencies if requested
    if (loadDependencies) {
      onProgress?.call('Loading dependencies...');
      await registry.loadAllDependencies();
    }

    // 5. Start unified watcher
    RootWatcher? watcher;
    if (watch) {
      watcher = RootWatcher(
        rootPath: discovery.rootPath,
        registry: registry,
      );
      await watcher.start();
    }

    // 6. Create executor
    // Note: Registry doesn't implement IndexProvider yet, so we pass null
    // TODO: Implement IndexProvider wrapper for PackageRegistry
    final executor = QueryExecutor(
      registry.projectIndex,
    );

    onProgress?.call('Ready');

    return DartContext._(
      rootPath: discovery.rootPath,
      registry: registry,
      executor: executor,
      watcher: watcher,
      discovery: discovery,
    );
  }

  /// The package registry for this context.
  PackageRegistry get registry => _registry;

  /// All discovered packages.
  List<LocalPackage> get packages => _discovery?.packages ?? [];

  /// Number of local packages.
  int get packageCount => _registry.localPackages.length;

  /// Stream of index updates from all local packages.
  ///
  /// Combines update streams from all package indexers.
  Stream<IndexUpdate> get updates {
    final streams = _registry.localPackages.values
        .map((pkg) => pkg.indexer.updates)
        .toList();
    if (streams.isEmpty) return const Stream.empty();
    if (streams.length == 1) return streams.first;
    return streams.reduce((a, b) => a.merge(b));
  }

  /// Execute a query using the DSL.
  ///
  /// Supported queries:
  /// - `def <symbol>` - Find definition
  /// - `refs <symbol>` - Find references
  /// - `members <symbol>` - Get class members
  /// - `impls <symbol>` - Find implementations
  /// - `supertypes <symbol>` - Get supertypes
  /// - `subtypes <symbol>` - Get subtypes
  /// - `hierarchy <symbol>` - Full hierarchy
  /// - `source <symbol>` - Get source code
  /// - `find <pattern> [kind:<kind>] [in:<path>]` - Search
  /// - `grep <pattern>` - Search source code
  /// - `files` - List indexed files
  /// - `stats` - Index statistics
  ///
  /// Example:
  /// ```dart
  /// final result = await context.query('refs AuthRepository.login');
  /// print(result.toText());
  /// ```
  Future<QueryResult> query(String queryString) {
    return _executor.execute(queryString);
  }

  /// Execute a parsed query.
  Future<QueryResult> executeQuery(ScipQuery query) {
    return _executor.executeQuery(query);
  }

  /// Manually refresh a specific file.
  ///
  /// Routes the file to the correct package indexer.
  Future<bool> refreshFile(String filePath) async {
    final pkg = _registry.findPackageForPath(filePath);
    if (pkg == null) return false;
    return pkg.indexer.refreshFile(filePath);
  }

  /// Manually refresh all files in all packages.
  Future<void> refreshAll() async {
    for (final pkg in _registry.localPackages.values) {
      await pkg.indexer.refreshAll();
    }
  }

  /// Get combined index statistics.
  Map<String, dynamic> get stats => _registry.stats;

  /// Whether external dependencies are loaded.
  bool get hasDependencies =>
      _registry.sdkIndex != null ||
      _registry.hostedPackages.isNotEmpty ||
      _registry.flutterPackages.isNotEmpty;

  /// Load pre-indexed dependencies for cross-package queries.
  ///
  /// Call this to enable cross-package queries after opening a context
  /// without the [loadDependencies] option:
  ///
  /// ```dart
  /// final context = await DartContext.open('/path/to/project');
  /// await context.loadDependencies(); // Enable later
  /// ```
  Future<DependencyLoadResult> loadDependencies() async {
    return _registry.loadAllDependencies();
  }

  /// Find which local package owns a file path.
  LocalPackageIndex? findPackageForPath(String filePath) {
    return _registry.findPackageForPath(filePath);
  }

  /// Dispose of resources.
  ///
  /// Stops file watching and cleans up all indexers.
  Future<void> dispose() async {
    await _watcher?.stop();
    _registry.dispose();
  }
}

/// Extension to merge streams.
extension _StreamMerge<T> on Stream<T> {
  Stream<T> merge(Stream<T> other) {
    final controller = StreamController<T>.broadcast();
    listen(controller.add, onError: controller.addError);
    other.listen(controller.add, onError: controller.addError);
    return controller.stream;
  }
}
