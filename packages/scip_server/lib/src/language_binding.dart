import 'dart:async';

import 'index/scip_index.dart';

/// Interface for language-specific SCIP implementations.
///
/// Each supported language (Dart, TypeScript, Python, etc.) implements this
/// interface to provide:
/// - Package discovery (finding projects in a directory)
/// - Indexer creation (building SCIP indexes for packages)
/// - Language-specific metadata
///
/// Example:
/// ```dart
/// class DartBinding implements LanguageBinding {
///   @override
///   String get languageId => 'dart';
///
///   @override
///   List<String> get extensions => ['.dart'];
///
///   @override
///   String get packageFile => 'pubspec.yaml';
///   // ...
/// }
/// ```
abstract class LanguageBinding {
  /// Language identifier (e.g., "dart", "typescript", "python").
  String get languageId;

  /// File extensions for this language (e.g., [".dart"], [".ts", ".tsx"]).
  List<String> get extensions;

  /// Package manifest filename (e.g., "pubspec.yaml", "package.json").
  String get packageFile;

  /// Discover packages in a directory.
  ///
  /// Recursively searches [rootPath] for packages (identified by [packageFile]).
  /// Returns a list of discovered packages with their metadata.
  Future<List<DiscoveredPackage>> discoverPackages(String rootPath);

  /// Create an indexer for a package.
  ///
  /// The indexer handles:
  /// - Initial indexing (full scan or cache load)
  /// - Incremental updates (if [supportsIncremental] is true)
  /// - Index persistence
  Future<PackageIndexer> createIndexer(
    String packagePath, {
    bool useCache = true,
  });

  /// Whether this binding supports true incremental indexing.
  ///
  /// If true, the indexer can update individual files without re-indexing
  /// the entire package. If false, any file change triggers a full re-index.
  bool get supportsIncremental;

  /// Global cache directory for external package indexes.
  ///
  /// For Dart: ~/.dart_context/
  /// For TypeScript: ~/.ts_context/ (or similar)
  String get globalCachePath;
}

/// A discovered package.
class DiscoveredPackage {
  const DiscoveredPackage({
    required this.name,
    required this.path,
    required this.version,
  });

  /// Package name (e.g., "my_app").
  final String name;

  /// Absolute path to the package root.
  final String path;

  /// Package version (e.g., "1.0.0").
  final String version;

  @override
  String toString() => 'DiscoveredPackage($name@$version at $path)';
}

/// Interface for package indexers.
///
/// Each language binding creates indexers that implement this interface.
/// The indexer manages the SCIP index for a single package.
abstract class PackageIndexer {
  /// The current SCIP index for this package.
  ScipIndex get index;

  /// Stream of index updates.
  ///
  /// Emits events when the index changes (file added, modified, removed).
  Stream<IndexUpdate> get updates;

  /// Update the index for a specific file.
  ///
  /// Called when a file changes. If the binding doesn't support incremental
  /// indexing, this may trigger a full re-index.
  Future<void> updateFile(String path);

  /// Remove a file from the index.
  Future<void> removeFile(String path);

  /// Dispose of resources (file watchers, analyzer contexts, etc.).
  Future<void> dispose();
}

/// Base class for index update events.
sealed class IndexUpdate {
  const IndexUpdate();
}

/// Initial index was built (fresh or from cache).
class InitialIndexUpdate extends IndexUpdate {
  const InitialIndexUpdate({
    required this.fileCount,
    required this.symbolCount,
    required this.fromCache,
    required this.duration,
  });

  final int fileCount;
  final int symbolCount;
  final bool fromCache;
  final Duration duration;
}

/// A file was updated in the index.
class FileUpdatedUpdate extends IndexUpdate {
  const FileUpdatedUpdate({
    required this.path,
    required this.symbolCount,
  });

  final String path;
  final int symbolCount;
}

/// A file was removed from the index.
class FileRemovedUpdate extends IndexUpdate {
  const FileRemovedUpdate({required this.path});

  final String path;
}

/// An error occurred during indexing.
class IndexErrorUpdate extends IndexUpdate {
  const IndexErrorUpdate({
    required this.message,
    this.path,
  });

  final String message;
  final String? path;
}

