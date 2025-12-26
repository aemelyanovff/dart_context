import 'dart:async';
import 'dart:io';

import 'index/incremental_indexer.dart';
import 'index/index_registry.dart';
import 'index/scip_index.dart';
import 'query/query_executor.dart';
import 'query/query_parser.dart';
import 'query/query_result.dart';
import 'workspace/workspace_detector.dart';
import 'workspace/workspace_registry.dart';
import 'workspace/workspace_watcher.dart';

export 'index/incremental_indexer.dart'
    show
        IndexUpdate,
        InitialIndexUpdate,
        CachedIndexUpdate,
        IncrementalIndexUpdate,
        FileUpdatedUpdate,
        FileRemovedUpdate,
        IndexErrorUpdate;
export 'workspace/workspace_detector.dart'
    show WorkspaceInfo, WorkspacePackage, WorkspaceType;

/// Lightweight semantic code intelligence for Dart.
///
/// Provides incremental indexing and a query DSL for navigating
/// Dart codebases.
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
class DartContext {
  DartContext._({
    required IncrementalScipIndexer indexer,
    required QueryExecutor executor,
    IndexRegistry? registry,
    WorkspaceInfo? workspace,
    WorkspaceRegistry? workspaceRegistry,
    WorkspaceWatcher? workspaceWatcher,
  })  : _indexer = indexer,
        _executor = executor,
        _registry = registry,
        _workspace = workspace,
        _workspaceRegistry = workspaceRegistry,
        _workspaceWatcher = workspaceWatcher;

  final IncrementalScipIndexer _indexer;
  QueryExecutor _executor;
  IndexRegistry? _registry;
  final WorkspaceInfo? _workspace;
  final WorkspaceRegistry? _workspaceRegistry;
  final WorkspaceWatcher? _workspaceWatcher;

  /// Open a Dart project and create a context.
  ///
  /// This will:
  /// 1. Detect if this is part of a mono repo workspace
  /// 2. Parse project configuration
  /// 3. Load from cache (if valid and [useCache] is true)
  /// 4. Create analyzer context
  /// 5. Perform incremental indexing of changed files
  /// 6. Start file watching (if [watch] is true)
  /// 7. Load pre-indexed dependencies (if [loadDependencies] is true)
  /// 8. Load local workspace packages for cross-package queries
  ///
  /// Set [useCache] to false to force a full re-index.
  ///
  /// Set [loadDependencies] to true to enable cross-package queries
  /// (requires pre-indexed dependencies via `index-sdk` or `index-deps`).
  ///
  /// Example:
  /// ```dart
  /// final context = await DartContext.open('/path/to/project');
  ///
  /// // With cross-package queries enabled:
  /// final context = await DartContext.open(
  ///   '/path/to/project',
  ///   loadDependencies: true,
  /// );
  /// ```
  static Future<DartContext> open(
    String projectPath, {
    bool watch = true,
    bool useCache = true,
    bool loadDependencies = false,
  }) async {
    // Detect workspace (melos, pub workspace, or single package)
    final workspace = await detectWorkspace(projectPath);

    // For mono repos, use workspace-aware opening
    if (workspace != null && workspace.type != WorkspaceType.single) {
      return _openWorkspace(
        projectPath,
        workspace,
        watch: watch,
        useCache: useCache,
        loadDependencies: loadDependencies,
      );
    }

    // Single package mode
    return _openSingle(
      projectPath,
      watch: watch,
      useCache: useCache,
      loadDependencies: loadDependencies,
    );
  }

  /// Open a single package (not in a workspace).
  static Future<DartContext> _openSingle(
    String projectPath, {
    bool watch = true,
    bool useCache = true,
    bool loadDependencies = false,
  }) async {
    final indexer = await IncrementalScipIndexer.open(
      projectPath,
      watch: watch,
      useCache: useCache,
    );

    // Create registry for cross-package queries if requested
    IndexRegistry? registry;
    if (loadDependencies) {
      registry = IndexRegistry(projectIndex: indexer.index);
      await registry.loadDependenciesFrom(projectPath);
    }

    final executor = QueryExecutor(
      indexer.index,
      signatureProvider: indexer.getSignature,
      registry: registry,
    );

    return DartContext._(
      indexer: indexer,
      executor: executor,
      registry: registry,
    );
  }

  /// Open a project that's part of a workspace.
  static Future<DartContext> _openWorkspace(
    String projectPath,
    WorkspaceInfo workspace, {
    bool watch = true,
    bool useCache = true,
    bool loadDependencies = false,
  }) async {
    // Create the workspace registry
    final workspaceRegistry = WorkspaceRegistry(workspace);
    await workspaceRegistry.initialize(useCache: useCache);

    // Find the target package in the workspace
    var targetPkg = workspace.findPackageForPath(projectPath);

    // If opening from workspace root (not a specific package), pick a primary package
    // Prefer Flutter apps (have lib/main.dart), otherwise use the first package
    if (targetPkg == null && workspace.packages.isNotEmpty) {
      // Try to find a Flutter app (has lib/main.dart)
      for (final pkg in workspace.packages) {
        final mainFile = File('${pkg.absolutePath}/lib/main.dart');
        if (mainFile.existsSync()) {
          targetPkg = pkg;
          break;
        }
      }
      // Fall back to first package
      targetPkg ??= workspace.packages.first;
    }

    final targetPath = targetPkg?.absolutePath ?? projectPath;

    // Get the indexer for the target package
    final indexer = workspaceRegistry.indexers[targetPkg?.name] ??
        await IncrementalScipIndexer.open(
          targetPath,
          watch: false, // Workspace watcher handles this
          useCache: useCache,
        );

    // Create registry with workspace root for local packages
    final registry = IndexRegistry(
      projectIndex: indexer.index,
      workspaceRoot: workspace.rootPath,
    );

    // Load ALL local package indexes (including the target package for cross-refs)
    final localIndexes = await workspaceRegistry.loadLocalPackages();
    for (final entry in localIndexes.entries) {
      registry.addLocalIndex(entry.key, entry.value);
    }

    // Load external dependencies if requested
    if (loadDependencies) {
      await registry.loadDependenciesFrom(targetPath);
    }

    // Start workspace watcher if watching is enabled
    WorkspaceWatcher? workspaceWatcher;
    if (watch) {
      workspaceWatcher = WorkspaceWatcher(
        workspace: workspace,
        registry: workspaceRegistry,
      );
      await workspaceWatcher.start();
    }

    final executor = QueryExecutor(
      indexer.index,
      signatureProvider: indexer.getSignature,
      registry: registry,
    );

    return DartContext._(
      indexer: indexer,
      executor: executor,
      registry: registry,
      workspace: workspace,
      workspaceRegistry: workspaceRegistry,
      workspaceWatcher: workspaceWatcher,
    );
  }

  /// The project root path.
  String get projectRoot => _indexer.projectRoot;

  /// The underlying index.
  ScipIndex get index => _indexer.index;

  /// Stream of index updates (file changes, errors, etc.)
  Stream<IndexUpdate> get updates => _indexer.updates;

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
  /// Useful when file watching is disabled.
  Future<bool> refreshFile(String filePath) {
    return _indexer.refreshFile(filePath);
  }

  /// Manually refresh all files.
  Future<void> refreshAll() {
    return _indexer.refreshAll();
  }

  /// Get index statistics.
  Map<String, int> get stats => _indexer.index.stats;

  /// Whether cross-package queries are enabled.
  bool get hasDependencies => _registry != null;

  /// The index registry for cross-package queries (if enabled).
  IndexRegistry? get registry => _registry;

  /// The workspace info (if this project is part of a mono repo).
  WorkspaceInfo? get workspace => _workspace;

  /// Whether this context is part of a workspace.
  bool get isWorkspace => _workspace != null;

  /// Load pre-indexed dependencies for cross-package queries.
  ///
  /// Call this to enable cross-package queries after opening a context
  /// without the [loadDependencies] option:
  ///
  /// ```dart
  /// final context = await DartContext.open('/path/to/project');
  /// await context.loadDependencies(); // Enable cross-package queries later
  /// ```
  ///
  /// Returns the number of packages loaded.
  Future<int> loadDependencies() async {
    if (_registry != null) {
      // Already have a registry, just reload
      return _registry!.loadDependenciesFrom(projectRoot);
    }

    // Create new registry
    _registry = IndexRegistry(
      projectIndex: _indexer.index,
      workspaceRoot: _workspace?.rootPath,
    );
    final count = await _registry!.loadDependenciesFrom(projectRoot);

    // Recreate executor with the registry for cross-package queries
    _executor = QueryExecutor(
      _indexer.index,
      signatureProvider: _indexer.getSignature,
      registry: _registry,
    );

    return count;
  }

  /// Dispose of resources.
  ///
  /// Stops file watching and cleans up.
  Future<void> dispose() async {
    await _workspaceWatcher?.stop();
    _workspaceRegistry?.dispose();
    _registry?.unloadAll();
    await _indexer.dispose();
  }
}

