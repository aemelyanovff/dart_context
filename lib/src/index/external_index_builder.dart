import 'dart:convert';
import 'dart:io';

import 'index_registry.dart';
import 'scip_index.dart';

/// Builds SCIP indexes for external dependencies (SDK, packages).
///
/// Pre-computes indexes that can be loaded on demand by [IndexRegistry].
///
/// ## Usage
///
/// ```dart
/// final builder = ExternalIndexBuilder(registry);
///
/// // Index the Dart SDK
/// await builder.indexSdk('/path/to/dart-sdk');
///
/// // Index a pub package
/// await builder.indexPackage('analyzer', '6.3.0', '/path/to/pub-cache/analyzer-6.3.0');
/// ```
class ExternalIndexBuilder {
  ExternalIndexBuilder({
    required IndexRegistry registry,
    this.scipDartPath = 'scip-dart',
  }) : _registry = registry;

  final IndexRegistry _registry;

  /// Path to scip-dart executable.
  final String scipDartPath;

  /// Index the Dart SDK.
  ///
  /// [sdkPath] should point to the SDK root (containing `lib/`).
  /// Returns the created index, or null on failure.
  Future<IndexResult> indexSdk(String sdkPath, {String? version}) async {
    // Detect SDK version if not provided
    final sdkVersion = version ?? await _detectSdkVersion(sdkPath);
    if (sdkVersion == null) {
      return IndexResult.failure('Could not detect SDK version');
    }

    final outputDir = _registry.sdkIndexPath(sdkVersion);
    await Directory(outputDir).create(recursive: true);

    // Run scip-dart on SDK
    final result = await _runScipDart(
      projectPath: sdkPath,
      outputPath: '$outputDir/index.scip',
    );

    if (!result.success) {
      return IndexResult.failure('scip-dart failed: ${result.error}');
    }

    // Write manifest
    await _writeManifest(
      outputDir,
      type: 'sdk',
      name: 'dart-sdk',
      version: sdkVersion,
      sourcePath: sdkPath,
    );

    // Load the index
    final index = await _registry.loadSdk(sdkVersion);
    if (index == null) {
      return IndexResult.failure('Failed to load created index');
    }

    return IndexResult.success(
      index: index,
      stats: {
        'type': 'sdk',
        'version': sdkVersion,
        'symbols': index.stats['symbols'] ?? 0,
        'files': index.stats['files'] ?? 0,
      },
    );
  }

  /// Index a pub package.
  ///
  /// [packagePath] should point to the package root in pub cache.
  Future<IndexResult> indexPackage(
    String name,
    String version,
    String packagePath,
  ) async {
    final outputDir = _registry.packageIndexPath(name, version);
    await Directory(outputDir).create(recursive: true);

    // Run scip-dart on package
    final result = await _runScipDart(
      projectPath: packagePath,
      outputPath: '$outputDir/index.scip',
    );

    if (!result.success) {
      return IndexResult.failure('scip-dart failed: ${result.error}');
    }

    // Write manifest
    await _writeManifest(
      outputDir,
      type: 'package',
      name: name,
      version: version,
      sourcePath: packagePath,
    );

    // Load the index
    final index = await _registry.loadPackage(name, version);
    if (index == null) {
      return IndexResult.failure('Failed to load created index');
    }

    return IndexResult.success(
      index: index,
      stats: {
        'type': 'package',
        'name': name,
        'version': version,
        'symbols': index.stats['symbols'] ?? 0,
        'files': index.stats['files'] ?? 0,
      },
    );
  }

  /// Index all packages from pubspec.lock.
  ///
  /// Reads the lockfile and indexes each dependency.
  /// Skips packages that are already indexed.
  Future<BatchIndexResult> indexDependencies(
    String projectPath, {
    bool forceReindex = false,
  }) async {
    final lockfile = File('$projectPath/pubspec.lock');
    if (!await lockfile.exists()) {
      return BatchIndexResult(
        success: false,
        error: 'pubspec.lock not found',
        results: [],
      );
    }

    final content = await lockfile.readAsString();
    final packages = _parsePubspecLock(content);

    final pubCachePath = await _getPubCachePath();
    if (pubCachePath == null) {
      return BatchIndexResult(
        success: false,
        error: 'Could not find pub cache',
        results: [],
      );
    }

    final results = <PackageIndexResult>[];

    for (final pkg in packages) {
      // Skip if already indexed (unless forcing)
      if (!forceReindex && await _registry.hasPackageIndex(pkg.name, pkg.version)) {
        results.add(PackageIndexResult(
          name: pkg.name,
          version: pkg.version,
          skipped: true,
          reason: 'already indexed',
        ));
        continue;
      }

      // Find package in pub cache
      final packagePath = '$pubCachePath/hosted/pub.dev/${pkg.name}-${pkg.version}';
      if (!await Directory(packagePath).exists()) {
        results.add(PackageIndexResult(
          name: pkg.name,
          version: pkg.version,
          skipped: true,
          reason: 'not found in pub cache',
        ));
        continue;
      }

      // Index it
      final result = await indexPackage(pkg.name, pkg.version, packagePath);
      results.add(PackageIndexResult(
        name: pkg.name,
        version: pkg.version,
        success: result.success,
        error: result.error,
        symbolCount: result.stats?['symbols'] as int?,
      ));
    }

    return BatchIndexResult(
      success: true,
      results: results,
    );
  }

  /// List available SDK indexes.
  Future<List<String>> listSdkIndexes() async {
    final dir = Directory('${_registry.globalCachePath}/sdk');
    if (!await dir.exists()) return [];

    return dir
        .list()
        .where((e) => e is Directory)
        .map((e) => e.path.split('/').last)
        .toList();
  }

  /// List available package indexes.
  Future<List<({String name, String version})>> listPackageIndexes() async {
    final dir = Directory('${_registry.globalCachePath}/packages');
    if (!await dir.exists()) return [];

    final results = <({String name, String version})>[];

    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final parts = entity.path.split('/').last.split('-');
        if (parts.length >= 2) {
          final version = parts.last;
          final name = parts.sublist(0, parts.length - 1).join('-');
          results.add((name: name, version: version));
        }
      }
    }

    return results;
  }

  Future<String?> _detectSdkVersion(String sdkPath) async {
    final versionFile = File('$sdkPath/version');
    if (await versionFile.exists()) {
      final content = await versionFile.readAsString();
      return content.trim();
    }
    return null;
  }

  Future<_ScipResult> _runScipDart({
    required String projectPath,
    required String outputPath,
  }) async {
    try {
      final result = await Process.run(
        scipDartPath,
        ['index', '--output', outputPath, projectPath],
      );

      if (result.exitCode != 0) {
        return _ScipResult(
          success: false,
          error: result.stderr.toString(),
        );
      }

      return _ScipResult(success: true);
    } catch (e) {
      return _ScipResult(success: false, error: e.toString());
    }
  }

  Future<void> _writeManifest(
    String outputDir, {
    required String type,
    required String name,
    required String version,
    required String sourcePath,
  }) async {
    final manifest = {
      'type': type,
      'name': name,
      'version': version,
      'sourcePath': sourcePath,
      'indexedAt': DateTime.now().toIso8601String(),
    };

    await File('$outputDir/manifest.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  List<_PackageInfo> _parsePubspecLock(String content) {
    final packages = <_PackageInfo>[];
    final lines = content.split('\n');

    String? currentPackage;
    String? currentVersion;

    for (final line in lines) {
      if (line.startsWith('  ') && line.endsWith(':') && !line.startsWith('    ')) {
        // Package name
        currentPackage = line.trim().replaceAll(':', '');
      } else if (line.contains('version:') && currentPackage != null) {
        // Package version
        currentVersion = line.split(':').last.trim().replaceAll('"', '');
        packages.add(_PackageInfo(currentPackage, currentVersion));
        currentPackage = null;
        currentVersion = null;
      }
    }

    return packages;
  }

  Future<String?> _getPubCachePath() async {
    // Check environment variable first
    final envPath = Platform.environment['PUB_CACHE'];
    if (envPath != null && await Directory(envPath).exists()) {
      return envPath;
    }

    // Default locations
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return null;

    final defaultPath = Platform.isWindows ? '$home\\AppData\\Local\\Pub\\Cache' : '$home/.pub-cache';

    if (await Directory(defaultPath).exists()) {
      return defaultPath;
    }

    return null;
  }
}

class _ScipResult {
  _ScipResult({required this.success, this.error});
  final bool success;
  final String? error;
}

class _PackageInfo {
  _PackageInfo(this.name, this.version);
  final String name;
  final String version;
}

/// Result of indexing an external source.
class IndexResult {
  IndexResult._({
    required this.success,
    this.index,
    this.error,
    this.stats,
  });

  factory IndexResult.success({
    required ScipIndex index,
    Map<String, dynamic>? stats,
  }) =>
      IndexResult._(success: true, index: index, stats: stats);

  factory IndexResult.failure(String error) => IndexResult._(success: false, error: error);

  final bool success;
  final ScipIndex? index;
  final String? error;
  final Map<String, dynamic>? stats;
}

/// Result of indexing a single package.
class PackageIndexResult {
  PackageIndexResult({
    required this.name,
    required this.version,
    this.success = false,
    this.skipped = false,
    this.reason,
    this.error,
    this.symbolCount,
  });

  final String name;
  final String version;
  final bool success;
  final bool skipped;
  final String? reason;
  final String? error;
  final int? symbolCount;
}

/// Result of batch indexing.
class BatchIndexResult {
  BatchIndexResult({
    required this.success,
    this.error,
    required this.results,
  });

  final bool success;
  final String? error;
  final List<PackageIndexResult> results;

  int get indexed => results.where((r) => r.success).length;
  int get skipped => results.where((r) => r.skipped).length;
  int get failed => results.where((r) => !r.success && !r.skipped).length;
}


