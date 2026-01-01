import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:crypto/crypto.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
// ignore: implementation_imports
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
// ignore: implementation_imports
import 'package:scip_dart/src/scip_visitor.dart';

import 'package:scip_server/scip_server.dart';

import 'adapters/analyzer_adapter.dart';
import 'analyzer/signature_visitor.dart';
import 'index_cache.dart';

/// Incremental SCIP indexer with file watching.
///
/// Maintains a live index that updates automatically when files change.
/// Uses the Dart analyzer for semantic analysis and scip-dart for
/// SCIP document generation.
///
/// ## Using with External Analyzer
///
/// To integrate with an existing analyzer (e.g., HologramAnalyzer):
///
/// ```dart
/// final adapter = MyAnalyzerAdapter(myAnalyzer);
/// final indexer = await IncrementalScipIndexer.openWithAdapter(
///   adapter,
///   packageConfig: packageConfig,
///   pubspec: pubspec,
/// );
/// ```
class IncrementalScipIndexer {
  IncrementalScipIndexer._({
    required String projectRoot,
    required PackageConfig packageConfig,
    required Pubspec pubspec,
    required ScipIndex index,
    required IndexCache cache,
    AnalyzerAdapter? adapter,
    AnalysisContextCollection? collection,
  })  : _projectRoot = projectRoot,
        _adapter = adapter,
        _collection = collection,
        _packageConfig = packageConfig,
        _pubspec = pubspec,
        _index = index,
        _cache = cache;

  final String _projectRoot;
  final AnalyzerAdapter? _adapter;
  final AnalysisContextCollection? _collection;
  final PackageConfig _packageConfig;
  final Pubspec _pubspec;
  final ScipIndex _index;
  final IndexCache _cache;

  final Map<String, String> _fileHashes = {};
  StreamSubscription<FileSystemEvent>? _watcher;
  StreamSubscription<FileChange>? _externalWatcher;
  final _updateController = StreamController<IndexUpdate>.broadcast();

  /// Stream of index updates.
  Stream<IndexUpdate> get updates => _updateController.stream;

  /// The current index.
  ScipIndex get index => _index;

  /// The project root path.
  String get projectRoot => _projectRoot;

  /// Open a project and create an incremental indexer.
  ///
  /// This will:
  /// 1. Parse pubspec.yaml and package_config.json
  /// 2. Try to load from cache (if valid)
  /// 3. Create the analyzer context
  /// 4. Perform incremental indexing of changed files
  /// 5. Start watching for file changes
  ///
  /// Set [useCache] to false to force a full re-index.
  static Future<IncrementalScipIndexer> open(
    String projectPath, {
    bool watch = true,
    bool useCache = true,
  }) async {
    final normalizedPath = p.normalize(p.absolute(projectPath));

    // Load package config
    final packageConfigFile = File(
      p.join(normalizedPath, '.dart_tool', 'package_config.json'),
    );
    if (!await packageConfigFile.exists()) {
      throw StateError(
        'package_config.json not found. Run `dart pub get` first.',
      );
    }
    final packageConfig = await loadPackageConfigUri(
      packageConfigFile.uri,
    );

    // Load pubspec
    final pubspecFile = File(p.join(normalizedPath, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      throw StateError('pubspec.yaml not found in $normalizedPath');
    }
    final pubspec = Pubspec.parse(await pubspecFile.readAsString());

    // Create analyzer context
    final collection = AnalysisContextCollection(
      includedPaths: [normalizedPath],
    );

    // Try to load from cache
    final cache = IndexCache(projectRoot: normalizedPath);
    ScipIndex index;
    Map<String, String> fileHashes;
    var loadedFromCache = false;

    if (useCache) {
      final cached = await cache.load();
      if (cached != null) {
        index = ScipIndex.fromScipIndex(
          cached.index,
          projectRoot: normalizedPath,
        );
        fileHashes = cached.fileHashes;
        loadedFromCache = true;
      } else {
        index = ScipIndex.empty(projectRoot: normalizedPath);
        fileHashes = {};
      }
    } else {
      index = ScipIndex.empty(projectRoot: normalizedPath);
      fileHashes = {};
    }

    final indexer = IncrementalScipIndexer._(
      projectRoot: normalizedPath,
      collection: collection,
      packageConfig: packageConfig,
      pubspec: pubspec,
      index: index,
      cache: cache,
    );

    // Copy file hashes from cache
    indexer._fileHashes.addAll(fileHashes);

    if (loadedFromCache) {
      // Incremental update: only index changed files
      await indexer._indexChangedFiles();
    } else {
      // Full index
      await indexer._indexAll();
    }

    // Start watching if requested
    if (watch) {
      await indexer._startWatching();
    }

    return indexer;
  }

  /// Open with an external analyzer adapter.
  ///
  /// Use this when integrating with an existing analyzer service
  /// (e.g., HologramAnalyzer, dart_mcp_server).
  ///
  /// The adapter provides:
  /// - `getResolvedUnit()` for semantic analysis
  /// - `fileChanges` stream for file watching (optional)
  /// - `notifyFileChange()` for change notification (optional)
  ///
  /// Example:
  /// ```dart
  /// class HologramAdapter implements AnalyzerAdapter {
  ///   HologramAdapter(this._analyzer, this._fileChanges);
  ///
  ///   final HologramAnalyzer _analyzer;
  ///   final Stream<FileChange> _fileChanges;
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
  ///   Stream<FileChange>? get fileChanges => _fileChanges;
  /// }
  /// ```
  static Future<IncrementalScipIndexer> openWithAdapter(
    AnalyzerAdapter adapter, {
    required PackageConfig packageConfig,
    required Pubspec pubspec,
    bool useCache = true,
  }) async {
    final normalizedPath = p.normalize(p.absolute(adapter.projectRoot));

    // Try to load from cache
    final cache = IndexCache(projectRoot: normalizedPath);
    ScipIndex index;
    Map<String, String> fileHashes;
    var loadedFromCache = false;

    if (useCache) {
      final cached = await cache.load();
      if (cached != null) {
        index = ScipIndex.fromScipIndex(
          cached.index,
          projectRoot: normalizedPath,
        );
        fileHashes = cached.fileHashes;
        loadedFromCache = true;
      } else {
        index = ScipIndex.empty(projectRoot: normalizedPath);
        fileHashes = {};
      }
    } else {
      index = ScipIndex.empty(projectRoot: normalizedPath);
      fileHashes = {};
    }

    final indexer = IncrementalScipIndexer._(
      projectRoot: normalizedPath,
      adapter: adapter,
      packageConfig: packageConfig,
      pubspec: pubspec,
      index: index,
      cache: cache,
    );

    // Copy file hashes from cache
    indexer._fileHashes.addAll(fileHashes);

    if (loadedFromCache) {
      await indexer._indexChangedFiles();
    } else {
      await indexer._indexAll();
    }

    // Start watching using adapter's file changes stream
    if (adapter.fileChanges != null) {
      indexer._startExternalWatching(adapter.fileChanges!);
    }

    return indexer;
  }

  /// Index all Dart files in the project.
  Future<void> _indexAll() async {
    final dartFiles = await _findDartFiles();

    for (final file in dartFiles) {
      await _indexFile(file, notify: false);
    }

    // Save to cache
    await _saveCache();

    _updateController.add(IndexUpdate.initial(_index.stats));
  }

  /// Index only changed files (incremental update from cache).
  Future<void> _indexChangedFiles() async {
    final dartFiles = await _findDartFiles();
    final changes = await _cache.getChangedFiles(dartFiles);

    if (!changes.hasChanges) {
      // No changes, use cached index as-is
      _updateController.add(
        IndexUpdate.cached(_index.stats, changes.totalChanges),
      );
      return;
    }

    // Remove deleted files from index
    for (final file in changes.removed) {
      final relativePath = p.relative(file, from: _projectRoot);
      _index.removeDocument(relativePath);
      _fileHashes.remove(file);
    }

    // Index changed and new files
    for (final file in [...changes.changed, ...changes.added]) {
      await _indexFile(file, notify: false);
    }

    // Save updated cache
    await _saveCache();

    _updateController.add(
      IndexUpdate.incremental(
        _index.stats,
        changed: changes.changed.length,
        added: changes.added.length,
        removed: changes.removed.length,
      ),
    );
  }

  /// Save current index to cache.
  Future<void> _saveCache() async {
    // Build SCIP index from current state
    final documents = <scip.Document>[];
    for (final path in _index.files) {
      final doc = _index.getDocument(path);
      if (doc != null) {
        documents.add(doc);
      }
    }

    final scipIndex = scip.Index(
      metadata: scip.Metadata(
        projectRoot: Uri.file(_projectRoot).toString(),
        textDocumentEncoding: scip.TextEncoding.UTF8,
        toolInfo: scip.ToolInfo(
          name: 'dart_context',
          version: '0.1.0',
        ),
      ),
      documents: documents,
    );

    // Convert absolute paths to relative for storage
    final relativeHashes = <String, String>{};
    for (final entry in _fileHashes.entries) {
      final relativePath = p.relative(entry.key, from: _projectRoot);
      relativeHashes[relativePath] = entry.value;
    }

    await _cache.save(
      index: scipIndex,
      fileHashes: relativeHashes,
    );
  }

  /// Find all Dart files in the project.
  Future<List<String>> _findDartFiles() async {
    // Use adapter's list if available
    final adapter = _adapter;
    if (adapter != null) {
      final adapterList = adapter.listDartFiles();
      if (adapterList != null) {
        return await adapterList;
      }
    }

    final files = <String>[];

    await for (final entity in Directory(_projectRoot).list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        // Skip hidden directories and build output
        final relative = p.relative(entity.path, from: _projectRoot);
        if (relative.startsWith('.') ||
            relative.contains('/.') ||
            relative.startsWith('build/')) {
          continue;
        }
        files.add(entity.path);
      }
    }

    return files;
  }

  /// Get resolved unit from adapter or collection.
  Future<ResolvedUnitResult?> _getResolvedUnit(String filePath) async {
    final adapter = _adapter;
    if (adapter != null) {
      return adapter.getResolvedUnit(filePath);
    }

    try {
      final context = _collection!.contextFor(filePath);
      final result = await context.currentSession.getResolvedUnit(filePath);
      return result is ResolvedUnitResult ? result : null;
    } catch (e) {
      return null;
    }
  }

  /// Index a single file.
  Future<bool> _indexFile(String filePath, {bool notify = true}) async {
    // Check if file has changed
    final hash = await _computeHash(filePath);
    if (_fileHashes[filePath] == hash) {
      return false; // No change
    }
    _fileHashes[filePath] = hash;

    try {
      // Get resolved unit
      final result = await _getResolvedUnit(filePath);

      if (result == null) {
        return false;
      }

      // Generate SCIP document using scip-dart's visitor
      final relativePath = p.relative(filePath, from: _projectRoot);
      final visitor = ScipVisitor(
        relativePath,
        _projectRoot,
        result.lineInfo,
        result.errors,
        _packageConfig,
        _pubspec,
      );
      result.unit.accept(visitor);

      // Enhance occurrences with proper enclosing ranges from AST
      final enhancedOccurrences = _enhanceOccurrencesWithRanges(
        visitor.occurrences,
        result.unit,
        result.lineInfo,
      );

      final doc = scip.Document(
        language: 'Dart',
        relativePath: relativePath,
        occurrences: enhancedOccurrences,
        symbols: visitor.symbols,
      );

      // Update index
      _index.updateDocument(doc);

      if (notify) {
        _updateController.add(IndexUpdate.fileUpdated(relativePath));
      }

      return true;
    } catch (e) {
      _updateController.add(IndexUpdate.error(filePath, e.toString()));
      return false;
    }
  }

  /// Remove a file from the index.
  void _removeFile(String filePath) {
    final relativePath = p.relative(filePath, from: _projectRoot);
    _index.removeDocument(relativePath);
    _fileHashes.remove(filePath);
    _updateController.add(IndexUpdate.fileRemoved(relativePath));
  }

  /// Compute SHA-256 hash of a file.
  Future<String> _computeHash(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return '';

    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Start watching for file changes (internal watcher).
  Future<void> _startWatching() async {
    final directory = Directory(_projectRoot);

    _watcher = directory
        .watch(recursive: true)
        .where((event) => event.path.endsWith('.dart'))
        .where((event) {
      // Filter out hidden and build directories
      final relative = p.relative(event.path, from: _projectRoot);
      return !relative.startsWith('.') &&
          !relative.contains('/.') &&
          !relative.startsWith('build/');
    }).listen(_handleFileEvent);
  }

  /// Start watching using external file change stream.
  void _startExternalWatching(Stream<FileChange> changes) {
    _externalWatcher = changes.listen(_handleExternalFileChange);
  }

  /// Handle a file system event.
  void _handleFileEvent(FileSystemEvent event) async {
    final path = event.path;

    if (event is FileSystemDeleteEvent) {
      _removeFile(path);
    } else if (event is FileSystemCreateEvent ||
        event is FileSystemModifyEvent) {
      // Notify analyzer of the change
      final adapter = _adapter;
      if (adapter != null) {
        await adapter.notifyFileChange(path);
      } else {
        try {
          final context = _collection!.contextFor(path);
          context.changeFile(path);
          await context.applyPendingFileChanges();
        } catch (e) {
          // File might not be in any context
        }
      }

      // Re-index the file
      await _indexFile(path);
    } else if (event is FileSystemMoveEvent) {
      // Handle rename as delete + create
      _removeFile(path);
      if (event.destination != null) {
        await _indexFile(event.destination!);
      }
    }
  }

  /// Handle an external file change event.
  Future<void> _handleExternalFileChange(FileChange change) async {
    final path = change.path;

    switch (change.type) {
      case FileChangeType.delete:
        _removeFile(path);
      case FileChangeType.create:
      case FileChangeType.modify:
        // Clear hash to force re-index
        _fileHashes.remove(path);
        await _indexFile(path);
      case FileChangeType.move:
        if (change.previousPath != null) {
          _removeFile(change.previousPath!);
        }
        _fileHashes.remove(path);
        await _indexFile(path);
    }
  }

  /// Manually trigger indexing for a file with an existing resolved unit.
  ///
  /// Use this when you already have a resolved unit from your analyzer
  /// and want to update the index without re-resolving.
  Future<bool> indexWithResolvedUnit(
    String filePath,
    ResolvedUnitResult result,
  ) async {
    // Update hash based on content
    final hash = result.content.hashCode.toString();
    if (_fileHashes[filePath] == hash) {
      return false; // No change
    }
    _fileHashes[filePath] = hash;

    try {
      final relativePath = p.relative(filePath, from: _projectRoot);
      final visitor = ScipVisitor(
        relativePath,
        _projectRoot,
        result.lineInfo,
        result.errors,
        _packageConfig,
        _pubspec,
      );
      result.unit.accept(visitor);

      // Enhance occurrences with proper enclosing ranges from AST
      final enhancedOccurrences = _enhanceOccurrencesWithRanges(
        visitor.occurrences,
        result.unit,
        result.lineInfo,
      );

      final doc = scip.Document(
        language: 'Dart',
        relativePath: relativePath,
        occurrences: enhancedOccurrences,
        symbols: visitor.symbols,
      );

      _index.updateDocument(doc);
      _updateController.add(IndexUpdate.fileUpdated(relativePath));

      return true;
    } catch (e) {
      _updateController.add(IndexUpdate.error(filePath, e.toString()));
      return false;
    }
  }

  /// Enhance SCIP occurrences with proper enclosing ranges from AST.
  ///
  /// scip_dart doesn't always populate enclosingRange for definitions,
  /// so we use the AST to find the actual extent of each declaration.
  List<scip.Occurrence> _enhanceOccurrencesWithRanges(
    List<scip.Occurrence> occurrences,
    CompilationUnit unit,
    LineInfo lineInfo,
  ) {
    // Build a map of (line, column) -> AST node end offset
    final declarationEnds = <(int, int), int>{};

    unit.accept(_DeclarationEndVisitor((node, nameOffset) {
      final location = lineInfo.getLocation(nameOffset);
      final endOffset = node.end;
      final endLocation = lineInfo.getLocation(endOffset);
      // Store as (line, column) -> endLine (0-indexed)
      declarationEnds[(location.lineNumber - 1, location.columnNumber - 1)] =
          endLocation.lineNumber - 1;
    }),);

    return occurrences.map((occ) {
      // Only enhance definition occurrences that don't have enclosingRange
      final isDefinition =
          (occ.symbolRoles & scip.SymbolRole.Definition.value) != 0;
      if (!isDefinition || occ.enclosingRange.isNotEmpty) {
        return occ;
      }

      // Find the end line from our map
      final line = occ.range.isNotEmpty ? occ.range[0] : 0;
      final col = occ.range.length > 1 ? occ.range[1] : 0;
      final endLine = declarationEnds[(line, col)];

      if (endLine == null) {
        return occ;
      }

      // Create enhanced occurrence with enclosingRange
      return scip.Occurrence(
        range: occ.range,
        symbol: occ.symbol,
        symbolRoles: occ.symbolRoles,
        overrideDocumentation: occ.overrideDocumentation,
        syntaxKind: occ.syntaxKind,
        diagnostics: occ.diagnostics,
        enclosingRange: [line, 0, endLine, 0], // Full extent of declaration
      );
    }).toList();
  }

  /// Manually refresh a file (useful when watching is disabled).
  Future<bool> refreshFile(String filePath) async {
    // Notify analyzer
    final adapter = _adapter;
    if (adapter != null) {
      await adapter.notifyFileChange(filePath);
    } else {
      try {
        final context = _collection!.contextFor(filePath);
        context.changeFile(filePath);
        await context.applyPendingFileChanges();
      } catch (e) {
        // File might not be in any context
      }
    }

    // Force re-index by clearing hash
    _fileHashes.remove(filePath);
    return _indexFile(filePath);
  }

  /// Manually refresh all files.
  Future<void> refreshAll() async {
    _fileHashes.clear();
    await _indexAll();
  }

  /// Get the signature of a symbol using the analyzer.
  ///
  /// This parses the file and uses [SignatureVisitor] to generate
  /// a clean signature with method bodies replaced by `{}`.
  ///
  /// Returns `null` if the symbol or file cannot be found.
  Future<String?> getSignature(String symbolId) async {
    final sym = _index.getSymbol(symbolId);
    if (sym == null || sym.file == null) return null;

    final def = _index.findDefinition(symbolId);
    if (def == null) return null;

    final filePath = p.join(_projectRoot, sym.file!);
    final result = await _getResolvedUnit(filePath);
    if (result == null) return null;

    // Find the AST node at the definition location
    final node = _findNodeAtLocation(result.unit, def.line, def.column);
    if (node == null) return null;

    // Walk up to find the declaration
    final declaration = _findContainingDeclaration(node);
    if (declaration == null) return null;

    // Generate signature
    return generateSignature(declaration);
  }

  /// Find AST node at a specific line and column.
  AstNode? _findNodeAtLocation(CompilationUnit unit, int line, int column) {
    AstNode? result;

    void visit(AstNode node) {
      final lineInfo = unit.lineInfo;
      final nodeStart = lineInfo.getLocation(node.offset);
      final nodeEnd = lineInfo.getLocation(node.end);

      // Check if the target location is within this node
      if ((nodeStart.lineNumber - 1 <= line &&
          line <= nodeEnd.lineNumber - 1)) {
        result = node;
        // Continue to find more specific child nodes
        for (final child in node.childEntities) {
          if (child is AstNode) {
            visit(child);
          }
        }
      }
    }

    for (final declaration in unit.declarations) {
      visit(declaration);
    }

    return result;
  }

  /// Walk up the AST to find the containing declaration.
  AstNode? _findContainingDeclaration(AstNode node) {
    AstNode? current = node;

    while (current != null) {
      if (current is ClassDeclaration ||
          current is MixinDeclaration ||
          current is ExtensionDeclaration ||
          current is EnumDeclaration ||
          current is FunctionDeclaration ||
          current is MethodDeclaration ||
          current is ConstructorDeclaration ||
          current is FieldDeclaration ||
          current is TopLevelVariableDeclaration) {
        return current;
      }
      current = current.parent;
    }

    return node;
  }

  /// Stop watching and clean up resources.
  Future<void> dispose() async {
    await _watcher?.cancel();
    await _externalWatcher?.cancel();
    await _updateController.close();
  }
}

/// Represents an update to the index.
sealed class IndexUpdate {
  const IndexUpdate();

  factory IndexUpdate.initial(Map<String, int> stats) = InitialIndexUpdate;
  factory IndexUpdate.cached(Map<String, int> stats, int checkedFiles) =
      CachedIndexUpdate;
  factory IndexUpdate.incremental(
    Map<String, int> stats, {
    required int changed,
    required int added,
    required int removed,
  }) = IncrementalIndexUpdate;
  factory IndexUpdate.fileUpdated(String path) = FileUpdatedUpdate;
  factory IndexUpdate.fileRemoved(String path) = FileRemovedUpdate;
  factory IndexUpdate.error(String path, String message) = IndexErrorUpdate;
}

class InitialIndexUpdate extends IndexUpdate {
  const InitialIndexUpdate(this.stats);
  final Map<String, int> stats;

  @override
  String toString() =>
      'InitialIndexUpdate(files: ${stats['files']}, symbols: ${stats['symbols']})';
}

class CachedIndexUpdate extends IndexUpdate {
  const CachedIndexUpdate(this.stats, this.checkedFiles);
  final Map<String, int> stats;
  final int checkedFiles;

  @override
  String toString() =>
      'CachedIndexUpdate(files: ${stats['files']}, symbols: ${stats['symbols']}, from cache)';
}

class IncrementalIndexUpdate extends IndexUpdate {
  const IncrementalIndexUpdate(
    this.stats, {
    required this.changed,
    required this.added,
    required this.removed,
  });
  final Map<String, int> stats;
  final int changed;
  final int added;
  final int removed;

  @override
  String toString() =>
      'IncrementalIndexUpdate(+$added, ~$changed, -$removed files, '
      '${stats['symbols']} symbols)';
}

class FileUpdatedUpdate extends IndexUpdate {
  const FileUpdatedUpdate(this.path);
  final String path;

  @override
  String toString() => 'FileUpdatedUpdate($path)';
}

class FileRemovedUpdate extends IndexUpdate {
  const FileRemovedUpdate(this.path);
  final String path;

  @override
  String toString() => 'FileRemovedUpdate($path)';
}

class IndexErrorUpdate extends IndexUpdate {
  const IndexErrorUpdate(this.path, this.message);
  final String path;
  final String message;

  @override
  String toString() => 'IndexErrorUpdate($path: $message)';
}

/// Visitor that collects end positions of declarations for enclosing ranges.
class _DeclarationEndVisitor extends RecursiveAstVisitor<void> {
  _DeclarationEndVisitor(this.onDeclaration);

  final void Function(AstNode node, int nameOffset) onDeclaration;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    onDeclaration(node, node.name.offset);
    super.visitClassDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    onDeclaration(node, node.name.offset);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    if (node.name != null) {
      onDeclaration(node, node.name!.offset);
    }
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    onDeclaration(node, node.name.offset);
    super.visitEnumDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    onDeclaration(node, node.name.offset);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    onDeclaration(node, node.name.offset);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // Constructor name offset is the return type (class name)
    onDeclaration(node, node.returnType.offset);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    for (final variable in node.fields.variables) {
      onDeclaration(node, variable.name.offset);
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final variable in node.variables.variables) {
      onDeclaration(node, variable.name.offset);
    }
    super.visitTopLevelVariableDeclaration(node);
  }
}
