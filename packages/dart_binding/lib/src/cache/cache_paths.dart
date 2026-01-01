import 'dart:io';

/// Centralized cache path management for dart_context.
///
/// Mirrors the structure of ~/.pub-cache for familiarity:
/// ```
/// ~/.dart_context/
/// ├── sdk/3.5.0/index.scip           # Dart SDK indexes
/// ├── flutter/3.32.0/flutter/...     # Flutter SDK packages
/// ├── hosted/collection-1.18.0/...   # Pub.dev packages
/// └── git/fluxon-bfef6c5e/...        # Git dependencies
/// ```
class CachePaths {
  /// Get the global cache directory.
  ///
  /// Can be overridden via DART_CONTEXT_CACHE environment variable.
  static String get globalCacheDir {
    final envOverride = Platform.environment['DART_CONTEXT_CACHE'];
    if (envOverride != null && envOverride.isNotEmpty) {
      return envOverride;
    }

    // Default to ~/.dart_context
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.dart_context';
  }

  /// Path to SDK index directory.
  ///
  /// Example: `~/.dart_context/sdk/3.5.0/`
  static String sdkDir(String version) => '$globalCacheDir/sdk/$version';

  /// Path to SDK index file.
  static String sdkIndex(String version) => '${sdkDir(version)}/index.scip';

  /// Path to SDK manifest file.
  static String sdkManifest(String version) =>
      '${sdkDir(version)}/manifest.json';

  /// Path to Flutter package index directory.
  ///
  /// Example: `~/.dart_context/flutter/3.32.0/flutter/`
  static String flutterDir(String version, String packageName) =>
      '$globalCacheDir/flutter/$version/$packageName';

  /// Path to Flutter package index file.
  static String flutterIndex(String version, String packageName) =>
      '${flutterDir(version, packageName)}/index.scip';

  /// Path to Flutter package manifest file.
  static String flutterManifest(String version, String packageName) =>
      '${flutterDir(version, packageName)}/manifest.json';

  /// Path to hosted (pub.dev) package index directory.
  ///
  /// Example: `~/.dart_context/hosted/collection-1.18.0/`
  static String hostedDir(String name, String version) =>
      '$globalCacheDir/hosted/$name-$version';

  /// Path to hosted package index file.
  static String hostedIndex(String name, String version) =>
      '${hostedDir(name, version)}/index.scip';

  /// Path to hosted package manifest file.
  static String hostedManifest(String name, String version) =>
      '${hostedDir(name, version)}/manifest.json';

  /// Path to git package index directory.
  ///
  /// The [repoCommitKey] should be in format `<repo-name>-<short-commit>`.
  /// Example: `~/.dart_context/git/fluxon-bfef6c5e/`
  static String gitDir(String repoCommitKey) =>
      '$globalCacheDir/git/$repoCommitKey';

  /// Path to git package index file.
  static String gitIndex(String repoCommitKey) =>
      '${gitDir(repoCommitKey)}/index.scip';

  /// Path to git package manifest file.
  static String gitManifest(String repoCommitKey) =>
      '${gitDir(repoCommitKey)}/manifest.json';

  /// Path to workspace registry directory.
  ///
  /// Example: `/path/to/monorepo/.dart_context/`
  static String workspaceDir(String workspaceRoot) =>
      '$workspaceRoot/.dart_context';

  /// Path to workspace metadata file.
  ///
  /// Example: `/path/to/monorepo/.dart_context/workspace.json`
  static String workspaceMetadata(String workspaceRoot) =>
      '${workspaceDir(workspaceRoot)}/workspace.json';

  /// Path to local package index directory in workspace registry.
  ///
  /// Example: `/path/to/monorepo/.dart_context/local/hologram_core/`
  static String localPackageDir(String workspaceRoot, String packageName) =>
      '${workspaceDir(workspaceRoot)}/local/$packageName';

  /// Path to local package index file in workspace registry.
  static String localPackageIndex(String workspaceRoot, String packageName) =>
      '${localPackageDir(workspaceRoot, packageName)}/index.scip';

  /// Path to local package manifest file in workspace registry.
  static String localPackageManifest(
          String workspaceRoot, String packageName,) =>
      '${localPackageDir(workspaceRoot, packageName)}/manifest.json';

  /// Path to per-package working index directory.
  ///
  /// Example: `/path/to/monorepo/packages/hologram_core/.dart_context/`
  static String packageWorkingDir(String packagePath) =>
      '$packagePath/.dart_context';

  /// Path to per-package working index file.
  static String packageWorkingIndex(String packagePath) =>
      '${packageWorkingDir(packagePath)}/index.scip';

  /// Path to per-package working manifest file.
  static String packageWorkingManifest(String packagePath) =>
      '${packageWorkingDir(packagePath)}/manifest.json';

  // ─────────────────────────────────────────────────────────────────────────
  // Utility methods
  // ─────────────────────────────────────────────────────────────────────────

  /// Check if an SDK index exists.
  static Future<bool> hasSdkIndex(String version) async {
    return File(sdkIndex(version)).exists();
  }

  /// Check if a Flutter package index exists.
  static Future<bool> hasFlutterIndex(
      String version, String packageName,) async {
    return File(flutterIndex(version, packageName)).exists();
  }

  /// Check if a hosted package index exists.
  static Future<bool> hasHostedIndex(String name, String version) async {
    return File(hostedIndex(name, version)).exists();
  }

  /// Check if a git package index exists.
  static Future<bool> hasGitIndex(String repoCommitKey) async {
    return File(gitIndex(repoCommitKey)).exists();
  }

  /// Check if a local package index exists in workspace registry.
  static Future<bool> hasLocalPackageIndex(
      String workspaceRoot, String packageName,) async {
    return File(localPackageIndex(workspaceRoot, packageName)).exists();
  }

  /// List all indexed SDK versions.
  static Future<List<String>> listSdkVersions() async {
    final dir = Directory('$globalCacheDir/sdk');
    if (!await dir.exists()) return [];

    return dir
        .list()
        .where((e) => e is Directory)
        .map((e) => e.path.split('/').last)
        .toList();
  }

  /// List all indexed Flutter versions.
  static Future<List<String>> listFlutterVersions() async {
    final dir = Directory('$globalCacheDir/flutter');
    if (!await dir.exists()) return [];

    return dir
        .list()
        .where((e) => e is Directory)
        .map((e) => e.path.split('/').last)
        .toList();
  }

  /// List all indexed hosted packages.
  ///
  /// Returns a list of `name-version` strings.
  static Future<List<String>> listHostedPackages() async {
    final dir = Directory('$globalCacheDir/hosted');
    if (!await dir.exists()) return [];

    return dir
        .list()
        .where((e) => e is Directory)
        .map((e) => e.path.split('/').last)
        .toList();
  }

  /// List all indexed git packages.
  ///
  /// Returns a list of `repo-commit` strings.
  static Future<List<String>> listGitPackages() async {
    final dir = Directory('$globalCacheDir/git');
    if (!await dir.exists()) return [];

    return dir
        .list()
        .where((e) => e is Directory)
        .map((e) => e.path.split('/').last)
        .toList();
  }

  /// Extract repo name and short commit from a git cache path.
  ///
  /// Input: `fluxon-bfef6c5e6909d853f20880bbc5272a826738fa58`
  /// Output: `GitPackageKey(repo: 'fluxon', commit: 'bfef6c5e')`
  static GitPackageKey? parseGitKey(String key) {
    // Format: <repo-name>-<40-char-commit>
    // We need to find the last hyphen before a 40-char hex string
    final match = RegExp(r'^(.+)-([a-f0-9]{8,40})$').firstMatch(key);
    if (match == null) return null;

    return GitPackageKey(
      repoName: match.group(1)!,
      commit: match.group(2)!,
      shortCommit: match.group(2)!.substring(0, 8),
    );
  }

  /// Create a cache key for a git package.
  ///
  /// Example: `fluxon-bfef6c5e`
  static String gitCacheKey(String repoName, String commit) {
    final shortCommit = commit.length > 8 ? commit.substring(0, 8) : commit;
    return '$repoName-$shortCommit';
  }
}

/// Parsed git package key.
class GitPackageKey {
  const GitPackageKey({
    required this.repoName,
    required this.commit,
    required this.shortCommit,
  });

  final String repoName;
  final String commit;
  final String shortCommit;

  @override
  String toString() => '$repoName-$shortCommit';
}

