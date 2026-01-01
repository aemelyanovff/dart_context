import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../cache/cache_paths.dart';
import '../dart_context.dart';
import '../index/external_index_builder.dart';
import '../utils/pubspec_utils.dart';
import '../version.dart';

/// Mix this in to any MCPServer to add Dart code intelligence via dart_context.
///
/// Provides a single `dart_query` tool that accepts DSL queries like:
/// - `def AuthRepository` - Find definition
/// - `refs login` - Find references
/// - `find Auth* kind:class` - Search with filters
/// - `members MyClass` - Get class members
/// - `hierarchy MyWidget` - Get type hierarchy
///
/// Example usage:
/// ```dart
/// class MyServer extends MCPServer with DartContextSupport {
///   // ...
/// }
/// ```
base mixin DartContextSupport on ToolsSupport, RootsTrackingSupport {
  /// Cached DartContext instances per project root.
  final Map<String, DartContext> _contexts = {};

  /// File watchers for package_config.json per project root.
  final Map<String, StreamSubscription<FileSystemEvent>>
      _packageConfigWatchers = {};

  /// Roots marked as stale (package_config changed since last refresh).
  final Set<String> _staleRoots = {};

  /// Whether to use cached indexes.
  bool get useCache => true;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);

    if (!supportsRoots) {
      log(
        LoggingLevel.warning,
        'DartContextSupport requires the "roots" capability which is not '
        'supported. dart_query tool has been disabled.',
      );
      return result;
    }

    registerTool(dartQueryTool, _handleDartQuery);
    registerTool(dartIndexFlutterTool, _handleIndexFlutter);
    registerTool(dartIndexDepsTool, _handleIndexDeps);
    registerTool(dartRefreshTool, _handleRefresh);
    registerTool(dartStatusTool, _handleStatus);

    return result;
  }

  @override
  Future<void> updateRoots() async {
    await super.updateRoots();

    final currentRoots = await roots;
    final currentRootUris = currentRoots.map((r) => r.uri).toSet();

    // Remove contexts and watchers for roots that no longer exist
    final removedRoots =
        _contexts.keys.where((r) => !currentRootUris.contains(r)).toList();
    for (final root in removedRoots) {
      await _contexts[root]?.dispose();
      _contexts.remove(root);
      await _packageConfigWatchers[root]?.cancel();
      _packageConfigWatchers.remove(root);
      _staleRoots.remove(root);
      log(LoggingLevel.debug, 'Removed DartContext for: $root');
    }

    // Add contexts for new roots (lazily - will be created on first query)
  }

  @override
  Future<void> shutdown() async {
    // Copy to list to avoid concurrent modification
    final contexts = _contexts.values.toList();
    final watchers = _packageConfigWatchers.values.toList();

    _contexts.clear();
    _packageConfigWatchers.clear();
    _staleRoots.clear();

    for (final context in contexts) {
      await context.dispose();
    }
    for (final watcher in watchers) {
      await watcher.cancel();
    }

    await super.shutdown();
  }

  /// Get the current Dart SDK version (major.minor.patch only).
  String? _getCurrentSdkVersion() {
    // Platform.version is like "3.2.0 (stable) ..."
    final versionMatch =
        RegExp(r'^(\d+\.\d+\.\d+)').firstMatch(Platform.version);
    return versionMatch?.group(1);
  }

  /// Start watching package_config.json for changes.
  void _watchPackageConfig(String rootUri, String rootPath) {
    // Cancel existing watcher if any
    _packageConfigWatchers[rootUri]?.cancel();

    final configPath = '$rootPath/.dart_tool/package_config.json';
    final configFile = File(configPath);

    if (!configFile.existsSync()) return;

    try {
      final watcher = configFile.parent.watch().where((event) {
        return event.path.endsWith('package_config.json');
      }).listen((event) {
        log(
          LoggingLevel.info,
          'package_config.json changed for $rootPath - dependencies may need refresh',
        );
        _staleRoots.add(rootUri);
      });

      _packageConfigWatchers[rootUri] = watcher;
      log(LoggingLevel.debug, 'Watching package_config.json for $rootPath');
    } catch (e) {
      log(
        LoggingLevel.warning,
        'Could not watch package_config.json: $e',
      );
    }
  }

  /// Get or create a DartContext for the given project path.
  Future<DartContext?> _getContextForPath(String filePath) async {
    final currentRoots = await roots;

    // Find the root that contains this file
    for (final root in currentRoots) {
      final rootPath = Uri.parse(root.uri).toFilePath();
      if (filePath.startsWith(rootPath)) {
        // Check if we already have a context for this root
        if (_contexts.containsKey(root.uri)) {
          // Warn if stale
          if (_staleRoots.contains(root.uri)) {
            log(
              LoggingLevel.warning,
              'Dependencies may be out of date. Use dart_refresh to reload.',
            );
          }
          return _contexts[root.uri];
        }

        // Create a new context
        try {
          log(LoggingLevel.info, 'Creating DartContext for: ${root.uri}');
          final context = await DartContext.open(
            rootPath,
            watch: true,
            useCache: useCache,
            loadDependencies: true, // Always try to load deps
          );
          _contexts[root.uri] = context;

          // Start watching package_config.json
          _watchPackageConfig(root.uri, rootPath);

          final depsInfo = context.hasDependencies
              ? ', ${context.registry.packageIndexes.length} packages loaded'
              : '';
          log(
            LoggingLevel.info,
            'Indexed ${context.stats['files']} files, '
            '${context.stats['symbols']} symbols$depsInfo',
          );

          return context;
        } catch (e) {
          log(LoggingLevel.error, 'Failed to create DartContext: $e');
          return null;
        }
      }
    }

    return null;
  }

  /// Get context for the first available root.
  Future<DartContext?> _getDefaultContext() async {
    final currentRoots = await roots;
    if (currentRoots.isEmpty) return null;

    final firstRoot = currentRoots.first;
    final rootPath = Uri.parse(firstRoot.uri).toFilePath();

    if (_contexts.containsKey(firstRoot.uri)) {
      // Warn if stale
      if (_staleRoots.contains(firstRoot.uri)) {
        log(
          LoggingLevel.warning,
          'Dependencies may be out of date. Use dart_refresh to reload.',
        );
      }
      return _contexts[firstRoot.uri];
    }

    try {
      log(LoggingLevel.info, 'Creating DartContext for: ${firstRoot.uri}');
      final context = await DartContext.open(
        rootPath,
        watch: true,
        useCache: useCache,
        loadDependencies: true, // Always try to load deps
      );
      _contexts[firstRoot.uri] = context;

      // Start watching package_config.json
      _watchPackageConfig(firstRoot.uri, rootPath);

      final depsInfo = context.hasDependencies
          ? ', ${context.registry.packageIndexes.length} packages loaded'
          : '';
      log(
        LoggingLevel.info,
        'Indexed ${context.stats['files']} files, '
        '${context.stats['symbols']} symbols$depsInfo',
      );

      return context;
    } catch (e) {
      log(LoggingLevel.error, 'Failed to create DartContext: $e');
      return null;
    }
  }

  Future<CallToolResult> _handleDartQuery(CallToolRequest request) async {
    final query = request.arguments?['query'] as String?;
    if (query == null || query.isEmpty) {
      return CallToolResult(
        content: [TextContent(text: 'Missing required argument `query`.')],
        isError: true,
      );
    }

    // Get context - use project hint if provided, otherwise use default
    final projectHint = request.arguments?['project'] as String?;
    DartContext? context;

    if (projectHint != null) {
      context = await _getContextForPath(projectHint);
    } else {
      context = await _getDefaultContext();
    }

    if (context == null) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'No Dart project found. Make sure roots are set and contain a pubspec.yaml.',
          ),
        ],
        isError: true,
      );
    }

    try {
      final result = await context.query(query);
      return CallToolResult(
        content: [TextContent(text: result.toText())],
        isError: false,
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Query error: $e')],
        isError: true,
      );
    }
  }

  /// Handle dart_index_flutter tool.
  Future<CallToolResult> _handleIndexFlutter(CallToolRequest request) async {
    final flutterRoot = request.arguments?['flutterRoot'] as String?;

    // Create a temporary registry for building
    final registry = PackageRegistry(rootPath: flutterRoot ?? '.');
    final builder = ExternalIndexBuilder(registry: registry);

    final messages = <String>[];

    try {
      final result = await builder.indexFlutterPackages(
        flutterPath: flutterRoot,
        onProgress: (msg) {
          log(LoggingLevel.info, msg);
          messages.add(msg);
        },
      );

      if (!result.success) {
        return CallToolResult(
          content: [TextContent(text: 'Failed: ${result.error}')],
          isError: true,
        );
      }

      final output = StringBuffer();
      output.writeln('Flutter ${result.version} indexed successfully');
      output.writeln('');
      output.writeln('Packages indexed: ${result.indexed}');
      output.writeln('Total symbols: ${result.totalSymbols}');
      output.writeln('');
      output.writeln('Results:');
      for (final pkg in result.results) {
        if (pkg.success) {
          output.writeln('  - ${pkg.name}: ${pkg.symbolCount} symbols');
        } else if (pkg.skipped) {
          output.writeln('  - ${pkg.name}: skipped (${pkg.reason})');
        } else {
          output.writeln('  - ${pkg.name}: failed (${pkg.error})');
        }
      }
      output.writeln('');
      output.writeln(
          'Indexes saved to: ${registry.globalCachePath}/flutter/${result.version}/',);

      return CallToolResult(
        content: [TextContent(text: output.toString())],
        isError: false,
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Error indexing Flutter: $e')],
        isError: true,
      );
    }
  }

  /// Handle dart_index_deps tool.
  Future<CallToolResult> _handleIndexDeps(CallToolRequest request) async {
    final projectHint = request.arguments?['projectRoot'] as String?;

    // Resolve project path
    String projectPath;
    if (projectHint != null) {
      projectPath = projectHint;
    } else {
      final currentRoots = await roots;
      if (currentRoots.isEmpty) {
        return CallToolResult(
          content: [TextContent(text: 'No project roots configured.')],
          isError: true,
        );
      }
      projectPath = Uri.parse(currentRoots.first.uri).toFilePath();
    }

    // Check for pubspec.lock
    final lockfile = File('$projectPath/pubspec.lock');
    if (!await lockfile.exists()) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'No pubspec.lock found in $projectPath. Run "dart pub get" first.',
          ),
        ],
        isError: true,
      );
    }

    log(LoggingLevel.info, 'Indexing dependencies from $projectPath...');

    // Create a temporary registry for building
    final registry = PackageRegistry(rootPath: projectPath);
    final builder = ExternalIndexBuilder(registry: registry);

    try {
      final result = await builder.indexDependencies(
        projectPath,
        onProgress: (msg) => log(LoggingLevel.info, msg),
      );

      if (!result.success) {
        return CallToolResult(
          content: [TextContent(text: 'Failed: ${result.error}')],
          isError: true,
        );
      }

      final output = StringBuffer();
      output.writeln('Dependencies indexed from $projectPath');
      output.writeln('');
      output.writeln('Indexed: ${result.indexed}');
      output.writeln('Skipped (already indexed): ${result.skipped}');
      output.writeln('Failed: ${result.failed}');

      if (result.failed > 0) {
        output.writeln('');
        output.writeln('Failed packages:');
        for (final pkg
            in result.results.where((r) => !r.success && !r.skipped)) {
          output.writeln('  - ${pkg.name}-${pkg.version}: ${pkg.error}');
        }
      }

      return CallToolResult(
        content: [TextContent(text: output.toString())],
        isError: false,
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Error indexing dependencies: $e')],
        isError: true,
      );
    }
  }

  /// Handle dart_refresh tool.
  Future<CallToolResult> _handleRefresh(CallToolRequest request) async {
    final projectHint = request.arguments?['projectRoot'] as String?;
    final fullReindex = request.arguments?['fullReindex'] as bool? ?? false;

    // Find the root to refresh
    final currentRoots = await roots;
    Root? targetRoot;

    if (projectHint != null) {
      for (final root in currentRoots) {
        final rootPath = Uri.parse(root.uri).toFilePath();
        if (rootPath == projectHint || projectHint.startsWith(rootPath)) {
          targetRoot = root;
          break;
        }
      }
    } else if (currentRoots.isNotEmpty) {
      targetRoot = currentRoots.first;
    }

    if (targetRoot == null) {
      return CallToolResult(
        content: [TextContent(text: 'No matching project root found.')],
        isError: true,
      );
    }

    final rootPath = Uri.parse(targetRoot.uri).toFilePath();

    // Dispose existing context and clear stale flag
    final existingContext = _contexts.remove(targetRoot.uri);
    if (existingContext != null) {
      await existingContext.dispose();
      log(LoggingLevel.info, 'Disposed existing context for $rootPath');
    }
    _staleRoots.remove(targetRoot.uri);

    // Create fresh context
    try {
      log(LoggingLevel.info, 'Refreshing DartContext for: $rootPath');
      if (fullReindex) {
        log(LoggingLevel.info, 'Full reindex requested (ignoring cache)');
      }
      log(LoggingLevel.info, 'Analyzing project files...');

      final context = await DartContext.open(
        rootPath,
        watch: true,
        useCache: !fullReindex,
        loadDependencies: true,
      );
      _contexts[targetRoot.uri] = context;

      log(LoggingLevel.info, 'Loading dependencies...');

      // Re-establish package_config watcher
      _watchPackageConfig(targetRoot.uri, rootPath);

      final depsInfo = context.hasDependencies
          ? ', ${context.registry.packageIndexes.length} packages loaded'
          : '';

      final output = StringBuffer();
      output.writeln('Refreshed: $rootPath');
      output.writeln('Files: ${context.stats['files']}');
      output.writeln('Symbols: ${context.stats['symbols']}');
      if (context.hasDependencies) {
        output.writeln('Packages: ${context.registry.packageIndexes.length}');
      }

      log(
        LoggingLevel.info,
        'Refreshed ${context.stats['files']} files, '
        '${context.stats['symbols']} symbols$depsInfo',
      );

      return CallToolResult(
        content: [TextContent(text: output.toString())],
        isError: false,
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Error refreshing context: $e')],
        isError: true,
      );
    }
  }

  /// Handle dart_status tool.
  Future<CallToolResult> _handleStatus(CallToolRequest request) async {
    final projectHint = request.arguments?['projectRoot'] as String?;

    // Find the context
    DartContext? context;
    String? rootPath;

    if (projectHint != null) {
      context = await _getContextForPath(projectHint);
      rootPath = projectHint;
    } else {
      final currentRoots = await roots;
      if (currentRoots.isNotEmpty) {
        rootPath = Uri.parse(currentRoots.first.uri).toFilePath();
        if (_contexts.containsKey(currentRoots.first.uri)) {
          context = _contexts[currentRoots.first.uri];
        }
      }
    }

    final output = StringBuffer();
    output.writeln('## Dart Context Status (v$dartContextVersion)');
    output.writeln('');

    if (context == null) {
      output.writeln('Project: ${rootPath ?? "(none)"}');
      output.writeln('Status: Not indexed');
      output.writeln('');
      output.writeln(
          'Use dart_query to trigger indexing, or dart_refresh to reload.',);
    } else {
      output.writeln('Project: ${context.rootPath}');
      output.writeln('Files: ${context.stats['files']}');
      output.writeln('Symbols: ${context.stats['symbols']}');
      output.writeln('References: ${context.stats['references'] ?? 0}');
      output.writeln('');

      // Show discovered packages
      final registry = context.registry;
      final localPkgs = registry.localPackages.keys.toList();
      if (localPkgs.isNotEmpty) {
        output.writeln('### Local Packages (${localPkgs.length})');
        output.writeln('');
        for (final pkg in localPkgs.take(10)) {
          output.writeln('  - $pkg');
        }
        if (localPkgs.length > 10) {
          output.writeln('  ... and ${localPkgs.length - 10} more');
        }
        output.writeln('');
      }

      // Show external indexes
      if (context.hasDependencies) {
        output.writeln('### External Indexes');
        output.writeln('');
        if (registry.loadedSdkVersion != null) {
          output.writeln('SDK: Dart ${registry.loadedSdkVersion}');
        }
        if (registry.loadedFlutterVersion != null) {
          output.writeln(
              'Flutter: ${registry.loadedFlutterVersion} (${registry.flutterPackages.length} packages)',);
        }

        // Show hosted packages
        output.writeln('Hosted packages: ${registry.hostedPackages.length}');
        if (registry.hostedPackages.isNotEmpty) {
          final pkgNames = registry.hostedPackages.keys.take(5).toList();
          for (final name in pkgNames) {
            output.writeln('  - $name');
          }
          if (registry.hostedPackages.length > 5) {
            output.writeln(
                '  ... and ${registry.hostedPackages.length - 5} more',);
          }
        }
        
        // Show git packages
        if (registry.gitPackages.isNotEmpty) {
          output.writeln('Git packages: ${registry.gitPackages.length}');
        }

        // Show git packages
        if (registry.gitPackages.isNotEmpty) {
          output.writeln('Git packages: ${registry.gitPackages.length}');
          final gitNames = registry.gitPackages.keys.take(5).toList();
          for (final name in gitNames) {
            output.writeln('  - $name');
          }
        }

        // Show local (workspace) packages
        if (registry.localIndexes.isNotEmpty) {
          output.writeln('Local packages: ${registry.localIndexes.length}');
          final localNames = registry.localIndexes.keys.take(5).toList();
          for (final name in localNames) {
            output.writeln('  - $name');
          }
        }
      } else {
        output.writeln('External indexes: Not loaded');
        output.writeln(
            'Use dart_index_flutter and dart_index_deps to enable cross-package queries.',);
      }
    }

    // Also show available indexes on disk
    final tempRegistry = PackageRegistry(rootPath: '.');
    final builder = ExternalIndexBuilder(registry: tempRegistry);

    final sdkVersions = await builder.listSdkIndexes();
    final flutterVersions = await CachePaths.listFlutterVersions();
    final packages = await builder.listPackageIndexes();
    final packageSet = packages.map((p) => p.name).toSet();

    output.writeln('');
    output.writeln('### Available Indexes (on disk)');
    output.writeln('');
    output.writeln(
        'SDK versions: ${sdkVersions.isEmpty ? "(none)" : sdkVersions.join(", ")}',);
    output.writeln(
        'Flutter versions: ${flutterVersions.isEmpty ? "(none)" : flutterVersions.join(", ")}',);
    output.writeln('Package indexes: ${packages.length}');

    // Check for Flutter project and give hints
    if (rootPath != null) {
      final pubspecFile = File('$rootPath/pubspec.yaml');
      if (await pubspecFile.exists()) {
        final pubspec = await pubspecFile.readAsString();
        final isFlutter =
            pubspec.contains('flutter:') || pubspec.contains('flutter_test:');

        output.writeln('');
        output.writeln('### Recommendations');
        output.writeln('');

        // Check if Flutter indexes are missing for Flutter project
        final hasFlutterIndexes = flutterVersions.isNotEmpty;
        if (isFlutter && !hasFlutterIndexes) {
          output.writeln(
              '⚠️ Flutter project detected but Flutter SDK not indexed.',);
          output.writeln(
              '   Run: `dart_index_flutter` to enable widget hierarchy queries.',);
          output.writeln('');
        }

        // Check for missing pub dependencies
        final lockFile = File('$rootPath/pubspec.lock');
        if (await lockFile.exists()) {
          final lockContent = await lockFile.readAsString();
          final deps = parsePubspecLock(lockContent);
          final missingDeps =
              deps.where((d) => !packageSet.contains(d.name)).toList();

          if (missingDeps.isNotEmpty) {
            output
                .writeln('📦 ${missingDeps.length} dependencies not indexed:');
            final toShow = missingDeps.take(5).map((d) => d.name).toList();
            output.writeln(
                '   ${toShow.join(", ")}${missingDeps.length > 5 ? " ..." : ""}',);
            output.writeln(
                '   Run: `dart_index_deps` to index all dependencies.',);
            output.writeln('');
          } else if (deps.isNotEmpty) {
            output.writeln('✓ All ${deps.length} dependencies are indexed.');
          }
        } else {
          output.writeln('ℹ️ No pubspec.lock found. Run `dart pub get` first.');
        }

        if (!isFlutter && sdkVersions.isEmpty) {
          output
              .writeln('ℹ️ Dart SDK not indexed. SDK symbols won\'t resolve.');
        }

        // Check if SDK version has changed since indexing
        if (sdkVersions.isNotEmpty) {
          final currentSdkVersion = _getCurrentSdkVersion();
          if (currentSdkVersion != null &&
              !sdkVersions.contains(currentSdkVersion)) {
            output.writeln(
                '⚠️ Current SDK ($currentSdkVersion) differs from indexed: ${sdkVersions.join(", ")}',);
            output.writeln('   Consider re-indexing for accurate results.');
          }
        }
      }
    }

    return CallToolResult(
      content: [TextContent(text: output.toString())],
      isError: false,
    );
  }

  /// The dart_query tool definition.
  static final dartQueryTool = Tool(
    name: 'dart_query',
    description:
        '''Query Dart codebase for semantic information using a simple DSL.

## Query Commands

| Query | Description | Example |
|-------|-------------|---------|
| `def <symbol>` | Find definition | `def AuthRepository` |
| `refs <symbol>` | Find all references | `refs login` |
| `sig <symbol>` | Get signature (no body) | `sig UserService` |
| `members <symbol>` | Get class members | `members UserService` |
| `impls <symbol>` | Find implementations | `impls Repository` |
| `hierarchy <symbol>` | Type hierarchy | `hierarchy MyWidget` |
| `source <symbol>` | Full source code | `source handleLogin` |
| `find <pattern>` | Search symbols | `find Auth*` |
| `which <symbol>` | Disambiguate matches | `which login` |
| `grep <pattern>` | Search in source | `grep /TODO|FIXME/` |
| `calls <symbol>` | What does it call? | `calls AuthService.login` |
| `callers <symbol>` | What calls it? | `callers validateUser` |
| `imports <file>` | File imports | `imports lib/auth.dart` |
| `exports <path>` | Directory exports | `exports lib/` |
| `deps <symbol>` | Dependencies | `deps AuthService` |
| `symbols <file>` | Symbols in file | `symbols lib/auth.dart` |
| `get <scip-id>` | Lookup by SCIP ID | `get "scip-dart..."` |
| `files` | List indexed files | `files` |
| `stats` | Index statistics | `stats` |

## Pattern Syntax

| Pattern | Type | Example |
|---------|------|---------|
| `Auth*` | Glob | Wildcard matching |
| `/TODO|FIXME/` | Regex | Regular expression |
| `/error/i` | Regex | Case-insensitive |
| `~authentcate` | Fuzzy | Typo-tolerant |
| `Class.method` | Qualified | Disambiguate |

## Filters

| Filter | Description | Example |
|--------|-------------|---------|
| `kind:<type>` | Symbol kind | `find * kind:class` |
| `in:<path>` | File path | `find * in:lib/auth/` |

## Grep Flags

| Flag | Description | Example |
|------|-------------|---------|
| `-i` | Case insensitive | `grep error -i` |
| `-v` | Invert match (non-matching) | `grep TODO -v` |
| `-w` | Word boundary | `grep test -w` |
| `-l` | Files with matches | `grep TODO -l` |
| `-L` | Files without matches | `grep TODO -L` |
| `-c` | Count per file | `grep error -c` |
| `-o` | Only matching text | `grep /\\w+Error/ -o` |
| `-F` | Fixed strings (literal) | `grep -F '\$variable'` |
| `-M` | Multiline matching | `grep /class.*\\{/ -M` |
| `-D` | Search external dependencies | `grep StatelessWidget -D` |
| `-C:n` | Context lines | `grep TODO -C:3` |
| `-A:n` | Lines after | `grep error -A:5` |
| `-B:n` | Lines before | `grep error -B:2` |
| `-m:n` | Max matches | `grep TODO -m:10` |
| `--include:glob` | Only matching files | `grep error --include:*.dart` |
| `--exclude:glob` | Skip matching files | `grep TODO --exclude:test/*` |

Kinds: class, method, function, field, enum, mixin, extension, getter, setter, constructor

## Pipe Queries

Chain queries with `|` to process results:
- `find Auth* kind:class | members` - Get members of all Auth classes
- `find *Service | refs` - Find refs for all services
- `grep TODO | refs` - Find refs for symbols containing TODOs

## Examples

```
def AuthRepository              # Definition with source
refs AuthService.login          # References to specific method
sig UserService                 # Class signature (methods as {})
find ~authentcate               # Fuzzy search (finds "authenticate")
grep /throw.*Exception/         # Find exception throws
which login                     # Show all "login" matches
find Auth* kind:class | members # Pipe: classes → their members
```

Semantic code navigation - understands definitions, references, types, call graphs, and relationships.''',
    annotations: ToolAnnotations(
      title: 'Dart Code Query',
      readOnlyHint: true,
    ),
    inputSchema: Schema.object(
      properties: {
        'query': Schema.string(
          description:
              'The query in DSL format. Examples: "def AuthRepository", "refs login", "find Auth* kind:class"',
        ),
        'project': Schema.string(
          description:
              'Optional path hint to select which project root to query (if multiple roots are configured).',
        ),
      },
      required: ['query'],
    ),
  );

  /// Tool to index Flutter SDK packages.
  static final dartIndexFlutterTool = Tool(
    name: 'dart_index_flutter',
    description: '''Index Flutter SDK packages for cross-package queries.

One-time setup that indexes flutter, flutter_test, flutter_driver, flutter_localizations, and flutter_web_plugins.

After indexing, queries like `hierarchy StatefulWidget` and `refs Navigator` will work across your project and Flutter.

Takes ~1 minute for a typical Flutter SDK.''',
    annotations: ToolAnnotations(
      title: 'Index Flutter SDK',
      readOnlyHint: false,
    ),
    inputSchema: Schema.object(
      properties: {
        'flutterRoot': Schema.string(
          description:
              'Path to Flutter SDK root. If not provided, uses FLUTTER_ROOT env var or finds from PATH.',
        ),
      },
    ),
  );

  /// Tool to index pub dependencies.
  static final dartIndexDepsTool = Tool(
    name: 'dart_index_deps',
    description: '''Index pub dependencies from pubspec.lock.

Pre-indexes all packages listed in pubspec.lock for cross-package queries. Skips packages already indexed.

Run this after adding new dependencies or when setting up a new project.

Takes ~1-2 minutes for typical projects.''',
    annotations: ToolAnnotations(
      title: 'Index Dependencies',
      readOnlyHint: false,
    ),
    inputSchema: Schema.object(
      properties: {
        'projectRoot': Schema.string(
          description:
              'Path to project with pubspec.lock. If not provided, uses the first configured root.',
        ),
      },
    ),
  );

  /// Tool to refresh project index.
  static final dartRefreshTool = Tool(
    name: 'dart_refresh',
    description: '''Refresh project index and reload dependencies.

Use after:
- pubspec.yaml or pubspec.lock changes
- Major refactoring
- When you suspect the index is stale

Set fullReindex=true to ignore cache and rebuild from scratch.''',
    annotations: ToolAnnotations(
      title: 'Refresh Index',
      readOnlyHint: false,
    ),
    inputSchema: Schema.object(
      properties: {
        'projectRoot': Schema.string(
          description:
              'Path to project. If not provided, uses the first configured root.',
        ),
        'fullReindex': Schema.bool(
          description: 'Force full re-index, ignoring cache. Default: false.',
        ),
      },
    ),
  );

  /// Tool to show index status.
  static final dartStatusTool = Tool(
    name: 'dart_status',
    description:
        '''Show index status: files, symbols, loaded packages, SDK version.

Displays:
- Project index statistics (files, symbols, references)
- Loaded external packages
- Available pre-computed indexes on disk

Use to verify indexing is complete before querying.''',
    annotations: ToolAnnotations(
      title: 'Index Status',
      readOnlyHint: true,
    ),
    inputSchema: Schema.object(
      properties: {
        'projectRoot': Schema.string(
          description:
              'Path to project. If not provided, uses the first configured root.',
        ),
      },
    ),
  );
}

