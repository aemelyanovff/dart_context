import 'dart:convert';
import 'dart:io';

import '../cache/cache_paths.dart';

/// Source type of a dependency.
enum DependencySource {
  /// Package from pub.dev (hosted).
  hosted,

  /// Package from a git repository.
  git,

  /// Local path dependency (mono repo package).
  path,

  /// SDK package (dart:* or flutter).
  sdk,
}

/// A resolved package from package_config.json.
class ResolvedPackage {
  const ResolvedPackage({
    required this.name,
    required this.absolutePath,
    required this.source,
    this.version,
    this.gitUrl,
    this.gitCommit,
    this.relativePath,
  });

  /// Package name.
  final String name;

  /// Absolute path to the package root.
  final String absolutePath;

  /// Source type of the dependency.
  final DependencySource source;

  /// Version string (for hosted packages).
  final String? version;

  /// Git repository URL (for git packages).
  final String? gitUrl;

  /// Git commit hash (for git packages).
  final String? gitCommit;

  /// Relative path from project root (for path dependencies).
  final String? relativePath;

  /// Get the cache key for this package.
  ///
  /// Used to look up pre-computed indexes in the global cache.
  String get cacheKey {
    switch (source) {
      case DependencySource.hosted:
        return '$name-$version';
      case DependencySource.git:
        if (gitCommit != null) {
          final repoName = _extractRepoName(gitUrl ?? name);
          return CachePaths.gitCacheKey(repoName, gitCommit!);
        }
        return name;
      case DependencySource.path:
        return name;
      case DependencySource.sdk:
        return name;
    }
  }

  /// Extract repo name from git URL.
  static String _extractRepoName(String gitUrl) {
    // Handle various git URL formats:
    // https://github.com/user/repo.git
    // git@github.com:user/repo.git
    // https://github.com/user/repo
    final uri = Uri.tryParse(gitUrl);
    if (uri != null) {
      final path = uri.path;
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) {
        var repoName = segments.last;
        if (repoName.endsWith('.git')) {
          repoName = repoName.substring(0, repoName.length - 4);
        }
        return repoName;
      }
    }
    return gitUrl;
  }

  @override
  String toString() => 'ResolvedPackage($name, $source, $cacheKey)';
}

/// Parse package_config.json to extract all resolved packages.
///
/// This is the source of truth for all dependencies after `pub get` runs.
/// It contains absolute paths for all packages regardless of source type.
Future<List<ResolvedPackage>> parsePackageConfig(String projectPath) async {
  final configFile = File('$projectPath/.dart_tool/package_config.json');
  if (!await configFile.exists()) {
    return [];
  }

  final content = await configFile.readAsString();
  final json = jsonDecode(content) as Map<String, dynamic>;
  final packages = json['packages'] as List<dynamic>? ?? [];

  final result = <ResolvedPackage>[];

  for (final pkg in packages) {
    final pkgMap = pkg as Map<String, dynamic>;
    final name = pkgMap['name'] as String;
    final rootUri = pkgMap['rootUri'] as String;

    final resolved = _resolvePackage(name, rootUri, projectPath);
    if (resolved != null) {
      result.add(resolved);
    }
  }

  return result;
}

/// Parse package_config.json synchronously.
List<ResolvedPackage> parsePackageConfigSync(String projectPath) {
  final configFile = File('$projectPath/.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    return [];
  }

  final content = configFile.readAsStringSync();
  final json = jsonDecode(content) as Map<String, dynamic>;
  final packages = json['packages'] as List<dynamic>? ?? [];

  final result = <ResolvedPackage>[];

  for (final pkg in packages) {
    final pkgMap = pkg as Map<String, dynamic>;
    final name = pkgMap['name'] as String;
    final rootUri = pkgMap['rootUri'] as String;

    final resolved = _resolvePackage(name, rootUri, projectPath);
    if (resolved != null) {
      result.add(resolved);
    }
  }

  return result;
}

/// Resolve a package entry from package_config.json.
ResolvedPackage? _resolvePackage(
    String name, String rootUri, String projectPath,) {
  // Absolute file URI (hosted or git from pub-cache)
  if (rootUri.startsWith('file://')) {
    final uri = Uri.parse(rootUri);
    final absolutePath = uri.toFilePath();

    // Determine source type from path
    if (absolutePath.contains('.pub-cache/hosted/')) {
      // Hosted package: extract version from path
      // e.g., /.../.pub-cache/hosted/pub.dev/collection-1.18.0
      final version = _extractVersionFromPath(absolutePath);
      return ResolvedPackage(
        name: name,
        absolutePath: absolutePath,
        source: DependencySource.hosted,
        version: version,
      );
    } else if (absolutePath.contains('.pub-cache/git/')) {
      // Git package: extract commit from path
      // e.g., /.../.pub-cache/git/fluxon-bfef6c5e.../
      final gitInfo = _extractGitInfoFromPath(absolutePath);
      return ResolvedPackage(
        name: name,
        absolutePath: absolutePath,
        source: DependencySource.git,
        gitCommit: gitInfo?.commit,
        gitUrl: gitInfo?.repoName,
      );
    } else if (absolutePath.contains('/flutter/') &&
        absolutePath.contains('/packages/')) {
      // Flutter SDK package
      return ResolvedPackage(
        name: name,
        absolutePath: absolutePath,
        source: DependencySource.sdk,
      );
    } else if (absolutePath.contains('/lib/_internal/') ||
        absolutePath.contains('/sdk/')) {
      // Dart SDK package
      return ResolvedPackage(
        name: name,
        absolutePath: absolutePath,
        source: DependencySource.sdk,
      );
    }

    // Unknown absolute path - treat as hosted
    return ResolvedPackage(
      name: name,
      absolutePath: absolutePath,
      source: DependencySource.hosted,
    );
  }

  // Relative path (local package in mono repo)
  if (!rootUri.startsWith('file://')) {
    // Relative path like "../packages/hologram_core"
    final configDir = '$projectPath/.dart_tool';
    final absolutePath = _resolveRelativePath(configDir, rootUri);

    return ResolvedPackage(
      name: name,
      absolutePath: absolutePath,
      source: DependencySource.path,
      relativePath: rootUri,
    );
  }

  return null;
}

/// Extract version from a hosted package path.
///
/// Input: `/.../.pub-cache/hosted/pub.dev/collection-1.18.0`
/// Output: `1.18.0`
String? _extractVersionFromPath(String path) {
  // The directory name is `<package>-<version>`
  final dirName = path.split('/').last;
  final lastHyphen = dirName.lastIndexOf('-');
  if (lastHyphen > 0) {
    return dirName.substring(lastHyphen + 1);
  }
  return null;
}

/// Extract git info from a git package path.
///
/// Input: `/.../.pub-cache/git/fluxon-bfef6c5e6909d853f20880bbc5272a826738fa58`
/// Output: `GitInfo(repoName: 'fluxon', commit: 'bfef6c5e...')`
_GitInfo? _extractGitInfoFromPath(String path) {
  // The directory name is `<repo>-<40-char-commit>`
  final dirName = path.split('/').last;
  final parsed = CachePaths.parseGitKey(dirName);
  if (parsed != null) {
    return _GitInfo(repoName: parsed.repoName, commit: parsed.commit);
  }
  return null;
}

class _GitInfo {
  const _GitInfo({required this.repoName, required this.commit});
  final String repoName;
  final String commit;
}

/// Resolve a relative path from the package_config.json location.
String _resolveRelativePath(String configDir, String relativePath) {
  // Handle both "../foo" and "file://../foo" formats
  var path = relativePath;
  if (path.startsWith('file://')) {
    path = Uri.parse(path).toFilePath();
  }

  // Resolve relative to the .dart_tool directory
  final resolved = Directory('$configDir/$path').absolute.path;

  // Normalize the path (remove trailing slashes, etc.)
  return resolved.endsWith('/') ? resolved.substring(0, resolved.length - 1) : resolved;
}

/// Filter packages by source type.
extension ResolvedPackageList on List<ResolvedPackage> {
  /// Get all hosted packages.
  List<ResolvedPackage> get hosted =>
      where((p) => p.source == DependencySource.hosted).toList();

  /// Get all git packages.
  List<ResolvedPackage> get git =>
      where((p) => p.source == DependencySource.git).toList();

  /// Get all path (local) packages.
  List<ResolvedPackage> get path =>
      where((p) => p.source == DependencySource.path).toList();

  /// Get all SDK packages.
  List<ResolvedPackage> get sdk =>
      where((p) => p.source == DependencySource.sdk).toList();
}

