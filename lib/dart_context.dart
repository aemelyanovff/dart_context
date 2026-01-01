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

// Main entry point
export 'src/dart_context.dart';
export 'src/root_watcher.dart' show RootWatcher;

// Re-export scip_server package (language-agnostic core)
export 'package:scip_server/scip_server.dart'
    show
        // Index types
        ScipIndex,
        SymbolInfo,
        OccurrenceInfo,
        GrepMatchInfo,
        IndexProvider,
        ReferenceWithSource,
        // Query engine
        QueryExecutor,
        ScipQuery,
        QueryAction,
        ParsedPattern,
        PatternType,
        // Result types
        QueryResult,
        DefinitionResult,
        DefinitionMatch,
        ReferencesResult,
        ReferenceMatch,
        AggregatedReferencesResult,
        SymbolReferences,
        MembersResult,
        HierarchyResult,
        SearchResult,
        SourceResult,
        SignatureResult,
        GrepResult,
        GrepMatch,
        GrepFilesResult,
        GrepCountResult,
        CallGraphResult,
        DependenciesResult,
        ImportsResult,
        FilesResult,
        FileSymbolsResult,
        StatsResult,
        WhichResult,
        WhichMatch,
        PipelineResult,
        NotFoundResult,
        ErrorResult,
        // Language binding
        LanguageBinding,
        DiscoveredPackage,
        PackageIndexer,
        // Protocol server
        ScipServer,
        ScipMethod,
        JsonRpcRequest,
        JsonRpcResponse,
        JsonRpcError,
        QueryResponse,
        QueryParams,
        InitializeParams,
        FileChangeParams,
        StatusResult;

// Re-export dart_binding package (Dart-specific)
export 'package:dart_binding/dart_binding.dart'
    show
        // Main binding
        DartBinding,
        DartPackageIndexer,
        // Indexing
        IncrementalScipIndexer,
        IndexCache,
        ExternalIndexBuilder,
        IndexResult,
        BatchIndexResult,
        PackageIndexResult,
        FlutterIndexResult,
        IndexUpdate,
        InitialIndexUpdate,
        CachedIndexUpdate,
        IncrementalIndexUpdate,
        FileUpdatedUpdate,
        FileRemovedUpdate,
        IndexErrorUpdate,
        // Package management
        PackageRegistry,
        LocalPackageIndex,
        ExternalPackageIndex,
        ExternalPackageType,
        DependencyLoadResult,
        IndexScope,
        // Discovery
        LocalPackage,
        DiscoveryResult,
        PackageDiscovery,
        // Cache
        CachePaths,
        // Adapters
        AnalyzerAdapter,
        FileChange,
        FileChangeType,
        HologramAnalyzerAdapter,
        // Utilities
        DependencySource,
        ResolvedPackage,
        parsePackageConfig,
        parsePackageConfigSync,
        dartContextVersion,
        manifestVersion;

// ─────────────────────────────────────────────────────────────────────────────
// Architecture Notes
// ─────────────────────────────────────────────────────────────────────────────

// This package is structured as follows:
//
// packages/
// ├── scip_server/              # Language-agnostic SCIP query engine
// │   ├── ScipIndex             # In-memory SCIP index
// │   ├── QueryExecutor         # DSL query execution
// │   ├── LanguageBinding       # Interface for language implementations
// │   └── ScipServer            # JSON-RPC protocol server
// │
// └── dart_binding/             # Dart-specific implementation
//     ├── DartBinding           # LanguageBinding implementation
//     ├── IncrementalScipIndexer # Incremental Dart indexer
//     ├── PackageRegistry       # Multi-package management
//     └── PackageDiscovery      # Pubspec.yaml discovery
//
// The root package (dart_context) provides:
// - DartContext: High-level API combining the above
// - RootWatcher: File watching for incremental updates
// - MCP server integration
