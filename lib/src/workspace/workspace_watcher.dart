import 'dart:async';
import 'dart:io';

import 'workspace_detector.dart';
import 'workspace_registry.dart';

/// Unified file watcher for mono repo workspaces.
///
/// Watches the entire workspace root and routes file changes
/// to the appropriate package indexer.
class WorkspaceWatcher {
  WorkspaceWatcher({
    required this.workspace,
    required this.registry,
    this.onPackageUpdated,
    this.onError,
  });

  /// The workspace being watched.
  final WorkspaceInfo workspace;

  /// The workspace registry managing package indexes.
  final WorkspaceRegistry registry;

  /// Callback when a package's index is updated.
  final void Function(String packageName, String filePath)? onPackageUpdated;

  /// Callback when an error occurs.
  final void Function(Object error, StackTrace? stack)? onError;

  StreamSubscription<FileSystemEvent>? _subscription;
  bool _isWatching = false;

  /// Whether the watcher is currently active.
  bool get isWatching => _isWatching;

  /// Start watching the workspace for file changes.
  Future<void> start() async {
    if (_isWatching) return;

    try {
      final stream = Directory(workspace.rootPath).watch(recursive: true);
      _subscription = stream.listen(
        _onFileEvent,
        onError: (error, stack) => onError?.call(error, stack),
      );
      _isWatching = true;
    } catch (e, stack) {
      onError?.call(e, stack);
    }
  }

  /// Stop watching the workspace.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _isWatching = false;
  }

  void _onFileEvent(FileSystemEvent event) {
    // Skip non-Dart files
    if (!event.path.endsWith('.dart')) return;

    // Skip generated/hidden files
    if (_shouldIgnore(event.path)) return;

    // Handle the event
    switch (event.type) {
      case FileSystemEvent.create:
      case FileSystemEvent.modify:
        _handleFileChange(event.path);
        break;
      case FileSystemEvent.delete:
        _handleFileDelete(event.path);
        break;
      case FileSystemEvent.move:
        final moveEvent = event as FileSystemMoveEvent;
        _handleFileDelete(event.path);
        if (moveEvent.destination != null) {
          _handleFileChange(moveEvent.destination!);
        }
        break;
    }
  }

  bool _shouldIgnore(String path) {
    // Ignore hidden directories and generated files
    final segments = path.split(Platform.pathSeparator);
    for (final segment in segments) {
      if (segment.startsWith('.')) return true;
      if (segment == 'build') return true;
      if (segment == 'generated') return true;
    }

    // Ignore generated Dart files
    if (path.endsWith('.g.dart')) return true;
    if (path.endsWith('.freezed.dart')) return true;
    if (path.endsWith('.pb.dart')) return true;
    if (path.endsWith('.pbjson.dart')) return true;
    if (path.endsWith('.pbserver.dart')) return true;
    if (path.endsWith('.pbgrpc.dart')) return true;

    return false;
  }

  Future<void> _handleFileChange(String filePath) async {
    try {
      final packageName = await registry.updateFile(filePath);
      if (packageName != null) {
        onPackageUpdated?.call(packageName, filePath);
      }
    } catch (e, stack) {
      onError?.call(e, stack);
    }
  }

  Future<void> _handleFileDelete(String filePath) async {
    // Find the package that owns this file
    final pkg = workspace.findPackageForPath(filePath);
    if (pkg == null) return;

    // For now, just trigger a full re-index of the package
    // A more sophisticated approach would remove just that file's symbols
    try {
      await registry.syncPackage(pkg.name);
    } catch (e, stack) {
      onError?.call(e, stack);
    }
  }
}

/// Configuration for workspace watching.
class WorkspaceWatchConfig {
  const WorkspaceWatchConfig({
    this.debounceMs = 100,
    this.ignoreDirs = const ['.dart_tool', '.git', 'build', '.idea', '.vscode'],
    this.ignorePatterns = const ['.g.dart', '.freezed.dart', '.pb.dart'],
  });

  /// Debounce time for file changes in milliseconds.
  final int debounceMs;

  /// Directories to ignore.
  final List<String> ignoreDirs;

  /// File patterns to ignore.
  final List<String> ignorePatterns;
}

