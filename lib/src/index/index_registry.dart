import 'dart:io';

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
  })  : _projectIndex = projectIndex,
        _globalCachePath = globalCachePath ?? _defaultGlobalCachePath;

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
  })  : _projectIndex = projectIndex,
        _globalCachePath = globalCachePath ?? _defaultGlobalCachePath,
        _sdkIndex = sdkIndex,
        _loadedSdkVersion = sdkVersion {
    if (packageIndexes != null) {
      _packageIndexes.addAll(packageIndexes);
    }
  }

  final ScipIndex _projectIndex;
  final String _globalCachePath;
  final Map<String, ScipIndex> _packageIndexes = {};
  ScipIndex? _sdkIndex;
  String? _loadedSdkVersion;

  static String get _defaultGlobalCachePath {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.dart_context';
  }

  /// The main project index.
  ScipIndex get projectIndex => _projectIndex;

  /// Currently loaded SDK index (if any).
  ScipIndex? get sdkIndex => _sdkIndex;

  /// Currently loaded SDK version.
  String? get loadedSdkVersion => _loadedSdkVersion;

  /// All loaded package indexes.
  Map<String, ScipIndex> get packageIndexes =>
      Map.unmodifiable(_packageIndexes);

  /// Path to global cache directory.
  String get globalCachePath => _globalCachePath;

  /// Path to SDK index directory.
  String sdkIndexPath(String version) => '$_globalCachePath/sdk/$version';

  /// Path to package index directory.
  String packageIndexPath(String name, String version) =>
      '$_globalCachePath/packages/$name-$version';

  /// Load SDK index from cache.
  ///
  /// Returns the loaded index, or null if not found in cache.
  /// Use [ExternalIndexBuilder] to create the index first.
  Future<ScipIndex?> loadSdk(String version) async {
    if (_loadedSdkVersion == version && _sdkIndex != null) {
      return _sdkIndex;
    }

    final indexPath = '${sdkIndexPath(version)}/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) {
      return null;
    }

    _sdkIndex = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: sdkIndexPath(version),
    );
    _loadedSdkVersion = version;
    return _sdkIndex;
  }

  /// Load package index from cache.
  ///
  /// Returns the loaded index, or null if not found in cache.
  /// Use [ExternalIndexBuilder] to create the index first.
  Future<ScipIndex?> loadPackage(String name, String version) async {
    final key = '$name-$version';

    if (_packageIndexes.containsKey(key)) {
      return _packageIndexes[key];
    }

    final indexPath = '${packageIndexPath(name, version)}/index.scip';
    final file = File(indexPath);

    if (!await file.exists()) {
      return null;
    }

    final index = await ScipIndex.loadFromFile(
      indexPath,
      projectRoot: packageIndexPath(name, version),
    );
    _packageIndexes[key] = index;
    return index;
  }

  /// Check if SDK index is available in cache.
  Future<bool> hasSdkIndex(String version) async {
    final file = File('${sdkIndexPath(version)}/index.scip');
    return file.exists();
  }

  /// Check if package index is available in cache.
  Future<bool> hasPackageIndex(String name, String version) async {
    final file = File('${packageIndexPath(name, version)}/index.scip');
    return file.exists();
  }

  /// Find symbol by exact ID across all loaded indexes.
  ///
  /// Searches in order: project → SDK → packages
  SymbolInfo? getSymbol(String symbolId) {
    // Check project first
    final projectSymbol = _projectIndex.getSymbol(symbolId);
    if (projectSymbol != null) return projectSymbol;

    // Check SDK
    if (_sdkIndex != null) {
      final sdkSymbol = _sdkIndex!.getSymbol(symbolId);
      if (sdkSymbol != null) return sdkSymbol;
    }

    // Check packages
    for (final index in _packageIndexes.values) {
      final pkgSymbol = index.getSymbol(symbolId);
      if (pkgSymbol != null) return pkgSymbol;
    }

    return null;
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
    final results = <SymbolInfo>[];

    // Always search project
    results.addAll(_projectIndex.findSymbols(pattern));

    if (scope == IndexScope.project) {
      return results;
    }

    // Search loaded externals
    if (_sdkIndex != null) {
      results.addAll(_sdkIndex!.findSymbols(pattern));
    }

    for (final index in _packageIndexes.values) {
      results.addAll(index.findSymbols(pattern));
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

    // Check SDK
    if (_sdkIndex != null) {
      final sdkSupers = _sdkIndex!.supertypesOf(symbolId);
      supertypes.addAll(sdkSupers);
    }

    // Check packages
    for (final index in _packageIndexes.values) {
      final pkgSupers = index.supertypesOf(symbolId);
      supertypes.addAll(pkgSupers);
    }

    return supertypes;
  }

  /// Get subtypes for a symbol, searching across indexes.
  List<SymbolInfo> subtypesOf(String symbolId) {
    final subtypes = <SymbolInfo>[];

    // Check project
    subtypes.addAll(_projectIndex.subtypesOf(symbolId));

    // Check SDK
    if (_sdkIndex != null) {
      subtypes.addAll(_sdkIndex!.subtypesOf(symbolId));
    }

    // Check packages
    for (final index in _packageIndexes.values) {
      subtypes.addAll(index.subtypesOf(symbolId));
    }

    return subtypes;
  }

  /// Get members of a class/mixin, searching across indexes.
  List<SymbolInfo> membersOf(String symbolId) {
    // Check project first (most common case)
    final projectMembers = _projectIndex.membersOf(symbolId).toList();
    if (projectMembers.isNotEmpty) return projectMembers;

    // Check SDK
    if (_sdkIndex != null) {
      final sdkMembers = _sdkIndex!.membersOf(symbolId).toList();
      if (sdkMembers.isNotEmpty) return sdkMembers;
    }

    // Check packages
    for (final index in _packageIndexes.values) {
      final pkgMembers = index.membersOf(symbolId).toList();
      if (pkgMembers.isNotEmpty) return pkgMembers;
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
  /// Also tries to load the SDK if available.
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
    final packages = _parsePubspecLock(content);

    // Load each package that has a pre-computed index
    for (final pkg in packages) {
      if (await hasPackageIndex(pkg.name, pkg.version)) {
        await loadPackage(pkg.name, pkg.version);
        loadedCount++;
      }
    }

    return loadedCount;
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

  /// Parse pubspec.lock to extract package versions.
  List<_PackageInfo> _parsePubspecLock(String content) {
    final packages = <_PackageInfo>[];
    final lines = content.split('\n');

    String? currentPackage;

    for (final line in lines) {
      if (line.startsWith('  ') &&
          line.endsWith(':') &&
          !line.startsWith('    ')) {
        // Package name
        currentPackage = line.trim().replaceAll(':', '');
      } else if (line.contains('version:') && currentPackage != null) {
        // Package version
        final version = line.split(':').last.trim().replaceAll('"', '');
        packages.add(_PackageInfo(currentPackage, version));
        currentPackage = null;
      }
    }

    return packages;
  }

  /// Unload all external indexes.
  void unloadAll() {
    _sdkIndex = null;
    _loadedSdkVersion = null;
    _packageIndexes.clear();
  }

  /// Get combined statistics.
  Map<String, dynamic> get stats {
    final result = <String, dynamic>{
      'project': _projectIndex.stats,
      'sdkLoaded': _sdkIndex != null,
      'sdkVersion': _loadedSdkVersion,
      'packagesLoaded': _packageIndexes.length,
      'packageNames': _packageIndexes.keys.toList(),
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

  /// Search all available indexes (may trigger loading).
  /// Note: This requires knowing which packages to load.
  // all, // TODO: Implement with dependency resolution
}

/// Internal class for package info from pubspec.lock.
class _PackageInfo {
  _PackageInfo(this.name, this.version);
  final String name;
  final String version;
}
