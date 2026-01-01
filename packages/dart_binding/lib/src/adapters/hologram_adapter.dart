import 'dart:async';

import 'package:analyzer/dart/analysis/results.dart';

import 'analyzer_adapter.dart';

/// Ready-to-use adapter for HologramAnalyzer integration.
///
/// Usage in hologram_server:
/// ```dart
/// import 'package:dart_context/dart_context.dart';
///
/// // In AnalyzerService or wherever you have access to HologramAnalyzer
/// class DartContextService extends FluxonService {
///   late final IncrementalScipIndexer _indexer;
///
///   @override
///   Future<void> initialize() async {
///     await super.initialize();
///
///     // Create adapter wrapping HologramAnalyzer
///     final adapter = HologramAnalyzerAdapter(
///       projectRoot: _analyzer.projectRoot,
///       getResolvedUnit: (path) async {
///         final result = await _analyzer.getResolvedUnit(path);
///         return result is ResolvedUnitResult ? result : null;
///       },
///       fileChanges: _fsWatcher.events.map((event) => FileChange(
///         path: event.path,
///         type: _mapEventType(event.type),
///         previousPath: event.previousPath,
///       )),
///     );
///
///     // Create indexer with adapter
///     _indexer = await IncrementalScipIndexer.openWithAdapter(
///       adapter,
///       packageConfig: _packageConfig,
///       pubspec: _pubspec,
///     );
///   }
///
///   // Query method
///   Future<String> query(String dsl) async {
///     final executor = QueryExecutor(_indexer.index);
///     final result = await executor.execute(dsl);
///     return result.toText();
///   }
/// }
/// ```
class HologramAnalyzerAdapter implements AnalyzerAdapter {
  HologramAnalyzerAdapter({
    required String projectRoot,
    required Future<ResolvedUnitResult?> Function(String) getResolvedUnit,
    Stream<FileChange>? fileChanges,
    Future<void> Function(String)? notifyChange,
    Future<List<String>> Function()? listFiles,
  })  : _projectRoot = projectRoot,
        _getResolvedUnit = getResolvedUnit,
        _fileChanges = fileChanges,
        _notifyChange = notifyChange,
        _listFiles = listFiles;

  final String _projectRoot;
  final Future<ResolvedUnitResult?> Function(String) _getResolvedUnit;
  final Stream<FileChange>? _fileChanges;
  final Future<void> Function(String)? _notifyChange;
  final Future<List<String>> Function()? _listFiles;

  @override
  String get projectRoot => _projectRoot;

  @override
  Future<ResolvedUnitResult?> getResolvedUnit(String filePath) =>
      _getResolvedUnit(filePath);

  @override
  Stream<FileChange>? get fileChanges => _fileChanges;

  @override
  Future<void> notifyFileChange(String filePath) async {
    final notifyFn = _notifyChange;
    if (notifyFn != null) {
      await notifyFn(filePath);
    }
  }

  @override
  Future<List<String>>? listDartFiles() {
    return _listFiles?.call();
  }
}

/// Extension to help convert FSEventType to FileChangeType.
///
/// Usage:
/// ```dart
/// import 'package:fs_watcher/fs_watcher.dart';
/// import 'package:dart_context/dart_context.dart';
///
/// final fileChange = FileChange(
///   path: event.path,
///   type: event.type.toFileChangeType(),
/// );
/// ```
extension FSEventTypeToFileChange on Object {
  /// Convert FSEventType to FileChangeType.
  ///
  /// Assumes the object is an FSEventType enum from fs_watcher.
  FileChangeType toFileChangeType() {
    final name = toString().split('.').last.toLowerCase();
    return switch (name) {
      'create' => FileChangeType.create,
      'modify' => FileChangeType.modify,
      'delete' => FileChangeType.delete,
      'move' => FileChangeType.move,
      _ => FileChangeType.modify, // Default to modify
    };
  }
}

