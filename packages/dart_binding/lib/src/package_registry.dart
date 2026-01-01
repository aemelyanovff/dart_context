import 'dart:convert';
import 'dart:io';

import 'package:scip_server/scip_server.dart';
import 'package:yaml/yaml.dart';

import 'cache/cache_paths.dart';
import 'incremental_indexer.dart';
import 'package_discovery.dart';
import 'utils/package_config.dart';
import 'version.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Package Index Types
// ─────────────────────────────────────────────────────────────────────────────

/// A local package with its indexer for incremental updates.
class LocalPackageIndex {
  LocalPackageIndex({
    required this.name,
    required this.path,
    required IncrementalScipIndexer indexer,
  })  : _indexer = indexer,
        _testIndex = null;

  /// Create a test instance with a direct index (no indexer).
  LocalPackageIndex.forTesting({
    required this.name,
    required this.path,
    required ScipIndex index,
  })  : _indexer = null,
        _testIndex = index;

  /// Package name.
  final String name;

  /// Absolute path to package root.
  final String path;

  /// The indexer that manages this package's index (null for test instances).
  final IncrementalScipIndexer? _indexer;

  /// Direct index for testing.
  final ScipIndex? _testIndex;

  /// Get the indexer (throws if this is a test instance).
  IncrementalScipIndexer get indexer {
    if (_indexer == null) {
      throw StateError(
          'This LocalPackageIndex was created for testing without an indexer',);
    }
    return _indexer!;
  }

  /// The SCIP index for this package.
  ScipIndex get index => _testIndex ?? _indexer!.index;

  /// Dispose the indexer.
  void dispose() {
    _indexer?.dispose();
  }
}

/// An external package (immutable, cached globally).
class ExternalPackageIndex {
  const ExternalPackageIndex({
    required this.name,
    required this.version,
    required this.cachePath,
    required this.index,
    this.type = ExternalPackageType.hosted,
  });

  /// Package name.
  final String name;

  /// Package version (or commit hash for git packages).
  final String version;

  /// Path to the cache directory.
  final String cachePath;

  /// The SCIP index.
  final ScipIndex index;

  /// Type of external package.
  final ExternalPackageType type;

  /// Cache key for this package.
  String get cacheKey {
    return switch (type) {
      ExternalPackageType.sdk => 'sdk-$version',
      ExternalPackageType.flutter => 'flutter-$version/$name',
      ExternalPackageType.hosted => '$name-$version',
      ExternalPackageType.git => '$name-$version',
    };
  }
}

/// Types of external packages.
enum ExternalPackageType { sdk, flutter, hosted, git }

// ─────────────────────────────────────────────────────────────────────────────
// Package Registry
// ─────────────────────────────────────────────────────────────────────────────

/// Unified registry for all package indexes.
///
/// Manages:
/// - Local packages: Mutable, with file watching and incremental updates
/// - External packages: Immutable, loaded from global cache
///
/// ## Local Packages
///
/// Local packages are discovered via [discoverPackages] and each has an
/// [IncrementalScipIndexer] for handling file changes.
///
/// ## External Packages
///
/// External packages are pre-indexed and stored in `~/.dart_context/`:
/// - SDK: `sdk/{version}/`
/// - Flutter: `flutter/{version}/{package}/`
/// - Hosted: `hosted/{name}-{version}/`
/// - Git: `git/{repo}-{commit}/`
///
/// ## Usage
///
/// ```dart
/// // Create registry
/// final registry = PackageRegistry(rootPath: '/path/to/workspace');
///
/// // Initialize local packages
/// await registry.initializeLocalPackages(useCache: true);
///
/// // Load external dependencies
/// await registry.loadDependencies();
///
/// // Query across all packages
/// final symbols = registry.findSymbols('AuthService');
/// ```
class PackageRegistry {
  PackageRegistry({
    required this.rootPath,
    String? globalCachePath,
  }) : _globalCachePath = globalCachePath ?? CachePaths.globalCacheDir;

  /// Create a registry with a single test index.
  ///
  /// This is a convenience factory for unit tests that need to
  /// create a registry with a pre-built index.
  factory PackageRegistry.forTesting({
    required ScipIndex projectIndex,
    ScipIndex? sdkIndex,
    String? sdkVersion,
    Map<String, ScipIndex>? packageIndexes,
    Map<String, ScipIndex>? flutterIndexes,
    Map<String, ScipIndex>? gitIndexes,
  }) {
    final registry = PackageRegistry(
      rootPath: projectIndex.projectRoot,
    );

    // Add the project as a local package
    registry._localPackages['test'] = LocalPackageIndex.forTesting(
      name: 'test',
      path: projectIndex.projectRoot,
      index: projectIndex,
    );

    if (sdkIndex != null) {
      registry._sdkIndex = ExternalPackageIndex(
        name: 'dart',
        version: sdkVersion ?? 'unknown',
        type: ExternalPackageType.sdk,
        cachePath: '',
        index: sdkIndex,
      );
      registry._loadedSdkVersion = sdkVersion;
    }

    packageIndexes?.forEach((key, idx) {
      final parts = key.split('-');
      final name = parts.length > 1 ? parts.first : key;
      final version = parts.length > 1 ? parts.skip(1).join('-') : 'unknown';
      registry._hostedPackages[key] = ExternalPackageIndex(
        name: name,
        version: version,
        type: ExternalPackageType.hosted,
        cachePath: '',
        index: idx,
      );
    });

    flutterIndexes?.forEach((key, idx) {
      registry._flutterPackages[key] = ExternalPackageIndex(
        name: key,
        version: '',
        type: ExternalPackageType.flutter,
        cachePath: '',
        index: idx,
      );
    });

    gitIndexes?.forEach((key, idx) {
      registry._gitPackages[key] = ExternalPackageIndex(
        name: key,
        version: '',
        type: ExternalPackageType.git,
        cachePath: '',
        index: idx,
      );
    });

    return registry;
  }

  /// The root path for this workspace/project.
  final String rootPath;

  final String _globalCachePath;

  // ─────────────────────────────────────────────────────────────────────────
  // Path Helpers (for ExternalIndexBuilder compatibility)
  // ─────────────────────────────────────────────────────────────────────────

  /// Path to SDK index directory.
  String sdkIndexPath(String version) => CachePaths.sdkDir(version);

  /// Path to Flutter package index directory.
  String flutterIndexPath(String version, String packageName) =>
      CachePaths.flutterDir(version, packageName);

  /// Path to hosted package index directory.
  String packageIndexPath(String name, String version) =>
      CachePaths.hostedDir(name, version);

  /// Path to git package index directory.
  String gitIndexPath(String repoCommitKey) => CachePaths.gitDir(repoCommitKey);

  /// Global cache path.
  String get globalCachePath => _globalCachePath;

  // ─────────────────────────────────────────────────────────────────────────
  // Local packages (mutable, watched)
  // ─────────────────────────────────────────────────────────────────────────

  final Map<String, LocalPackageIndex> _localPackages = {};

  /// All local packages in the workspace.
  Map<String, LocalPackageIndex> get localPackages =>
      Map.unmodifiable(_localPackages);

  /// All local package indexes.
  Iterable<ScipIndex> get allLocalIndexes sync* {
    for (final pkg in _localPackages.values) {
      yield pkg.index;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // External packages (immutable, cached)
  // ─────────────────────────────────────────────────────────────────────────

  ExternalPackageIndex? _sdkIndex;
  String? _loadedSdkVersion;
  String? _loadedFlutterVersion;

  final Map<String, ExternalPackageIndex> _flutterPackages = {};
  final Map<String, ExternalPackageIndex> _hostedPackages = {};
  final Map<String, ExternalPackageIndex> _gitPackages = {};

  /// SDK SCIP index (if loaded).
  ScipIndex? get sdkIndex => _sdkIndex?.index;

  /// SDK package (if loaded).
  ExternalPackageIndex? get sdkPackage => _sdkIndex;

  /// Loaded SDK version.
  String? get loadedSdkVersion => _loadedSdkVersion;

  /// Loaded Flutter version.
  String? get loadedFlutterVersion => _loadedFlutterVersion;

  /// All Flutter packages.
  Map<String, ExternalPackageIndex> get flutterPackages =>
      Map.unmodifiable(_flutterPackages);

  /// All hosted packages.
  Map<String, ExternalPackageIndex> get hostedPackages =>
      Map.unmodifiable(_hostedPackages);

  /// All git packages.
  Map<String, ExternalPackageIndex> get gitPackages =>
      Map.unmodifiable(_gitPackages);

  /// All external indexes.
  Iterable<ScipIndex> get allExternalIndexes sync* {
    if (_sdkIndex != null) yield _sdkIndex!.index;
    yield* _flutterPackages.values.map((p) => p.index);
    yield* _hostedPackages.values.map((p) => p.index);
    yield* _gitPackages.values.map((p) => p.index);
  }

  /// All indexes (local + external).
  Iterable<ScipIndex> get allIndexes sync* {
    yield* allLocalIndexes;
    yield* allExternalIndexes;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Initialization
  // ─────────────────────────────────────────────────────────────────────────

  /// Initialize local packages from discovered packages.
  ///
  /// Creates an [IncrementalScipIndexer] for each package and syncs
  /// indexes to the workspace cache.
  ///
  /// Packages that fail to initialize (e.g., missing package_config.json)
  /// are skipped with a warning rather than failing the entire operation.
  Future<void> initializeLocalPackages(
    List<LocalPackage> packages, {
    bool useCache = true,
    void Function(String message)? onProgress,
  }) async {
    // Create registry directory
    final registryDir = CachePaths.workspaceDir(rootPath);
    await Directory(registryDir).create(recursive: true);

    final skipped = <String>[];

    for (final pkg in packages) {
      onProgress?.call('Initializing ${pkg.name}...');

      try {
        final indexer = await IncrementalScipIndexer.open(
          pkg.path,
          watch: false, // RootWatcher handles file watching
          useCache: useCache,
        );

        _localPackages[pkg.name] = LocalPackageIndex(
          name: pkg.name,
          path: pkg.path,
          indexer: indexer,
        );

        // Sync to workspace cache
        await _syncPackageToCache(pkg.name);
      } catch (e) {
        // Skip packages that can't be initialized (missing package_config.json, etc.)
        skipped.add(pkg.name);
        onProgress?.call('Skipped ${pkg.name}: $e');
      }
    }

    // Save metadata for successfully initialized packages
    await _saveMetadata(
        packages.where((p) => !skipped.contains(p.name)).toList(),);

    if (skipped.isNotEmpty) {
      onProgress?.call(
        'Initialized ${_localPackages.length} packages '
        '(${skipped.length} skipped: run `dart pub get` in skipped packages)',
      );
    } else {
      onProgress?.call('Initialized ${_localPackages.length} packages');
    }
  }

  /// Add a local package index directly.
  void addLocalPackage(LocalPackageIndex pkg) {
    _localPackages[pkg.name] = pkg;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Package lookup
  // ─────────────────────────────────────────────────────────────────────────

  /// Find which local package owns a file path.
  LocalPackageIndex? findPackageForPath(String filePath) {
    // Normalize for comparison
    final normalizedPath = _normalizePath(filePath);

    LocalPackageIndex? bestMatch;
    var bestMatchLength = 0;

    for (final pkg in _localPackages.values) {
      final pkgPath = _normalizePath(pkg.path);
      if (normalizedPath.startsWith(pkgPath)) {
        if (pkgPath.length > bestMatchLength) {
          bestMatch = pkg;
          bestMatchLength = pkgPath.length;
        }
      }
    }
    return bestMatch;
  }

  String _normalizePath(String path) {
    final normalized = Directory(path).absolute.path;
    return normalized.endsWith(Platform.pathSeparator)
        ? normalized
        : '$normalized${Platform.pathSeparator}';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SDK Loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load SDK index from cache.
  Future<ScipIndex?> loadSdk(String version) async {
    if (_loadedSdkVersion == version && _sdkIndex != null) {
      return _sdkIndex!.index;
    }

    final indexDir = CachePaths.sdkDir(version);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) return null;

    // Check manifest compatibility
    final manifest = await _loadManifest(indexDir);
    if (!_isManifestCompatible(manifest)) return null;

    final sourceRoot = manifest?['sourcePath'] as String?;

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );

    _sdkIndex = ExternalPackageIndex(
      name: 'dart-sdk',
      version: version,
      cachePath: indexDir,
      index: index,
      type: ExternalPackageType.sdk,
    );
    _loadedSdkVersion = version;

    return index;
  }

  /// Check if SDK index is available.
  Future<bool> hasSdkIndex(String version) => CachePaths.hasSdkIndex(version);

  // ─────────────────────────────────────────────────────────────────────────
  // Flutter Loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load Flutter package index from cache.
  Future<ScipIndex?> loadFlutterPackage(
      String version, String packageName,) async {
    final key = '$version/$packageName';

    if (_flutterPackages.containsKey(key)) {
      return _flutterPackages[key]!.index;
    }

    final indexDir = CachePaths.flutterDir(version, packageName);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) return null;

    final manifest = await _loadManifest(indexDir);
    if (!_isManifestCompatible(manifest)) return null;

    final sourceRoot = manifest?['sourcePath'] as String?;

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );

    _flutterPackages[key] = ExternalPackageIndex(
      name: packageName,
      version: version,
      cachePath: indexDir,
      index: index,
      type: ExternalPackageType.flutter,
    );
    _loadedFlutterVersion = version;

    return index;
  }

  /// Load all Flutter packages for a version.
  Future<int> loadFlutterPackages(String version) async {
    const packages = [
      'flutter',
      'flutter_test',
      'flutter_driver',
      'flutter_localizations',
      'flutter_web_plugins',
    ];

    var loaded = 0;
    for (final pkg in packages) {
      final index = await loadFlutterPackage(version, pkg);
      if (index != null) loaded++;
    }
    return loaded;
  }

  /// Check if Flutter package is available.
  Future<bool> hasFlutterIndex(String version, String packageName) =>
      CachePaths.hasFlutterIndex(version, packageName);

  // ─────────────────────────────────────────────────────────────────────────
  // Hosted Package Loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load hosted package index from cache.
  Future<ScipIndex?> loadHostedPackage(String name, String version) async {
    final key = '$name-$version';

    if (_hostedPackages.containsKey(key)) {
      return _hostedPackages[key]!.index;
    }

    final indexDir = CachePaths.hostedDir(name, version);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) return null;

    final manifest = await _loadManifest(indexDir);
    if (!_isManifestCompatible(manifest)) return null;

    final sourceRoot = manifest?['sourcePath'] as String?;

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );

    _hostedPackages[key] = ExternalPackageIndex(
      name: name,
      version: version,
      cachePath: indexDir,
      index: index,
      type: ExternalPackageType.hosted,
    );

    return index;
  }

  /// Check if hosted package is available.
  Future<bool> hasHostedIndex(String name, String version) =>
      CachePaths.hasHostedIndex(name, version);

  // ─────────────────────────────────────────────────────────────────────────
  // Git Package Loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load git package index from cache.
  Future<ScipIndex?> loadGitPackage(String repoCommitKey) async {
    if (_gitPackages.containsKey(repoCommitKey)) {
      return _gitPackages[repoCommitKey]!.index;
    }

    final indexDir = CachePaths.gitDir(repoCommitKey);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) return null;

    final manifest = await _loadManifest(indexDir);
    if (!_isManifestCompatible(manifest)) return null;

    final sourceRoot = manifest?['sourcePath'] as String?;
    final name = manifest?['name'] as String? ?? repoCommitKey;

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );

    _gitPackages[repoCommitKey] = ExternalPackageIndex(
      name: name,
      version: repoCommitKey,
      cachePath: indexDir,
      index: index,
      type: ExternalPackageType.git,
    );

    return index;
  }

  /// Check if git package is available.
  Future<bool> hasGitIndex(String repoCommitKey) =>
      CachePaths.hasGitIndex(repoCommitKey);

  // ─────────────────────────────────────────────────────────────────────────
  // Dependency Loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load all dependencies for all local packages.
  ///
  /// Parses each package's package_config.json and loads available indexes.
  Future<DependencyLoadResult> loadAllDependencies() async {
    final result = DependencyLoadResult();

    // Collect all unique dependencies from all local packages
    final allDeps = <String, ResolvedPackage>{};

    for (final pkg in _localPackages.values) {
      final deps = await parsePackageConfig(pkg.path);
      for (final dep in deps) {
        allDeps[dep.cacheKey] = dep;
      }
    }

    // Detect and load SDK
    final sdkVersion = await _detectSdkVersion();
    if (sdkVersion != null && await hasSdkIndex(sdkVersion)) {
      await loadSdk(sdkVersion);
      result.sdkLoaded = true;
      result.sdkVersion = sdkVersion;
    }

    // Load each dependency
    for (final dep in allDeps.values) {
      switch (dep.source) {
        case DependencySource.hosted:
          if (dep.version != null &&
              await hasHostedIndex(dep.name, dep.version!)) {
            await loadHostedPackage(dep.name, dep.version!);
            result.hostedLoaded.add(dep.cacheKey);
          } else {
            result.hostedMissing.add(dep.cacheKey);
          }

        case DependencySource.git:
          if (await hasGitIndex(dep.cacheKey)) {
            await loadGitPackage(dep.cacheKey);
            result.gitLoaded.add(dep.cacheKey);
          } else {
            result.gitMissing.add(dep.cacheKey);
          }

        case DependencySource.path:
          // Path dependencies are local packages, already loaded
          if (_localPackages.containsKey(dep.name)) {
            result.localLoaded.add(dep.name);
          }

        case DependencySource.sdk:
          // SDK packages handled separately
          break;
      }
    }

    // Load Flutter packages if any local package uses Flutter
    final flutterVersion = await _detectFlutterVersion();
    if (flutterVersion != null) {
      result.flutterVersion = flutterVersion;
      final count = await loadFlutterPackages(flutterVersion);
      if (count > 0) {
        result.flutterLoaded
            .addAll(_flutterPackages.keys.map((k) => k.split('/').last));
      }
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Query Methods
  // ─────────────────────────────────────────────────────────────────────────

  /// Find symbol by exact ID across all indexes.
  SymbolInfo? getSymbol(String symbolId) {
    for (final index in allIndexes) {
      final symbol = index.getSymbol(symbolId);
      if (symbol != null) return symbol;
    }
    return null;
  }

  /// Find the index that owns a symbol.
  ScipIndex? findOwningIndex(String symbolId) {
    for (final index in allIndexes) {
      if (index.getSymbol(symbolId) != null) return index;
    }
    return null;
  }

  /// Resolve the absolute file path for a symbol.
  ///
  /// Finds the owning index and combines its root with the relative path.
  String? resolveFilePath(String symbolId) {
    final owningIndex = findOwningIndex(symbolId);
    if (owningIndex == null) return null;

    // Try to find the definition occurrence
    final def = owningIndex.findDefinition(symbolId);
    if (def != null) {
      return '${owningIndex.sourceRoot}/${def.file}';
    }

    // Fallback: parse file path from symbol ID
    // Format: "pkg path/to/file.dart/Symbol#"
    final filePathMatch =
        RegExp(r'^[^\s]+\s+([^\s]+\.dart)/').firstMatch(symbolId);
    if (filePathMatch != null) {
      final relativePath = filePathMatch.group(1);
      return '${owningIndex.sourceRoot}/$relativePath';
    }

    return null;
  }

  /// Find definition across all indexes.
  OccurrenceInfo? findDefinition(String symbolId) {
    for (final index in allIndexes) {
      final def = index.findDefinition(symbolId);
      if (def != null) return def;
    }
    return null;
  }

  /// Find all references to a symbol across all indexes.
  List<OccurrenceInfo> findAllReferences(String symbolId) {
    final refs = <OccurrenceInfo>[];
    for (final index in allIndexes) {
      refs.addAll(index.findReferences(symbolId));
    }
    return refs;
  }

  /// Find all references by symbol name.
  ///
  /// Useful for cross-package queries where symbol IDs differ.
  List<({OccurrenceInfo ref, String packageName, String sourceRoot})>
      findAllReferencesByName(String symbolName, {String? symbolKind}) {
    final results =
        <({OccurrenceInfo ref, String packageName, String sourceRoot})>[];

    void searchIndex(ScipIndex index, String packageName) {
      for (final sym in index.findSymbols(symbolName)) {
        // Compare kind strings (e.g., "class", "function", etc.)
        if (symbolKind != null && sym.kindString != symbolKind) continue;
        for (final ref in index.findReferences(sym.symbol)) {
          results.add((
            ref: ref,
            packageName: packageName,
            sourceRoot: index.sourceRoot,
          ),);
        }
      }
    }

    // Search local packages
    for (final entry in _localPackages.entries) {
      searchIndex(entry.value.index, entry.key);
    }

    // Search external packages
    if (_sdkIndex != null) {
      searchIndex(_sdkIndex!.index, 'sdk');
    }
    for (final entry in _flutterPackages.entries) {
      searchIndex(entry.value.index, entry.key);
    }
    for (final entry in _hostedPackages.entries) {
      searchIndex(entry.value.index, entry.key);
    }
    for (final entry in _gitPackages.entries) {
      searchIndex(entry.value.index, entry.key);
    }

    return results;
  }

  /// Find symbols by pattern across all indexes.
  List<SymbolInfo> findSymbols(
    String pattern, {
    IndexScope scope = IndexScope.projectAndLoaded,
  }) {
    final seen = <String>{};
    final results = <SymbolInfo>[];

    void addUnique(Iterable<SymbolInfo> symbols) {
      for (final sym in symbols) {
        if (seen.add(sym.symbol)) results.add(sym);
      }
    }

    // Always search local/project indexes
    for (final index in allLocalIndexes) {
      addUnique(index.findSymbols(pattern));
    }

    // Search external indexes if not limited to project
    if (scope == IndexScope.projectAndLoaded) {
      for (final index in allExternalIndexes) {
        addUnique(index.findSymbols(pattern));
      }
    }

    return results;
  }

  /// Find qualified symbols (container.member).
  Iterable<SymbolInfo> findQualified(String container, String member) {
    final seen = <String>{};
    final results = <SymbolInfo>[];

    for (final index in allIndexes) {
      for (final sym in index.findQualified(container, member)) {
        if (seen.add(sym.symbol)) results.add(sym);
      }
    }

    return results;
  }

  /// Get callers of a symbol.
  List<SymbolInfo> getCallers(String symbolId) {
    final callers = <String, SymbolInfo>{};
    for (final index in allIndexes) {
      for (final caller in index.getCallers(symbolId)) {
        callers[caller.symbol] = caller;
      }
    }
    return callers.values.toList();
  }

  /// Find all callers by symbol name.
  List<SymbolInfo> findAllCallersByName(String symbolName) {
    final callers = <String, SymbolInfo>{};

    void addCallers(ScipIndex index) {
      for (final sym in index.findSymbols(symbolName)) {
        for (final caller in index.getCallers(sym.symbol)) {
          callers[caller.symbol] = caller;
        }
      }
    }

    for (final index in allIndexes) {
      addCallers(index);
    }

    return callers.values.toList();
  }

  /// Get calls made by a symbol.
  List<SymbolInfo> getCalls(String symbolId) {
    final calls = <String, SymbolInfo>{};
    for (final index in allIndexes) {
      for (final called in index.getCalls(symbolId)) {
        calls[called.symbol] = called;
      }
    }
    return calls.values.toList();
  }

  /// Get supertypes of a symbol.
  List<SymbolInfo> supertypesOf(String symbolId) {
    final supertypes = <SymbolInfo>[];
    for (final index in allIndexes) {
      supertypes.addAll(index.supertypesOf(symbolId));
    }
    return supertypes;
  }

  /// Get subtypes of a symbol.
  List<SymbolInfo> subtypesOf(String symbolId) {
    final subtypes = <SymbolInfo>[];
    for (final index in allIndexes) {
      subtypes.addAll(index.subtypesOf(symbolId));
    }
    return subtypes;
  }

  /// Get members of a class/mixin.
  List<SymbolInfo> membersOf(String symbolId) {
    for (final index in allIndexes) {
      final members = index.membersOf(symbolId).toList();
      if (members.isNotEmpty) return members;
    }
    return [];
  }

  /// Get source code for a symbol.
  Future<String?> getSource(String symbolId) async {
    final owningIndex = findOwningIndex(symbolId);
    if (owningIndex == null) return null;
    return owningIndex.getSource(symbolId);
  }

  /// Grep across all local packages.
  Future<List<GrepMatchData>> grep(
    RegExp pattern, {
    String? pathFilter,
    String? includeGlob,
    String? excludeGlob,
    int linesBefore = 2,
    int linesAfter = 2,
    bool invertMatch = false,
    int? maxPerFile,
    bool multiline = false,
    bool onlyMatching = false,
    bool includeExternal = false,
  }) async {
    final results = <GrepMatchData>[];
    final searchedPaths = <String>{};

    Future<void> searchIndex(ScipIndex index) async {
      if (searchedPaths.contains(index.sourceRoot)) return;
      searchedPaths.add(index.sourceRoot);

      results.addAll(await index.grep(
        pattern,
        pathFilter: pathFilter,
        includeGlob: includeGlob,
        excludeGlob: excludeGlob,
        linesBefore: linesBefore,
        linesAfter: linesAfter,
        invertMatch: invertMatch,
        maxPerFile: maxPerFile,
        multiline: multiline,
        onlyMatching: onlyMatching,
      ),);
    }

    // Always search local packages
    for (final index in allLocalIndexes) {
      await searchIndex(index);
    }

    if (!includeExternal) return results;

    // Search external if requested
    for (final index in allExternalIndexes) {
      await searchIndex(index);
    }

    return results;
  }

  /// The first local index (used as the "primary" project index).
  ScipIndex get projectIndex {
    return _localPackages.values.isNotEmpty
        ? _localPackages.values.first.index
        : _emptyIndex;
  }

  /// Local indexes by name.
  Map<String, ScipIndex> get localIndexes =>
      _localPackages.map((k, v) => MapEntry(k, v.index));

  /// Hosted package indexes (alias for hostedPackages).
  Map<String, ScipIndex> get packageIndexes =>
      _hostedPackages.map((k, v) => MapEntry(k, v.index));

  // Placeholder empty index for when no packages exist
  static final _emptyIndex = ScipIndex.empty();

  // ─────────────────────────────────────────────────────────────────────────
  // Statistics
  // ─────────────────────────────────────────────────────────────────────────

  /// Get combined statistics.
  Map<String, dynamic> get stats {
    var totalFiles = 0;
    var totalSymbols = 0;
    var totalReferences = 0;

    for (final pkg in _localPackages.values) {
      final s = pkg.index.stats;
      totalFiles += s['files'] ?? 0;
      totalSymbols += s['symbols'] ?? 0;
      totalReferences += s['references'] ?? 0;
    }

    return {
      'files': totalFiles,
      'symbols': totalSymbols,
      'references': totalReferences,
      'packages': _localPackages.length,
      'localPackageNames': _localPackages.keys.toList(),
      'sdkLoaded': _sdkIndex != null,
      'sdkVersion': _loadedSdkVersion,
      'flutterVersion': _loadedFlutterVersion,
      'flutterPackagesLoaded': _flutterPackages.length,
      'hostedPackagesLoaded': _hostedPackages.length,
      'hostedPackageNames': _hostedPackages.keys.toList(),
      'gitPackagesLoaded': _gitPackages.length,
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Unload Methods
  // ─────────────────────────────────────────────────────────────────────────

  /// Unload SDK index.
  void unloadSdk() {
    _sdkIndex = null;
    _loadedSdkVersion = null;
  }

  /// Unload a hosted package.
  void unloadHostedPackage(String name, String version) {
    _hostedPackages.remove('$name-$version');
  }

  /// Unload all external packages.
  void unloadAllExternal() {
    _sdkIndex = null;
    _loadedSdkVersion = null;
    _loadedFlutterVersion = null;
    _flutterPackages.clear();
    _hostedPackages.clear();
    _gitPackages.clear();
  }

  /// Dispose all local package indexers.
  void dispose() {
    for (final pkg in _localPackages.values) {
      pkg.dispose();
    }
    _localPackages.clear();
    unloadAllExternal();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private Helpers
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _syncPackageToCache(String packageName) async {
    final pkg = _localPackages[packageName];
    if (pkg == null) return;

    final localDir = CachePaths.localPackageDir(rootPath, packageName);
    await Directory(localDir).create(recursive: true);

    // Copy index
    final sourceIndex = CachePaths.packageWorkingIndex(pkg.path);
    final destIndex = CachePaths.localPackageIndex(rootPath, packageName);

    if (await File(sourceIndex).exists()) {
      await File(sourceIndex).copy(destIndex);
    }

    // Write manifest
    await _writeManifest(localDir, pkg);
  }

  Future<void> _writeManifest(String dir, LocalPackageIndex pkg) async {
    final manifest = {
      'type': 'local',
      'name': pkg.name,
      'sourcePath': pkg.path,
      'indexedAt': DateTime.now().toIso8601String(),
      'dartContextVersion': dartContextVersion,
      'manifestVersion': manifestVersion,
    };

    await File('$dir/manifest.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  Future<void> _saveMetadata(List<LocalPackage> packages) async {
    final metadata = {
      'rootPath': rootPath,
      'packages': packages
          .map((p) => {
                'name': p.name,
                'relativePath': p.relativePath,
              },)
          .toList(),
      'updatedAt': DateTime.now().toIso8601String(),
      'dartContextVersion': dartContextVersion,
    };

    final file = File(CachePaths.workspaceMetadata(rootPath));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata),
    );
  }

  Future<Map<String, dynamic>?> _loadManifest(String indexDir) async {
    final manifestFile = File('$indexDir/manifest.json');
    if (!await manifestFile.exists()) return null;
    try {
      final content = await manifestFile.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  bool _isManifestCompatible(Map<String, dynamic>? manifest) {
    if (manifest == null) return true; // Old manifests without version
    final cachedVersion = manifest['dartContextVersion'] as String?;
    return cachedVersion == null || isVersionCompatible(cachedVersion);
  }

  Future<String?> _detectSdkVersion() async {
    try {
      final result = await Process.run('dart', ['--version']);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final match =
            RegExp(r'Dart SDK version: (\d+\.\d+\.\d+)').firstMatch(output);
        return match?.group(1);
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _detectFlutterVersion() async {
    // Check if any local package uses Flutter
    for (final pkg in _localPackages.values) {
      final pubspecFile = File('${pkg.path}/pubspec.yaml');
      if (!await pubspecFile.exists()) continue;

      try {
        final content = await pubspecFile.readAsString();
        final pubspec = loadYaml(content) as YamlMap?;
        final deps = pubspec?['dependencies'] as YamlMap?;
        final flutter = deps?['flutter'];
        if (flutter is YamlMap && flutter['sdk'] == 'flutter') {
          // Found a Flutter project
          return await _getFlutterVersion();
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _getFlutterVersion() async {
    try {
      final result = await Process.run('flutter', ['--version', '--machine']);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final match =
            RegExp(r'"frameworkVersion":\s*"([^"]+)"').firstMatch(output);
        return match?.group(1);
      }
    } catch (_) {}

    try {
      final result = await Process.run('flutter', ['--version']);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final match = RegExp(r'Flutter\s+(\d+\.\d+\.\d+)').firstMatch(output);
        return match?.group(1);
      }
    } catch (_) {}

    return null;
  }
}

/// Scope for cross-index queries.
enum IndexScope {
  /// Only search the project index.
  project,

  /// Search project and already loaded external indexes.
  projectAndLoaded,
}

// ─────────────────────────────────────────────────────────────────────────────
// Result Types
// ─────────────────────────────────────────────────────────────────────────────

/// Result of loading dependencies.
class DependencyLoadResult {
  bool sdkLoaded = false;
  String? sdkVersion;
  String? flutterVersion;

  final List<String> hostedLoaded = [];
  final List<String> hostedMissing = [];
  final List<String> gitLoaded = [];
  final List<String> gitMissing = [];
  final List<String> localLoaded = [];
  final List<String> flutterLoaded = [];

  int get totalLoaded =>
      hostedLoaded.length +
      gitLoaded.length +
      localLoaded.length +
      flutterLoaded.length +
      (sdkLoaded ? 1 : 0);

  int get totalMissing => hostedMissing.length + gitMissing.length;

  @override
  String toString() {
    final parts = <String>[];
    if (sdkLoaded) parts.add('SDK $sdkVersion');
    if (hostedLoaded.isNotEmpty) parts.add('${hostedLoaded.length} hosted');
    if (gitLoaded.isNotEmpty) parts.add('${gitLoaded.length} git');
    if (localLoaded.isNotEmpty) parts.add('${localLoaded.length} local');
    if (flutterLoaded.isNotEmpty) parts.add('${flutterLoaded.length} flutter');
    return 'DependencyLoadResult(${parts.join(", ")})';
  }
}
