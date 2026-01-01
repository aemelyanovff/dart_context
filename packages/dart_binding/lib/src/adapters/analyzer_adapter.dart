import 'dart:async';

import 'package:analyzer/dart/analysis/results.dart';

/// Event types for file changes.
enum FileChangeType { create, modify, delete, move }

/// A file change event.
class FileChange {
  const FileChange({
    required this.path,
    required this.type,
    this.previousPath,
  });

  final String path;
  final FileChangeType type;

  /// For move events, the original path before the move.
  final String? previousPath;
}

/// Adapter interface for external analyzer integration.
///
/// Implement this to allow dart_context to use an existing
/// Dart analyzer instance instead of creating its own.
///
/// Example integration with HologramAnalyzer:
/// ```dart
/// class HologramAnalyzerAdapter implements AnalyzerAdapter {
///   HologramAnalyzerAdapter(this._analyzer);
///   final HologramAnalyzer _analyzer;
///
///   @override
///   String get projectRoot => _analyzer.projectRoot;
///
///   @override
///   Future<ResolvedUnitResult?> getResolvedUnit(String filePath) async {
///     final result = await _analyzer.getResolvedUnit(filePath);
///     return result is ResolvedUnitResult ? result : null;
///   }
///
///   @override
///   Stream<FileChange>? get fileChanges => _fsWatcher.events.map(...);
/// }
/// ```
abstract interface class AnalyzerAdapter {
  /// The project root path.
  String get projectRoot;

  /// Get the resolved unit for a file.
  ///
  /// Returns null if the file cannot be resolved (doesn't exist,
  /// has errors preventing resolution, etc).
  Future<ResolvedUnitResult?> getResolvedUnit(String filePath);

  /// Optional stream of file changes.
  ///
  /// If provided, the indexer will listen for changes and update
  /// the index accordingly. If null, the indexer will use its
  /// own file watcher.
  Stream<FileChange>? get fileChanges;

  /// Optional: Notify the analyzer that a file has changed.
  ///
  /// Some analyzers need explicit notification before getting
  /// updated resolved units. If your analyzer handles this
  /// automatically, this can be a no-op.
  Future<void> notifyFileChange(String filePath) async {}

  /// Optional: List all Dart files in the project.
  ///
  /// If provided, the indexer will use this instead of scanning
  /// the file system. Useful if the host already tracks files.
  Future<List<String>>? listDartFiles() => null;
}

/// Default implementation that wraps an AnalysisContextCollection.
///
/// Use this when you don't have an existing analyzer but want
/// to customize file watching behavior.
class DefaultAnalyzerAdapter implements AnalyzerAdapter {
  DefaultAnalyzerAdapter({
    required String projectRoot,
    required dynamic collection, // AnalysisContextCollection
    this.fileChanges,
  })  : _projectRoot = projectRoot,
        _collection = collection;

  final String _projectRoot;
  final dynamic _collection; // AnalysisContextCollection

  @override
  String get projectRoot => _projectRoot;

  @override
  final Stream<FileChange>? fileChanges;

  @override
  Future<ResolvedUnitResult?> getResolvedUnit(String filePath) async {
    try {
      final context = _collection.contextFor(filePath);
      final result = await context.currentSession.getResolvedUnit(filePath);
      return result is ResolvedUnitResult ? result : null;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> notifyFileChange(String filePath) async {
    try {
      final context = _collection.contextFor(filePath);
      context.changeFile(filePath);
      await context.applyPendingFileChanges();
    } catch (_) {
      // File might not be in any context
    }
  }

  @override
  Future<List<String>>? listDartFiles() => null;
}
