import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Core Types
// ─────────────────────────────────────────────────────────────────────────────

/// A discovered local package.
class LocalPackage {
  const LocalPackage({
    required this.name,
    required this.path,
    required this.relativePath,
  });

  /// Package name from pubspec.yaml.
  final String name;

  /// Absolute path to package root.
  final String path;

  /// Path relative to the discovery root.
  final String relativePath;

  @override
  String toString() => 'LocalPackage($name, $relativePath)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalPackage &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          path == other.path;

  @override
  int get hashCode => name.hashCode ^ path.hashCode;
}

/// Result of package discovery.
class DiscoveryResult {
  const DiscoveryResult({
    required this.rootPath,
    required this.packages,
  });

  /// The root path where discovery started.
  final String rootPath;

  /// All discovered packages.
  final List<LocalPackage> packages;

  /// Check if a file path belongs to any package.
  ///
  /// Returns the most specific (deepest) package that contains the path.
  LocalPackage? findPackageForPath(String filePath) {
    // Normalize path for comparison
    final normalizedPath = _normalizePath(filePath);

    LocalPackage? bestMatch;
    var bestMatchLength = 0;

    for (final pkg in packages) {
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

  @override
  String toString() =>
      'DiscoveryResult(root: $rootPath, packages: ${packages.length})';
}

String _normalizePath(String path) {
  // Ensure consistent trailing separator handling
  final normalized = Directory(path).absolute.path;
  return normalized.endsWith(Platform.pathSeparator)
      ? normalized
      : '$normalized${Platform.pathSeparator}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Ignore Patterns
// ─────────────────────────────────────────────────────────────────────────────

/// Directory segments that should always be excluded from package discovery.
/// These are build artifacts, symlinks, cached dependencies, and version control.
const ignoredSegments = <String>{
  // Flutter/Dart build artifacts
  '.symlinks',
  '.plugin_symlinks',
  'ephemeral',
  'build',
  '.dart_tool',

  // Caches
  '.pub-cache',
  '.pub',
  'node_modules',

  // Version control
  '.git',

  // IDE
  '.idea',
  '.vscode',

  // Our own cache
  '.dart_context',
};

/// Check if a path should be ignored based on segment matching.
///
/// This is more robust than substring matching - it checks actual
/// path segments to avoid false positives like "build_utils".
bool shouldIgnorePath(String path, String rootPath) {
  // Get relative path from root
  String relativePath;
  if (path.startsWith(rootPath)) {
    relativePath = path.substring(rootPath.length);
    // Remove leading separator
    if (relativePath.startsWith(Platform.pathSeparator)) {
      relativePath = relativePath.substring(1);
    }
  } else {
    relativePath = path;
  }

  // Split into segments and check each
  final segments = relativePath.split(Platform.pathSeparator);
  return segments.any((segment) => ignoredSegments.contains(segment));
}

// ─────────────────────────────────────────────────────────────────────────────
// Package Discovery
// ─────────────────────────────────────────────────────────────────────────────

/// Package discovery service for Dart projects.
///
/// Provides methods to find all Dart packages in a directory tree.
///
/// Example:
/// ```dart
/// final discovery = PackageDiscovery();
/// final result = await discovery.discoverPackages('/path/to/project');
/// ```
class PackageDiscovery {
  /// Discover all packages in a directory.
  Future<DiscoveryResult> discoverPackages(String rootPath) {
    return _discoverPackages(rootPath);
  }

  /// Synchronous version of [discoverPackages].
  DiscoveryResult discoverPackagesSync(String rootPath) {
    return _discoverPackagesSync(rootPath);
  }
}

/// Recursively discover all Dart packages under a root directory.
///
/// This is the primary entry point for package discovery. It:
/// - Recursively scans for pubspec.yaml files
/// - Filters out ignored directories (build, .symlinks, etc.)
/// - Returns all valid packages sorted by path
///
/// Works for any folder structure:
/// - Melos mono repos
/// - Dart pub workspaces
/// - Random folders with multiple packages
/// - Single package projects
///
/// Example:
/// ```dart
/// final result = await discoverPackages('/path/to/workspace');
/// for (final pkg in result.packages) {
///   print('Found: ${pkg.name} at ${pkg.relativePath}');
/// }
/// ```
Future<DiscoveryResult> _discoverPackages(String rootPath) async {
  final absoluteRoot = Directory(rootPath).absolute.path;
  final packages = <LocalPackage>[];
  final seenPaths = <String>{};

  await for (final entity in Directory(absoluteRoot).list(recursive: true)) {
    // Only interested in files
    if (entity is! File) continue;

    // Only interested in pubspec.yaml
    if (!entity.path.endsWith('pubspec.yaml')) continue;

    // Get the package directory (parent of pubspec.yaml)
    final packageDir = entity.parent.path;

    // Skip if we've already seen this package
    if (seenPaths.contains(packageDir)) continue;

    // Skip ignored directories
    if (shouldIgnorePath(packageDir, absoluteRoot)) continue;

    // Read package name from pubspec
    final name = await _readPackageName(entity);
    if (name == null) continue;

    // Calculate relative path
    final relativePath = _getRelativePath(packageDir, absoluteRoot);

    seenPaths.add(packageDir);
    packages.add(LocalPackage(
      name: name,
      path: packageDir,
      relativePath: relativePath,
    ),);
  }

  // Sort by relative path for consistent ordering
  packages.sort((a, b) => a.relativePath.compareTo(b.relativePath));

  return DiscoveryResult(
    rootPath: absoluteRoot,
    packages: packages,
  );
}

/// Synchronous version of [_discoverPackages].
DiscoveryResult _discoverPackagesSync(String rootPath) {
  final absoluteRoot = Directory(rootPath).absolute.path;
  final packages = <LocalPackage>[];
  final seenPaths = <String>{};

  for (final entity in Directory(absoluteRoot).listSync(recursive: true)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('pubspec.yaml')) continue;

    final packageDir = entity.parent.path;

    if (seenPaths.contains(packageDir)) continue;
    if (shouldIgnorePath(packageDir, absoluteRoot)) continue;

    final name = _readPackageNameSync(File(entity.path));
    if (name == null) continue;

    final relativePath = _getRelativePath(packageDir, absoluteRoot);

    seenPaths.add(packageDir);
    packages.add(LocalPackage(
      name: name,
      path: packageDir,
      relativePath: relativePath,
    ),);
  }

  packages.sort((a, b) => a.relativePath.compareTo(b.relativePath));

  return DiscoveryResult(
    rootPath: absoluteRoot,
    packages: packages,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Read the package name from a pubspec.yaml file.
Future<String?> _readPackageName(File pubspecFile) async {
  try {
    final content = await pubspecFile.readAsString();
    final yaml = loadYaml(content) as YamlMap?;
    return yaml?['name'] as String?;
  } catch (_) {
    return null;
  }
}

/// Synchronous version of [_readPackageName].
String? _readPackageNameSync(File pubspecFile) {
  try {
    final content = pubspecFile.readAsStringSync();
    final yaml = loadYaml(content) as YamlMap?;
    return yaml?['name'] as String?;
  } catch (_) {
    return null;
  }
}

/// Get the relative path from root to target.
String _getRelativePath(String targetPath, String rootPath) {
  if (targetPath == rootPath) {
    return '.';
  }

  if (targetPath.startsWith(rootPath)) {
    var relative = targetPath.substring(rootPath.length);
    // Remove leading separator
    if (relative.startsWith(Platform.pathSeparator)) {
      relative = relative.substring(1);
    }
    return relative.isEmpty ? '.' : relative;
  }

  return targetPath;
}

// ─────────────────────────────────────────────────────────────────────────────
// Serialization
// ─────────────────────────────────────────────────────────────────────────────

/// Serialize discovery result to JSON.
Map<String, dynamic> discoveryResultToJson(DiscoveryResult result) {
  return {
    'rootPath': result.rootPath,
    'packages': result.packages
        .map((p) => {
              'name': p.name,
              'path': p.path,
              'relativePath': p.relativePath,
            },)
        .toList(),
  };
}

/// Serialize discovery result to JSON string.
String discoveryResultToJsonString(DiscoveryResult result) {
  return const JsonEncoder.withIndent('  ')
      .convert(discoveryResultToJson(result));
}

