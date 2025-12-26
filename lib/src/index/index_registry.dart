import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../cache/cache_paths.dart';
import '../utils/package_config.dart';
import '../utils/pubspec_utils.dart';
import 'scip_index.dart';

/// Manages multiple SCIP indexes for cross-package queries.
///
/// Supports loading indexes from:
/// - Project: The main project being analyzed
/// - SDK: Dart/Flutter SDK (pre-computed)
/// - Packages: Pub packages (pre-computed)
///
/// Indexes are loaded lazily on demand to minimize memory usage.
///
/// ## Storage Layout
///
/// ```
/// ~/.dart_context/
///   sdk/
///     3.2.0/
///       index.scip
///       manifest.json
///   packages/
///     collection-1.18.0/
///       index.scip
///       manifest.json
///     analyzer-6.3.0/
///       index.scip
///       manifest.json
/// ```
///
/// ## Usage
///
/// ```dart
/// final registry = IndexRegistry(projectIndex: myProjectIndex);
///
/// // Load SDK index on demand
/// await registry.loadSdk('3.2.0');
///
/// // Load package index on demand
/// await registry.loadPackage('analyzer', '6.3.0');
///
/// // Query across all loaded indexes
/// final symbols = registry.findSymbols('RecursiveAstVisitor');
/// ```
class IndexRegistry {
  IndexRegistry({
    required ScipIndex projectIndex,
    String? globalCachePath,
    String? workspaceRoot,
  })  : _projectIndex = projectIndex,
        _globalCachePath = globalCachePath ?? CachePaths.globalCacheDir,
        _workspaceRoot = workspaceRoot;

  /// Creates a registry with pre-loaded indexes for testing.
  ///
  /// This constructor is intended for unit tests that need to simulate
  /// cross-package queries without actual SDK/package indexes on disk.
  IndexRegistry.withIndexes({
    required ScipIndex projectIndex,
    ScipIndex? sdkIndex,
    String? sdkVersion,
    Map<String, ScipIndex>? packageIndexes,
    String? globalCachePath,
    String? workspaceRoot,
  })  : _projectIndex = projectIndex,
        _globalCachePath = globalCachePath ?? CachePaths.globalCacheDir,
        _workspaceRoot = workspaceRoot,
        _sdkIndex = sdkIndex,
        _loadedSdkVersion = sdkVersion {
    if (packageIndexes != null) {
      _packageIndexes.addAll(packageIndexes);
    }
  }

  final ScipIndex _projectIndex;
  final String _globalCachePath;
  final String? _workspaceRoot;
  
  /// Package indexes keyed by cache key (e.g., "collection-1.18.0").
  final Map<String, ScipIndex> _packageIndexes = {};
  
  /// Flutter package indexes keyed by "version/packageName" (e.g., "3.32.0/flutter").
  final Map<String, ScipIndex> _flutterIndexes = {};
  
  /// Git package indexes keyed by repo-commit (e.g., "fluxon-bfef6c5e").
  final Map<String, ScipIndex> _gitIndexes = {};
  
  /// Local package indexes keyed by package name.
  final Map<String, ScipIndex> _localIndexes = {};
  
  ScipIndex? _sdkIndex;
  String? _loadedSdkVersion;
  String? _loadedFlutterVersion;

  /// The main project index.
  ScipIndex get projectIndex => _projectIndex;

  /// Currently loaded SDK index (if any).
  ScipIndex? get sdkIndex => _sdkIndex;

  /// Currently loaded SDK version.
  String? get loadedSdkVersion => _loadedSdkVersion;

  /// All loaded package indexes (hosted packages).
  Map<String, ScipIndex> get packageIndexes =>
      Map.unmodifiable(_packageIndexes);

  /// All loaded Flutter package indexes.
  Map<String, ScipIndex> get flutterIndexes =>
      Map.unmodifiable(_flutterIndexes);

  /// All loaded git package indexes.
  Map<String, ScipIndex> get gitIndexes => Map.unmodifiable(_gitIndexes);

  /// All loaded local package indexes.
  Map<String, ScipIndex> get localIndexes => Map.unmodifiable(_localIndexes);

  /// Loaded Flutter version, if any.
  String? get loadedFlutterVersion => _loadedFlutterVersion;

  /// Path to global cache directory.
  String get globalCachePath => _globalCachePath;

  /// Workspace root path (if in a mono repo).
  String? get workspaceRoot => _workspaceRoot;

  // ─────────────────────────────────────────────────────────────────────────
  // Path helpers (using CachePaths)
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

  /// Path to local package index in workspace registry.
  String localIndexPath(String packageName) {
    final wsRoot = _workspaceRoot ?? _projectIndex.projectRoot;
    return CachePaths.localPackageDir(wsRoot, packageName);
  }

  /// All external indexes (SDK + Flutter + hosted + git + local).
  ///
  /// Order: local → SDK → Flutter → hosted → git
  /// (Local first so project dependencies take precedence)
  Iterable<ScipIndex> get _externalIndexes sync* {
    yield* _localIndexes.values;
    if (_sdkIndex != null) {
      yield _sdkIndex!;
    }
    yield* _flutterIndexes.values;
    yield* _packageIndexes.values;
    yield* _gitIndexes.values;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SDK loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load SDK index from cache.
  ///
  /// Returns the loaded index, or null if not found in cache.
  /// Use [ExternalIndexBuilder] to create the index first.
  Future<ScipIndex?> loadSdk(String version) async {
    if (_loadedSdkVersion == version && _sdkIndex != null) {
      return _sdkIndex;
    }

    final indexDir = sdkIndexPath(version);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) {
      return null;
    }

    // Read manifest to get actual source path
    final manifest = await _loadManifest(indexDir);
    final sourceRoot = manifest?['sourcePath'] as String?;

    _sdkIndex = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );
    _loadedSdkVersion = version;
    return _sdkIndex;
  }

  /// Check if SDK index is available in cache.
  Future<bool> hasSdkIndex(String version) async {
    return CachePaths.hasSdkIndex(version);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Flutter package loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load Flutter package index from cache.
  ///
  /// Returns the loaded index, or null if not found in cache.
  /// Use [ExternalIndexBuilder.indexFlutterPackages] to create indexes first.
  Future<ScipIndex?> loadFlutterPackage(
      String version, String packageName) async {
    final key = '$version/$packageName';

    if (_flutterIndexes.containsKey(key)) {
      return _flutterIndexes[key];
    }

    final indexDir = flutterIndexPath(version, packageName);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) {
      return null;
    }

    // Read manifest to get actual source path
    final manifest = await _loadManifest(indexDir);
    final sourceRoot = manifest?['sourcePath'] as String?;

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );
    _flutterIndexes[key] = index;
    _loadedFlutterVersion = version;
    return index;
  }

  /// Load all Flutter packages for a given version.
  ///
  /// Returns the number of packages loaded.
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

  /// Check if Flutter package index is available in cache.
  Future<bool> hasFlutterIndex(String version, String packageName) async {
    return CachePaths.hasFlutterIndex(version, packageName);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Hosted package loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load hosted package index from cache.
  ///
  /// Returns the loaded index, or null if not found in cache.
  /// Use [ExternalIndexBuilder] to create the index first.
  Future<ScipIndex?> loadPackage(String name, String version) async {
    final key = '$name-$version';

    if (_packageIndexes.containsKey(key)) {
      return _packageIndexes[key];
    }

    final indexDir = packageIndexPath(name, version);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) {
      return null;
    }

    // Read manifest to get actual source path
    final manifest = await _loadManifest(indexDir);
    final sourceRoot = manifest?['sourcePath'] as String?;

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );
    _packageIndexes[key] = index;
    return index;
  }

  /// Check if hosted package index is available in cache.
  Future<bool> hasPackageIndex(String name, String version) async {
    return CachePaths.hasHostedIndex(name, version);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Git package loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load git package index from cache.
  ///
  /// [repoCommitKey] should be in format `<repo>-<short-commit>`.
  Future<ScipIndex?> loadGitPackage(String repoCommitKey) async {
    if (_gitIndexes.containsKey(repoCommitKey)) {
      return _gitIndexes[repoCommitKey];
    }

    final indexDir = gitIndexPath(repoCommitKey);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) {
      return null;
    }

    final manifest = await _loadManifest(indexDir);
    final sourceRoot = manifest?['sourcePath'] as String?;

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );
    _gitIndexes[repoCommitKey] = index;
    return index;
  }

  /// Check if git package index is available in cache.
  Future<bool> hasGitIndex(String repoCommitKey) async {
    return CachePaths.hasGitIndex(repoCommitKey);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Local (path dependency) package loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load local package index from workspace registry.
  ///
  /// For mono repo packages that are path dependencies.
  Future<ScipIndex?> loadLocalPackage(String packageName) async {
    if (_localIndexes.containsKey(packageName)) {
      return _localIndexes[packageName];
    }

    final indexDir = localIndexPath(packageName);
    final indexPath = '$indexDir/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) {
      return null;
    }

    final manifest = await _loadManifest(indexDir);
    final sourceRoot = manifest?['sourcePath'] as String?;

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: indexDir,
      sourceRoot: sourceRoot,
    );
    _localIndexes[packageName] = index;
    return index;
  }

  /// Check if local package index is available in workspace registry.
  Future<bool> hasLocalIndex(String packageName) async {
    final wsRoot = _workspaceRoot ?? _projectIndex.projectRoot;
    return CachePaths.hasLocalPackageIndex(wsRoot, packageName);
  }

  /// Add a local package index directly (for on-the-fly indexing).
  void addLocalIndex(String packageName, ScipIndex index) {
    _localIndexes[packageName] = index;
  }

  /// Find symbol by exact ID across all loaded indexes.
  ///
  /// Searches in order: project → local → SDK → hosted → git
  SymbolInfo? getSymbol(String symbolId) {
    // Check project first
    final projectSymbol = _projectIndex.getSymbol(symbolId);
    if (projectSymbol != null) return projectSymbol;

    // Check external indexes
    for (final index in _externalIndexes) {
      final symbol = index.getSymbol(symbolId);
      if (symbol != null) return symbol;
    }

    return null;
  }

  /// Find the index that owns a symbol.
  ///
  /// Returns null if symbol not found in any index.
  ScipIndex? findOwningIndex(String symbolId) {
    if (_projectIndex.getSymbol(symbolId) != null) {
      return _projectIndex;
    }
    for (final index in _externalIndexes) {
      if (index.getSymbol(symbolId) != null) {
        return index;
      }
    }
    return null;
  }

  /// Find definition across all loaded indexes.
  ///
  /// Returns the first definition found in order: project → local → SDK → hosted → git
  OccurrenceInfo? findDefinition(String symbolId) {
    // Check project first
    final projectDef = _projectIndex.findDefinition(symbolId);
    if (projectDef != null) return projectDef;

    // Check external indexes
    for (final index in _externalIndexes) {
      final def = index.findDefinition(symbolId);
      if (def != null) return def;
    }

    return null;
  }

  /// Resolve a file path to an absolute path for a symbol.
  ///
  /// Uses the owning index's sourceRoot to resolve relative paths.
  String? resolveFilePath(String symbolId) {
    final owningIndex = findOwningIndex(symbolId);
    if (owningIndex == null) return null;

    final def = owningIndex.findDefinition(symbolId);
    if (def == null) return null;

    return '${owningIndex.sourceRoot}/${def.file}';
  }

  /// Get source code for a symbol from any index.
  ///
  /// Searches across all loaded indexes to find the source.
  Future<String?> getSource(String symbolId) async {
    final owningIndex = findOwningIndex(symbolId);
    if (owningIndex == null) return null;
    return owningIndex.getSource(symbolId);
  }

  /// Find all references to a symbol across all loaded indexes.
  ///
  /// Combines references from project and all external indexes.
  List<OccurrenceInfo> findAllReferences(String symbolId) {
    final refs = <OccurrenceInfo>[];

    // Add references from all indexes
    refs.addAll(_projectIndex.findReferences(symbolId));
    for (final index in _externalIndexes) {
      refs.addAll(index.findReferences(symbolId));
    }

    return refs;
  }

  /// Find all references to a symbol BY NAME across all loaded indexes.
  ///
  /// This is useful for workspace queries where symbol IDs differ between
  /// packages. It finds the symbol in each index and aggregates all refs.
  ///
  /// [symbolName] is the simple name (e.g., "UserProvider").
  /// [symbolKind] optionally filters by kind (class, method, etc.).
  List<({OccurrenceInfo ref, String packageName, String sourceRoot})>
      findAllReferencesByName(String symbolName, {String? symbolKind}) {
    final results =
        <({OccurrenceInfo ref, String packageName, String sourceRoot})>[];

    // Search in project index
    for (final sym in _projectIndex.findSymbols(symbolName)) {
      if (symbolKind != null && sym.kind != symbolKind) continue;
      for (final ref in _projectIndex.findReferences(sym.symbol)) {
        results.add((
          ref: ref,
          packageName: 'project',
          sourceRoot: _projectIndex.sourceRoot,
        ));
      }
    }

    // Search in local indexes (workspace packages)
    for (final entry in _localIndexes.entries) {
      final index = entry.value;
      for (final sym in index.findSymbols(symbolName)) {
        if (symbolKind != null && sym.kind != symbolKind) continue;
        for (final ref in index.findReferences(sym.symbol)) {
          results.add((
            ref: ref,
            packageName: entry.key,
            sourceRoot: index.sourceRoot,
          ));
        }
      }
    }

    // Also search other external indexes (SDK, hosted, git)
    if (_sdkIndex != null) {
      for (final sym in _sdkIndex!.findSymbols(symbolName)) {
        if (symbolKind != null && sym.kind != symbolKind) continue;
        for (final ref in _sdkIndex!.findReferences(sym.symbol)) {
          results.add((
            ref: ref,
            packageName: 'sdk',
            sourceRoot: _sdkIndex!.sourceRoot,
          ));
        }
      }
    }

    for (final entry in _flutterIndexes.entries) {
      final index = entry.value;
      for (final sym in index.findSymbols(symbolName)) {
        if (symbolKind != null && sym.kind != symbolKind) continue;
        for (final ref in index.findReferences(sym.symbol)) {
          results.add((
            ref: ref,
            packageName: entry.key,
            sourceRoot: index.sourceRoot,
          ));
        }
      }
    }

    for (final entry in _packageIndexes.entries) {
      final index = entry.value;
      for (final sym in index.findSymbols(symbolName)) {
        if (symbolKind != null && sym.kind != symbolKind) continue;
        for (final ref in index.findReferences(sym.symbol)) {
          results.add((
            ref: ref,
            packageName: entry.key,
            sourceRoot: index.sourceRoot,
          ));
        }
      }
    }

    return results;
  }

  /// Get all calls made by a symbol across all indexes.
  List<SymbolInfo> getCalls(String symbolId) {
    final calls = <String, SymbolInfo>{};

    // Get calls from all indexes
    for (final called in _projectIndex.getCalls(symbolId)) {
      calls[called.symbol] = called;
    }
    for (final index in _externalIndexes) {
      for (final called in index.getCalls(symbolId)) {
        calls[called.symbol] = called;
      }
    }

    return calls.values.toList();
  }

  /// Get all callers of a symbol across all indexes.
  List<SymbolInfo> getCallers(String symbolId) {
    final callers = <String, SymbolInfo>{};

    // Get callers from all indexes
    for (final caller in _projectIndex.getCallers(symbolId)) {
      callers[caller.symbol] = caller;
    }
    for (final index in _externalIndexes) {
      for (final caller in index.getCallers(symbolId)) {
        callers[caller.symbol] = caller;
      }
    }

    return callers.values.toList();
  }

  /// Find all callers of a symbol BY NAME across all loaded indexes.
  ///
  /// This is useful for workspace queries where symbol IDs differ between
  /// packages. It finds the symbol in each index and aggregates all callers.
  ///
  /// [symbolName] is the simple name (e.g., "fetchData").
  List<SymbolInfo> findAllCallersByName(String symbolName) {
    final callers = <String, SymbolInfo>{};

    void addCallers(ScipIndex index) {
      for (final sym in index.findSymbols(symbolName)) {
        for (final caller in index.getCallers(sym.symbol)) {
          callers[caller.symbol] = caller;
        }
      }
    }

    // Search all indexes
    addCallers(_projectIndex);
    for (final index in _localIndexes.values) {
      addCallers(index);
    }
    if (_sdkIndex != null) {
      addCallers(_sdkIndex!);
    }
    for (final index in _flutterIndexes.values) {
      addCallers(index);
    }
    for (final index in _packageIndexes.values) {
      addCallers(index);
    }
    for (final index in _gitIndexes.values) {
      addCallers(index);
    }

    return callers.values.toList();
  }

  /// Get all files across all loaded indexes.
  Iterable<String> get allFiles sync* {
    yield* _projectIndex.files;
    for (final index in _externalIndexes) {
      yield* index.files;
    }
  }

  /// Get all loaded indexes (project + external).
  ///
  /// Order: project → local → SDK → hosted → git
  List<ScipIndex> get allIndexes {
    final indexes = <ScipIndex>[_projectIndex];
    indexes.addAll(_localIndexes.values);
    if (_sdkIndex != null) {
      indexes.add(_sdkIndex!);
    }
    indexes.addAll(_packageIndexes.values);
    indexes.addAll(_gitIndexes.values);
    return indexes;
  }

  /// Find symbols matching a qualified name (container.member) across indexes.
  ///
  /// Searches project → SDK → packages and returns unique results.
  Iterable<SymbolInfo> findQualified(String container, String member) {
    final seen = <String>{};
    final results = <SymbolInfo>[];

    void addAll(Iterable<SymbolInfo> symbols) {
      for (final sym in symbols) {
        if (seen.add(sym.symbol)) {
          results.add(sym);
        }
      }
    }

    addAll(_projectIndex.findQualified(container, member));

    for (final index in _externalIndexes) {
      addAll(index.findQualified(container, member));
    }

    return results;
  }

  /// Grep across all loaded indexes.
  ///
  /// Returns grep matches from project and all loaded packages.
  ///
  /// By default, searches:
  /// - Project index
  /// - All local (workspace) packages
  ///
  /// Set [includeExternal] to true to also search external dependencies
  /// (SDK, Flutter, hosted packages, git packages).
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

    // Helper to search an index and avoid duplicates
    Future<void> searchIndex(ScipIndex index) async {
      // Skip if we've already searched this path
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
      ));
    }

    // Always search project
    await searchIndex(_projectIndex);

    // Always search local (workspace) packages
    for (final index in _localIndexes.values) {
      await searchIndex(index);
    }

    if (!includeExternal) {
      return results;
    }

    // Search external indexes (SDK, Flutter, hosted, git)
    if (_sdkIndex != null) {
      await searchIndex(_sdkIndex!);
    }
    for (final index in _flutterIndexes.values) {
      await searchIndex(index);
    }
    for (final index in _packageIndexes.values) {
      await searchIndex(index);
    }
    for (final index in _gitIndexes.values) {
      await searchIndex(index);
    }

    return results;
  }

  /// Find symbols by name/pattern across indexes.
  ///
  /// [scope] controls which indexes to search:
  /// - [IndexScope.project]: Only the project index
  /// - [IndexScope.projectAndLoaded]: Project + already loaded externals
  /// - [IndexScope.all]: Project + load needed externals on demand (not implemented)
  List<SymbolInfo> findSymbols(
    String pattern, {
    IndexScope scope = IndexScope.projectAndLoaded,
  }) {
    final seen = <String>{};
    final results = <SymbolInfo>[];

    void addUnique(Iterable<SymbolInfo> symbols) {
      for (final sym in symbols) {
        if (seen.add(sym.symbol)) {
          results.add(sym);
        }
      }
    }

    // Always search project
    addUnique(_projectIndex.findSymbols(pattern));

    if (scope == IndexScope.project) {
      return results;
    }

    // Search loaded externals
    for (final index in _externalIndexes) {
      addUnique(index.findSymbols(pattern));
    }

    return results;
  }

  /// Get supertypes for a symbol, searching across indexes.
  List<SymbolInfo> supertypesOf(String symbolId) {
    // First find the symbol's definition
    final info = getSymbol(symbolId);
    if (info == null) return [];

    // Get supertypes from the defining index
    final supertypes = <SymbolInfo>[];

    // Check project
    final projectSupers = _projectIndex.supertypesOf(symbolId);
    if (projectSupers.isNotEmpty) {
      supertypes.addAll(projectSupers);
    }

    // Check external indexes
    for (final index in _externalIndexes) {
      supertypes.addAll(index.supertypesOf(symbolId));
    }

    return supertypes;
  }

  /// Get subtypes for a symbol, searching across indexes.
  List<SymbolInfo> subtypesOf(String symbolId) {
    final subtypes = <SymbolInfo>[];

    // Check project
    subtypes.addAll(_projectIndex.subtypesOf(symbolId));

    // Check external indexes
    for (final index in _externalIndexes) {
      subtypes.addAll(index.subtypesOf(symbolId));
    }

    return subtypes;
  }

  /// Get members of a class/mixin, searching across indexes.
  List<SymbolInfo> membersOf(String symbolId) {
    // Check project first (most common case)
    final projectMembers = _projectIndex.membersOf(symbolId).toList();
    if (projectMembers.isNotEmpty) return projectMembers;

    // Check external indexes
    for (final index in _externalIndexes) {
      final members = index.membersOf(symbolId).toList();
      if (members.isNotEmpty) return members;
    }

    return [];
  }

  /// Unload SDK index to free memory.
  void unloadSdk() {
    _sdkIndex = null;
    _loadedSdkVersion = null;
  }

  /// Unload a package index to free memory.
  void unloadPackage(String name, String version) {
    _packageIndexes.remove('$name-$version');
  }

  /// Load all available pre-indexed dependencies for a project.
  ///
  /// Parses pubspec.lock and loads any packages that have pre-computed indexes.
  /// Also tries to load the SDK and Flutter packages if available.
  ///
  /// Returns the number of packages loaded.
  Future<int> loadDependenciesFrom(String projectPath) async {
    var loadedCount = 0;

    // Try to load SDK (detect version from project)
    final sdkVersion = await _detectSdkVersion(projectPath);
    if (sdkVersion != null && await hasSdkIndex(sdkVersion)) {
      await loadSdk(sdkVersion);
      loadedCount++;
    }

    // Parse pubspec.lock for dependencies
    final lockfile = File('$projectPath/pubspec.lock');
    if (!await lockfile.exists()) {
      return loadedCount;
    }

    final content = await lockfile.readAsString();
    final packages = parsePubspecLock(content);

    // Load each package that has a pre-computed index
    for (final pkg in packages) {
      if (await hasPackageIndex(pkg.name, pkg.version)) {
        await loadPackage(pkg.name, pkg.version);
        loadedCount++;
      }
    }

    // Also try to load Flutter packages if the project uses Flutter
    final flutterVersion = await _detectFlutterVersion(projectPath);
    if (flutterVersion != null) {
      final flutterPackages = [
        'flutter',
        'flutter_test',
        'flutter_driver',
        'flutter_localizations',
        'flutter_web_plugins',
      ];

      for (final pkg in flutterPackages) {
        if (await hasPackageIndex(pkg, flutterVersion)) {
          await loadPackage(pkg, flutterVersion);
          loadedCount++;
        }
      }
    }

    return loadedCount;
  }

  /// Load dependencies from package_config.json.
  ///
  /// This uses the resolved package configuration instead of pubspec.lock,
  /// which provides accurate paths for all dependency types:
  /// - Hosted packages (pub.dev)
  /// - Git packages
  /// - Path dependencies (local mono repo packages)
  ///
  /// Returns a summary of what was loaded.
  Future<DependencyLoadResult> loadFromPackageConfig(String projectPath) async {
    final result = DependencyLoadResult();

    // Try to load SDK
    final sdkVersion = await _detectSdkVersion(projectPath);
    if (sdkVersion != null && await hasSdkIndex(sdkVersion)) {
      await loadSdk(sdkVersion);
      result.sdkLoaded = true;
      result.sdkVersion = sdkVersion;
    }

    // Parse package_config.json
    final packages = await parsePackageConfig(projectPath);
    if (packages.isEmpty) {
      return result;
    }

    for (final pkg in packages) {
      switch (pkg.source) {
        case DependencySource.hosted:
          if (pkg.version != null &&
              await hasPackageIndex(pkg.name, pkg.version!)) {
            await loadPackage(pkg.name, pkg.version!);
            result.hostedLoaded.add(pkg.cacheKey);
          } else {
            result.hostedMissing.add(pkg.cacheKey);
          }

        case DependencySource.git:
          if (await hasGitIndex(pkg.cacheKey)) {
            await loadGitPackage(pkg.cacheKey);
            result.gitLoaded.add(pkg.cacheKey);
          } else {
            result.gitMissing.add(pkg.cacheKey);
          }

        case DependencySource.path:
          // For path dependencies, check workspace registry
          if (await hasLocalIndex(pkg.name)) {
            await loadLocalPackage(pkg.name);
            result.localLoaded.add(pkg.name);
          } else {
            // Mark as needing on-the-fly indexing
            result.localMissing.add(pkg.name);
          }

        case DependencySource.sdk:
          // SDK packages are handled separately
          break;
      }
    }

    // Also try to load Flutter packages if the project uses Flutter
    final flutterVersion = await _detectFlutterVersion(projectPath);
    if (flutterVersion != null) {
      result.flutterVersion = flutterVersion;
      final flutterPackages = [
        'flutter',
        'flutter_test',
        'flutter_driver',
        'flutter_localizations',
        'flutter_web_plugins',
      ];

      for (final pkg in flutterPackages) {
        if (await hasPackageIndex(pkg, flutterVersion)) {
          await loadPackage(pkg, flutterVersion);
          result.flutterLoaded.add(pkg);
        }
      }
    }

    return result;
  }

  /// Detect the Dart SDK version being used by a project.
  Future<String?> _detectSdkVersion(String projectPath) async {
    // Try to get SDK version from dart command
    try {
      final result = await Process.run('dart', ['--version']);
      if (result.exitCode == 0) {
        // Parse version from output like "Dart SDK version: 3.2.0 ..."
        final output = result.stdout.toString();
        final match =
            RegExp(r'Dart SDK version: (\d+\.\d+\.\d+)').firstMatch(output);
        if (match != null) {
          return match.group(1);
        }
      }
    } catch (_) {
      // Ignore errors
    }
    return null;
  }

  /// Detect the Flutter SDK version being used by a project.
  ///
  /// Returns the Flutter version if the project uses Flutter, null otherwise.
  /// Uses proper YAML parsing to detect Flutter SDK dependencies.
  Future<String?> _detectFlutterVersion(String projectPath) async {
    // First check if this is a Flutter project by parsing pubspec.yaml
    final pubspecFile = File('$projectPath/pubspec.yaml');
    if (!await pubspecFile.exists()) {
      return null;
    }

    try {
      final pubspecContent = await pubspecFile.readAsString();
      final pubspec = loadYaml(pubspecContent) as YamlMap?;
      if (pubspec == null) return null;

      // Check dependencies for flutter SDK
      final dependencies = pubspec['dependencies'] as YamlMap?;
      if (dependencies == null) return null;

      final flutter = dependencies['flutter'];
      if (flutter == null) return null;

      // Flutter SDK dependency looks like: flutter: { sdk: flutter }
      if (flutter is YamlMap && flutter['sdk'] == 'flutter') {
        // This is a Flutter project, get the version
        return await _getFlutterVersion();
      }
    } catch (_) {
      // YAML parsing failed, not a valid pubspec
      return null;
    }

    return null;
  }

  /// Get the Flutter SDK version from the flutter command.
  Future<String?> _getFlutterVersion() async {
    try {
      final result = await Process.run('flutter', ['--version', '--machine']);
      if (result.exitCode == 0) {
        // Parse JSON output
        final output = result.stdout.toString();
        final versionMatch =
            RegExp(r'"frameworkVersion":\s*"([^"]+)"').firstMatch(output);
        if (versionMatch != null) {
          return versionMatch.group(1);
        }
      }
    } catch (_) {
      // Try without --machine flag
      try {
        final result = await Process.run('flutter', ['--version']);
        if (result.exitCode == 0) {
          // Parse version from output like "Flutter 3.x.x ..."
          final output = result.stdout.toString();
          final match = RegExp(r'Flutter\s+(\d+\.\d+\.\d+)').firstMatch(output);
          if (match != null) {
            return match.group(1);
          }
        }
      } catch (_) {
        // Ignore errors
      }
    }
    return null;
  }

  /// Unload all external indexes.
  void unloadAll() {
    _sdkIndex = null;
    _loadedSdkVersion = null;
    _packageIndexes.clear();
    _gitIndexes.clear();
    _localIndexes.clear();
  }

  /// Load manifest.json from an index directory.
  ///
  /// Returns null if manifest doesn't exist or can't be parsed.
  Future<Map<String, dynamic>?> _loadManifest(String indexDir) async {
    final manifestFile = File('$indexDir/manifest.json');
    if (!await manifestFile.exists()) {
      return null;
    }
    try {
      final content = await manifestFile.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Get combined statistics.
  Map<String, dynamic> get stats {
    final result = <String, dynamic>{
      'project': _projectIndex.stats,
      'sdkLoaded': _sdkIndex != null,
      'sdkVersion': _loadedSdkVersion,
      'flutterVersion': _loadedFlutterVersion,
      'flutterPackagesLoaded': _flutterIndexes.length,
      'flutterPackageNames': _flutterIndexes.keys.toList(),
      'hostedPackagesLoaded': _packageIndexes.length,
      'hostedPackageNames': _packageIndexes.keys.toList(),
      'gitPackagesLoaded': _gitIndexes.length,
      'gitPackageNames': _gitIndexes.keys.toList(),
      'localPackagesLoaded': _localIndexes.length,
      'localPackageNames': _localIndexes.keys.toList(),
    };

    if (_sdkIndex != null) {
      result['sdk'] = _sdkIndex!.stats;
    }

    return result;
  }
}

/// Scope for cross-index queries.
enum IndexScope {
  /// Only search the project index.
  project,

  /// Search project and already loaded external indexes.
  projectAndLoaded,
}

/// Result of loading dependencies from package_config.json.
class DependencyLoadResult {
  /// Whether SDK was loaded.
  bool sdkLoaded = false;

  /// Loaded SDK version.
  String? sdkVersion;

  /// Flutter version (if detected).
  String? flutterVersion;

  /// Loaded hosted package cache keys.
  final List<String> hostedLoaded = [];

  /// Missing hosted package cache keys (not indexed).
  final List<String> hostedMissing = [];

  /// Loaded git package cache keys.
  final List<String> gitLoaded = [];

  /// Missing git package cache keys (not indexed).
  final List<String> gitMissing = [];

  /// Loaded local package names.
  final List<String> localLoaded = [];

  /// Missing local package names (need on-the-fly indexing).
  final List<String> localMissing = [];

  /// Loaded Flutter package names.
  final List<String> flutterLoaded = [];

  /// Total number of packages loaded.
  int get totalLoaded =>
      hostedLoaded.length +
      gitLoaded.length +
      localLoaded.length +
      flutterLoaded.length +
      (sdkLoaded ? 1 : 0);

  /// Total number of packages missing.
  int get totalMissing =>
      hostedMissing.length + gitMissing.length + localMissing.length;

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
