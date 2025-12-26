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
export 'src/index/index_registry.dart'
    show IndexRegistry, IndexScope, DependencyLoadResult;
export 'src/index/scip_index.dart'
    show ScipIndex, SymbolInfo, OccurrenceInfo, GrepMatchData;
export 'src/query/query_executor.dart' show QueryExecutor;
export 'src/query/query_parser.dart'
    show ScipQuery, ParsedPattern, PatternType;
export 'src/query/query_result.dart';
export 'src/utils/package_config.dart'
    show
        DependencySource,
        ResolvedPackage,
        parsePackageConfig,
        parsePackageConfigSync;
export 'src/workspace/workspace_detector.dart'
    show
        WorkspaceInfo,
        WorkspacePackage,
        WorkspaceType,
        MelosConfig,
        detectWorkspace,
        detectWorkspaceSync;
export 'src/workspace/workspace_registry.dart' show WorkspaceRegistry;
export 'src/workspace/workspace_watcher.dart'
    show WorkspaceWatcher, WorkspaceWatchConfig;

