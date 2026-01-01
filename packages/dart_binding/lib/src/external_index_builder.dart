import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:scip_server/scip_server.dart';
// ignore: implementation_imports
import 'package:scip_dart/scip_dart.dart' as scip_dart;
// ignore: implementation_imports
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
// ignore: implementation_imports
import 'package:scip_dart/src/scip_visitor.dart';
// ignore: implementation_imports
import 'package:scip_dart/src/version.dart';

import 'package_registry.dart';
import 'utils/pubspec_utils.dart';

/// Builds SCIP indexes for external dependencies (SDK, packages).
///
/// Pre-computes indexes that can be loaded on demand by [PackageRegistry].
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
    required PackageRegistry registry,
  }) : _registry = registry;

  final PackageRegistry _registry;

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

    try {
      // Index using scip_dart library
      final index = await _indexDirectory(sdkPath);
      if (index == null) {
        return IndexResult.failure('Failed to index SDK');
      }

      // Save the index
      final outputPath = '$outputDir/index.scip';
      await File(outputPath).writeAsBytes(index.writeToBuffer());

      // Write manifest
      await _writeManifest(
        outputDir,
        type: 'sdk',
        name: 'dart-sdk',
        version: sdkVersion,
        sourcePath: sdkPath,
      );

      // Load the index
      final loadedIndex = await _registry.loadSdk(sdkVersion);
      if (loadedIndex == null) {
        return IndexResult.failure('Failed to load created index');
      }

      return IndexResult.success(
        index: loadedIndex,
        stats: {
          'type': 'sdk',
          'version': sdkVersion,
          'symbols': loadedIndex.stats['symbols'] ?? 0,
          'files': loadedIndex.stats['files'] ?? 0,
        },
      );
    } catch (e) {
      return IndexResult.failure('Failed to index SDK: $e');
    }
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

    try {
      // Index using scip_dart library
      final index = await _indexDirectory(packagePath);
      if (index == null) {
        return IndexResult.failure('Failed to index package');
      }

      // Save the index
      final outputPath = '$outputDir/index.scip';
      await File(outputPath).writeAsBytes(index.writeToBuffer());

      // Write manifest
      await _writeManifest(
        outputDir,
        type: 'package',
        name: name,
        version: version,
        sourcePath: packagePath,
      );

      // Load the index
      final loadedIndex = await _registry.loadHostedPackage(name, version);
      if (loadedIndex == null) {
        return IndexResult.failure('Failed to load created index');
      }

      return IndexResult.success(
        index: loadedIndex,
        stats: {
          'type': 'package',
          'name': name,
          'version': version,
          'symbols': loadedIndex.stats['symbols'] ?? 0,
          'files': loadedIndex.stats['files'] ?? 0,
        },
      );
    } catch (e) {
      return IndexResult.failure('Failed to index package: $e');
    }
  }

  /// Index a Flutter SDK package.
  ///
  /// [packagePath] should point to the package root in Flutter SDK packages/.
  /// Saves to ~/.dart_context/flutter/{version}/{packageName}/.
  Future<IndexResult> indexFlutterPackage(
    String packageName,
    String version,
    String packagePath,
  ) async {
    final outputDir = _registry.flutterIndexPath(version, packageName);
    await Directory(outputDir).create(recursive: true);

    try {
      // Index using scip_dart library
      final index = await _indexDirectory(packagePath);
      if (index == null) {
        return IndexResult.failure('Failed to index Flutter package');
      }

      // Save the index
      final outputPath = '$outputDir/index.scip';
      await File(outputPath).writeAsBytes(index.writeToBuffer());

      // Write manifest
      await _writeManifest(
        outputDir,
        type: 'flutter',
        name: packageName,
        version: version,
        sourcePath: packagePath,
      );

      // Load the index
      final loadedIndex =
          await _registry.loadFlutterPackage(version, packageName);
      if (loadedIndex == null) {
        return IndexResult.failure('Failed to load created Flutter index');
      }

      return IndexResult.success(
        index: loadedIndex,
        stats: {
          'type': 'flutter',
          'name': packageName,
          'version': version,
          'symbols': loadedIndex.stats['symbols'] ?? 0,
          'files': loadedIndex.stats['files'] ?? 0,
        },
      );
    } catch (e) {
      return IndexResult.failure('Failed to index Flutter package: $e');
    }
  }

  /// Index a directory using scip_dart library.
  ///
  /// This uses a custom implementation that correctly handles packages
  /// where the lib/ directory needs to be analyzed separately from the
  /// package root.
  Future<scip.Index?> _indexDirectory(String path) async {
    // Clear global state from previous indexing runs to prevent accumulation
    globalExternalSymbols.clear();

    // Ensure we have an absolute path
    final absPath = Directory(path).absolute.path;

    // Find pubspec first
    final pubspecFile = File('$absPath/pubspec.yaml');
    if (!await pubspecFile.exists()) {
      return null;
    }
    final pubspec = Pubspec.parse(await pubspecFile.readAsString());

    // Try to find an existing package_config.json
    var packageConfig = await findPackageConfig(Directory(absPath));

    packageConfig ??= _createSyntheticPackageConfig(absPath, pubspec.name);

    // Check if lib/ directory exists
    final libPath = '$absPath/lib';
    final hasLib = await Directory(libPath).exists();

    // Use custom indexing for packages with separate lib context
    if (hasLib) {
      return _indexPackageWithLib(absPath, libPath, packageConfig, pubspec);
    }

    // Fall back to standard scip_dart for packages without lib
    return scip_dart.indexPackage(absPath, packageConfig, pubspec);
  }

  /// Index a package, ensuring the lib/ directory is properly analyzed.
  ///
  /// The Dart analyzer may create separate contexts for subdirectories
  /// with their own analysis_options.yaml. This method ensures we get
  /// the context for the lib/ directory which contains the actual library code.
  Future<scip.Index?> _indexPackageWithLib(
    String packagePath,
    String libPath,
    PackageConfig packageConfig,
    Pubspec pubspec,
  ) async {
    final dirPath = p.normalize(p.absolute(packagePath));

    final metadata = scip.Metadata(
      projectRoot: Uri.file(dirPath).toString(),
      textDocumentEncoding: scip.TextEncoding.UTF8,
      toolInfo: scip.ToolInfo(
        name: 'scip-dart',
        version: scipDartVersion,
        arguments: [],
      ),
    );

    // Get all package roots for dependency resolution
    final allPackageRoots = packageConfig.packages
        .map((package) => p.normalize(package.packageUriRoot.toFilePath()))
        .toList();

    // Create collection with lib path explicitly included
    final collection = AnalysisContextCollection(
      includedPaths: [
        ...allPackageRoots,
        libPath, // Explicitly include lib path
        dirPath,
      ],
    );

    // Get the context for the lib path specifically
    final context = collection.contextFor(libPath);
    final resolvedUnitFutures = context.contextRoot
        .analyzedFiles()
        .where((file) => p.extension(file) == '.dart')
        .map(context.currentSession.getResolvedUnit);

    final resolvedUnits = await Future.wait(resolvedUnitFutures);

    final documents =
        resolvedUnits.whereType<ResolvedUnitResult>().map((resUnit) {
      // Make path relative to package root (not lib)
      final relativePath = p.relative(resUnit.path, from: dirPath);

      final visitor = ScipVisitor(
        relativePath,
        dirPath,
        resUnit.lineInfo,
        resUnit.errors,
        packageConfig,
        pubspec,
      );
      resUnit.unit.accept(visitor);

      return scip.Document(
        language: scip.Language.Dart.name,
        relativePath: relativePath,
        occurrences: visitor.occurrences,
        symbols: visitor.symbols,
      );
    }).toList();

    return scip.Index(
      metadata: metadata,
      documents: documents,
      externalSymbols: globalExternalSymbols,
    );
  }

  /// Create a minimal package config for indexing a single package.
  ///
  /// This is used for packages in pub cache that don't have package_config.json.
  PackageConfig _createSyntheticPackageConfig(
      String packagePath, String packageName,) {
    // Use absolute file:// URI for the package root
    final packageUri = Uri.file('$packagePath/');
    return PackageConfig([
      Package(
        packageName,
        packageUri,
        packageUriRoot: Uri.file('$packagePath/lib/'),
        languageVersion: LanguageVersion(3, 0), // Use a reasonable default
      ),
    ]);
  }

  /// Index all packages from pubspec.lock.
  ///
  /// Reads the lockfile and indexes each dependency.
  /// Skips packages that are already indexed.
  Future<BatchIndexResult> indexDependencies(
    String projectPath, {
    bool forceReindex = false,
    void Function(String message)? onProgress,
    int concurrency = 4,
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
    final packages = parsePubspecLock(content);
    onProgress?.call('Found ${packages.length} dependencies to index');

    final pubCachePath = await _getPubCachePath();
    if (pubCachePath == null) {
      return BatchIndexResult(
        success: false,
        error: 'Could not find pub cache',
        results: [],
      );
    }

    // Categorize packages: to index vs skip
    final toIndex = <({String name, String version, String path})>[];
    final skippedResults = <PackageIndexResult>[];

    for (final pkg in packages) {
      // Skip if already indexed (unless forcing)
      if (!forceReindex &&
          await _registry.hasHostedIndex(pkg.name, pkg.version)) {
        skippedResults.add(PackageIndexResult(
          name: pkg.name,
          version: pkg.version,
          skipped: true,
          reason: 'already indexed',
        ),);
        continue;
      }

      // Find package in pub cache
      final packagePath =
          '$pubCachePath/hosted/pub.dev/${pkg.name}-${pkg.version}';
      if (!await Directory(packagePath).exists()) {
        skippedResults.add(PackageIndexResult(
          name: pkg.name,
          version: pkg.version,
          skipped: true,
          reason: 'not found in pub cache',
        ),);
        continue;
      }

      toIndex.add((name: pkg.name, version: pkg.version, path: packagePath));
    }

    onProgress?.call(
        'Indexing ${toIndex.length} packages (${skippedResults.length} skipped)...',);

    // Process packages in parallel with concurrency limit
    final indexedResults = <PackageIndexResult>[];
    var indexed = 0;

    // Process in batches for controlled concurrency
    for (var i = 0; i < toIndex.length; i += concurrency) {
      final batch = toIndex.skip(i).take(concurrency).toList();

      final batchFutures = batch.map((pkg) async {
        final result = await indexPackage(pkg.name, pkg.version, pkg.path);
        return PackageIndexResult(
          name: pkg.name,
          version: pkg.version,
          success: result.success,
          error: result.error,
          symbolCount: result.stats?['symbols'] as int?,
        );
      });

      final batchResults = await Future.wait(batchFutures);
      indexedResults.addAll(batchResults);

      // Report progress for successful packages
      for (final result in batchResults) {
        if (result.success) {
          indexed++;
          onProgress
              ?.call('Indexed ${result.name}: ${result.symbolCount} symbols');
        }
      }
    }

    onProgress
        ?.call('Completed: $indexed indexed, ${skippedResults.length} skipped');

    return BatchIndexResult(
      success: true,
      results: [...skippedResults, ...indexedResults],
    );
  }

  /// Index Flutter framework packages.
  ///
  /// This indexes the main Flutter packages (flutter, flutter_test, etc.)
  /// to enable queries like `hierarchy StatelessWidget`.
  ///
  /// [flutterPath] should point to the Flutter SDK root.
  /// If not provided, uses FLUTTER_ROOT environment variable or tries to find from PATH.
  ///
  /// [onProgress] callback is invoked with status messages during indexing.
  Future<FlutterIndexResult> indexFlutterPackages({
    String? flutterPath,
    void Function(String message)? onProgress,
  }) async {
    // Resolve Flutter path
    final resolvedPath = await _resolveFlutterPath(flutterPath);
    if (resolvedPath == null) {
      return FlutterIndexResult(
        success: false,
        error: 'Flutter SDK not found. Provide path or set FLUTTER_ROOT.',
      );
    }

    final packagesPath = '$resolvedPath/packages';
    if (!await Directory(packagesPath).exists()) {
      return FlutterIndexResult(
        success: false,
        error: 'Flutter packages not found at $packagesPath',
      );
    }

    // Get Flutter version
    final versionFile = File('$resolvedPath/version');
    final version = await versionFile.exists()
        ? (await versionFile.readAsString()).trim()
        : 'unknown';

    onProgress?.call('Indexing Flutter $version packages from $resolvedPath');

    // List of Flutter packages to index
    const flutterPackages = [
      'flutter',
      'flutter_test',
      'flutter_driver',
      'flutter_localizations',
      'flutter_web_plugins',
    ];

    final results = <PackageIndexResult>[];

    for (final pkgName in flutterPackages) {
      final pkgPath = '$packagesPath/$pkgName';
      if (!await Directory(pkgPath).exists()) {
        onProgress?.call('Skipping $pkgName (not found)');
        results.add(PackageIndexResult(
          name: pkgName,
          version: version,
          skipped: true,
          reason: 'not found',
        ),);
        continue;
      }

      // Check if package_config.json exists, run flutter pub get if not
      final pkgConfigFile = File('$pkgPath/.dart_tool/package_config.json');
      if (!await pkgConfigFile.exists()) {
        onProgress?.call('Running flutter pub get in $pkgName...');
        final result = await Process.run(
          'flutter',
          ['pub', 'get'],
          workingDirectory: pkgPath,
        );
        if (result.exitCode != 0) {
          onProgress?.call('Failed to get dependencies for $pkgName');
          results.add(PackageIndexResult(
            name: pkgName,
            version: version,
            error: 'pub get failed',
          ),);
          continue;
        }
      }

      onProgress?.call('Indexing $pkgName...');
      final result = await indexFlutterPackage(pkgName, version, pkgPath);

      if (result.success) {
        onProgress?.call('$pkgName: ${result.stats?['symbols']} symbols');
        results.add(PackageIndexResult(
          name: pkgName,
          version: version,
          success: true,
          symbolCount: result.stats?['symbols'] as int?,
        ),);
      } else {
        onProgress?.call('$pkgName: failed - ${result.error}');
        results.add(PackageIndexResult(
          name: pkgName,
          version: version,
          error: result.error,
        ),);
      }
    }

    return FlutterIndexResult(
      success: results.any((r) => r.success),
      flutterPath: resolvedPath,
      version: version,
      results: results,
    );
  }

  /// Resolve Flutter path from argument, env var, or PATH.
  Future<String?> _resolveFlutterPath(String? providedPath) async {
    if (providedPath != null && await Directory(providedPath).exists()) {
      return providedPath;
    }

    // Try FLUTTER_ROOT env var
    final envPath = Platform.environment['FLUTTER_ROOT'];
    if (envPath != null && await Directory(envPath).exists()) {
      return envPath;
    }

    // Try to find Flutter from the flutter command
    try {
      final result = await Process.run('which', ['flutter']);
      if (result.exitCode == 0) {
        final flutterBin = result.stdout.toString().trim();
        // Flutter binary is at FLUTTER_ROOT/bin/flutter
        final path = Directory(flutterBin).parent.parent.path;
        if (await Directory(path).exists()) {
          return path;
        }
      }
    } catch (_) {}

    return null;
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

  /// List available package indexes (hosted packages).
  Future<List<({String name, String version})>> listPackageIndexes() async {
    final dir = Directory('${_registry.globalCachePath}/hosted');
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

  Future<String?> _getPubCachePath() async {
    // Check environment variable first
    final envPath = Platform.environment['PUB_CACHE'];
    if (envPath != null && await Directory(envPath).exists()) {
      return envPath;
    }

    // Default locations
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return null;

    final defaultPath = Platform.isWindows
        ? '$home\\AppData\\Local\\Pub\\Cache'
        : '$home/.pub-cache';

    if (await Directory(defaultPath).exists()) {
      return defaultPath;
    }

    return null;
  }
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

  factory IndexResult.failure(String error) =>
      IndexResult._(success: false, error: error);

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

/// Result of indexing Flutter packages.
class FlutterIndexResult {
  FlutterIndexResult({
    required this.success,
    this.error,
    this.flutterPath,
    this.version,
    this.results = const [],
  });

  final bool success;
  final String? error;
  final String? flutterPath;
  final String? version;
  final List<PackageIndexResult> results;

  int get indexed => results.where((r) => r.success).length;
  int get skipped => results.where((r) => r.skipped).length;
  int get failed => results.where((r) => !r.success && !r.skipped).length;

  /// Total symbols indexed across all packages.
  int get totalSymbols =>
      results.fold(0, (sum, r) => sum + (r.symbolCount ?? 0));
}
