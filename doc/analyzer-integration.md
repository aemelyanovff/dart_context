# External Analyzer Integration

When integrating with an existing analyzer (e.g., HologramAnalyzer), you can avoid creating duplicate analyzer contexts by using an adapter.

## Basic Adapter Usage

```dart
import 'package:dart_binding/dart_binding.dart';
import 'package:analyzer/dart/analysis/results.dart';

// Create an adapter that wraps your existing analyzer
final adapter = HologramAnalyzerAdapter(
  projectRoot: analyzer.projectRoot,
  
  // Delegate to your existing analyzer
  getResolvedUnit: (path) async {
    final result = await analyzer.getResolvedUnit(path);
    return result is ResolvedUnitResult ? result : null;
  },
  
  // Use your existing file watcher
  fileChanges: fsWatcher.events.map((event) => FileChange(
    path: event.path,
    type: event.type.toFileChangeType(),
    previousPath: event is FSMoveEvent ? event.previousPath : null,
  )),
);

// Create indexer with shared analyzer
final indexer = await IncrementalScipIndexer.openWithAdapter(
  adapter,
  packageConfig: packageConfig,
  pubspec: pubspec,
);

// Query the index
final executor = QueryExecutor(indexer.index);
final result = await executor.execute('refs login');
print(result.toText());
```

## With Fluxon Service (Hologram)

```dart
@ServiceContract(remote: true)
class DartContextService extends FluxonService {
  late final IncrementalScipIndexer _indexer;
  
  @override
  Future<void> initialize() async {
    await super.initialize();
    
    final adapter = HologramAnalyzerAdapter(
      projectRoot: projectRootDirectory.path,
      getResolvedUnit: (path) => _analyzer.getResolvedUnit(path),
      fileChanges: _fsWatcher.events.map(_toFileChange),
    );
    
    _indexer = await IncrementalScipIndexer.openWithAdapter(
      adapter,
      packageConfig: _packageConfig,
      pubspec: _pubspec,
    );
  }
  
  @ServiceMethod()
  Future<String> query(String dsl) async {
    final executor = QueryExecutor(_indexer.index);
    final result = await executor.execute(dsl);
    return result.toText();
  }
}
```

## Incremental Updates from Resolved Units

If you already have resolved units, you can update the index directly:

```dart
// When HologramAnalyzer completes analysis
analyzer.onFileDartAnalysisCompleted = (filePath, result) {
  if (result is ResolvedUnitResult) {
    indexer.indexWithResolvedUnit(filePath, result);
  }
};
```

## Adapter Interface

The `AnalyzerAdapter` interface requires:

```dart
abstract interface class AnalyzerAdapter {
  /// Project root path
  String get projectRoot;
  
  /// Get a resolved unit for a file
  Future<ResolvedUnitResult?> getResolvedUnit(String path);
  
  /// Stream of file change events (optional)
  Stream<FileChange>? get fileChanges;
  
  /// Notify analyzer of file changes (optional)
  Future<void> notifyFileChange(String filePath);
  
  /// List all Dart files (optional, falls back to filesystem scan)
  Future<List<String>>? listDartFiles();
}
```

## Available Adapters

| Adapter | Use Case |
|---------|----------|
| `AnalyzerAdapter` | Base interface - implement for custom analyzers |
| `DefaultAnalyzerAdapter` | Wraps `AnalysisContextCollection` |
| `HologramAnalyzerAdapter` | Ready-to-use for Hologram/Fluxon integration |

## Benefits

- **No duplicate analyzers**: Share the analyzer context with your existing tools
- **Unified file watching**: Reuse your existing file watcher
- **Incremental updates**: Index updates automatically when files change
- **Memory efficient**: Single analyzer instance serves multiple purposes
