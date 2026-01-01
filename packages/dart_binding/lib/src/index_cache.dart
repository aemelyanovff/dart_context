import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:protobuf/protobuf.dart' show CodedBufferReader;
import 'package:scip_server/scip_server.dart' show ScipIndex;
// ignore: implementation_imports
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;

/// Manages caching of SCIP indexes to disk.
///
/// Cache is stored in `.dart_context/` directory within the project:
/// - `index.scip` - The SCIP protobuf index
/// - `manifest.json` - File hashes and metadata for cache validation
class IndexCache {
  IndexCache({required this.projectRoot});

  final String projectRoot;

  /// Cache directory path.
  String get cacheDir => p.join(projectRoot, '.dart_context');

  /// Path to the cached SCIP index.
  String get indexPath => p.join(cacheDir, 'index.scip');

  /// Path to the manifest file.
  String get manifestPath => p.join(cacheDir, 'manifest.json');

  /// Check if a valid cache exists.
  Future<bool> hasValidCache() async {
    final indexFile = File(indexPath);
    final manifestFile = File(manifestPath);

    if (!await indexFile.exists() || !await manifestFile.exists()) {
      return false;
    }

    try {
      final manifest = await _loadManifest();
      return await _validateManifest(manifest);
    } catch (e) {
      return false;
    }
  }

  /// Load the cached index.
  ///
  /// Returns null if cache is invalid or doesn't exist.
  Future<CachedIndex?> load() async {
    if (!await hasValidCache()) {
      return null;
    }

    try {
      final indexFile = File(indexPath);
      final bytes = await indexFile.readAsBytes();
      final reader = CodedBufferReader(
        bytes,
        sizeLimit: ScipIndex.defaultMaxIndexSize,
      );
      final index = scip.Index()..mergeFromCodedBufferReader(reader);

      final manifest = await _loadManifest();

      return CachedIndex(
        index: index,
        fileHashes: Map<String, String>.from(manifest['fileHashes'] as Map),
      );
    } catch (e) {
      // Cache corrupted, return null to trigger re-index
      return null;
    }
  }

  /// Save the index to cache.
  Future<void> save({
    required scip.Index index,
    required Map<String, String> fileHashes,
  }) async {
    // Ensure cache directory exists
    await Directory(cacheDir).create(recursive: true);

    // Save SCIP index
    final indexFile = File(indexPath);
    await indexFile.writeAsBytes(index.writeToBuffer());

    // Save manifest
    final manifest = {
      'version': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'projectRoot': projectRoot,
      'fileHashes': fileHashes,
    };
    final manifestFile = File(manifestPath);
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  /// Invalidate the cache (delete cache files).
  Future<void> invalidate() async {
    final dir = Directory(cacheDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Get changed files since cache was created.
  ///
  /// Returns a record with:
  /// - `changed`: Files that have been modified
  /// - `added`: New files not in cache
  /// - `removed`: Files that were deleted
  Future<FileChanges> getChangedFiles(List<String> currentFiles) async {
    final manifestFile = File(manifestPath);
    if (!await manifestFile.exists()) {
      return FileChanges(
        changed: const [],
        added: currentFiles,
        removed: const [],
      );
    }

    final manifest = await _loadManifest();
    final cachedHashes = Map<String, String>.from(
      manifest['fileHashes'] as Map,
    );

    final changed = <String>[];
    final added = <String>[];

    for (final file in currentFiles) {
      final relativePath = p.relative(file, from: projectRoot);
      final cachedHash = cachedHashes[relativePath];

      if (cachedHash == null) {
        added.add(file);
      } else {
        final currentHash = await _computeHash(file);
        if (currentHash != cachedHash) {
          changed.add(file);
        }
        cachedHashes.remove(relativePath);
      }
    }

    // Remaining keys in cachedHashes are removed files
    final removed = cachedHashes.keys
        .map((rel) => p.join(projectRoot, rel))
        .toList();

    return FileChanges(
      changed: changed,
      added: added,
      removed: removed,
    );
  }

  Future<Map<String, dynamic>> _loadManifest() async {
    final manifestFile = File(manifestPath);
    final content = await manifestFile.readAsString();
    return jsonDecode(content) as Map<String, dynamic>;
  }

  Future<bool> _validateManifest(Map<String, dynamic> manifest) async {
    // Check version
    if (manifest['version'] != 1) {
      return false;
    }

    // Check project root matches
    if (manifest['projectRoot'] != projectRoot) {
      return false;
    }

    // Spot-check a few files for hash validity
    final fileHashes = manifest['fileHashes'] as Map;
    if (fileHashes.isEmpty) {
      return true; // Empty project is valid
    }

    // Check first 5 files
    var checked = 0;
    for (final entry in fileHashes.entries) {
      if (checked >= 5) break;

      final filePath = p.join(projectRoot, entry.key);
      final file = File(filePath);

      if (!await file.exists()) {
        return false; // File was deleted
      }

      final currentHash = await _computeHash(filePath);
      if (currentHash != entry.value) {
        return false; // File was modified
      }

      checked++;
    }

    return true;
  }

  Future<String> _computeHash(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return '';

    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }
}

/// A cached index loaded from disk.
class CachedIndex {
  CachedIndex({
    required this.index,
    required this.fileHashes,
  });

  final scip.Index index;
  final Map<String, String> fileHashes;
}

/// Changes detected between cache and current state.
class FileChanges {
  FileChanges({
    required this.changed,
    required this.added,
    required this.removed,
  });

  final List<String> changed;
  final List<String> added;
  final List<String> removed;

  bool get hasChanges =>
      changed.isNotEmpty || added.isNotEmpty || removed.isNotEmpty;

  int get totalChanges => changed.length + added.length + removed.length;
}

