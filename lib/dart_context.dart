/// Lightweight semantic code intelligence for Dart.
///
/// Query your codebase with a simple DSL:
/// ```dart
/// final context = await DartContext.open('/path/to/project');
///
/// // Find definition
/// final result = await context.query('def AuthRepository');
///
/// // Find references
/// final refs = await context.query('refs login');
///
/// // Get class members
/// final members = await context.query('members MyClass');
///
/// // Search with filters
/// final classes = await context.query('find Auth* kind:class');
/// ```
///
/// ## Works with any folder structure
///
/// The unified architecture works for:
/// - Single packages
/// - Melos mono repos
/// - Dart pub workspaces
/// - Any folder with multiple packages
///
/// ## Integration with External Analyzers
///
/// When integrating with an existing analyzer (e.g., HologramAnalyzer):
///
/// ```dart
/// import 'package:dart_context/dart_context.dart';
///
/// final adapter = HologramAnalyzerAdapter(
///   projectRoot: analyzer.projectRoot,
///   getResolvedUnit: (path) async {
///     final result = await analyzer.getResolvedUnit(path);
///     return result is ResolvedUnitResult ? result : null;
///   },
///   fileChanges: watcher.events.map((e) => FileChange(
///     path: e.path,
///     type: e.type.toFileChangeType(),
///   )),
/// );
///
/// final indexer = await IncrementalScipIndexer.openWithAdapter(
///   adapter,
///   packageConfig: packageConfig,
///   pubspec: pubspec,
/// );
/// ```
library;

export 'src/adapters/analyzer_adapter.dart';
export 'src/adapters/hologram_adapter.dart';
export 'src/cache/cache_paths.dart' show CachePaths;
export 'src/dart_context.dart';
export 'src/index/external_index_builder.dart'
    show
        ExternalIndexBuilder,
        IndexResult,
        BatchIndexResult,
        PackageIndexResult,
        FlutterIndexResult;
export 'src/index/incremental_indexer.dart'
    show IncrementalScipIndexer, IndexUpdate;
export 'src/index/package_registry.dart'
    show
        PackageRegistry,
        LocalPackageIndex,
        ExternalPackageIndex,
        ExternalPackageType,
        DependencyLoadResult,
        // Backward compatibility
        IndexRegistry,
        IndexScope;
export 'src/index/scip_index.dart'
    show ScipIndex, SymbolInfo, OccurrenceInfo, GrepMatchData;
export 'src/package_discovery.dart'
    show
        LocalPackage,
        DiscoveryResult,
        discoverPackages,
        discoverPackagesSync,
        shouldIgnorePath,
        ignoredSegments;
export 'src/query/query_executor.dart' show QueryExecutor;
export 'src/query/query_parser.dart'
    show ScipQuery, ParsedPattern, PatternType;
export 'src/query/query_result.dart';
export 'src/root_watcher.dart' show RootWatcher;
export 'src/utils/package_config.dart'
    show
        DependencySource,
        ResolvedPackage,
        parsePackageConfig,
        parsePackageConfigSync;
export 'src/version.dart' show dartContextVersion, manifestVersion;

// ─────────────────────────────────────────────────────────────────────────────
// Deprecated exports (for backward compatibility)
// ─────────────────────────────────────────────────────────────────────────────

// These are deprecated and will be removed in a future version.
// Use the new unified architecture instead:
//   - discoverPackages() instead of detectWorkspace()
//   - PackageRegistry instead of WorkspaceRegistry
//   - RootWatcher instead of WorkspaceWatcher
