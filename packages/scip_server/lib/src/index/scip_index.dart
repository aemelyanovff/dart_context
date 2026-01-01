import 'dart:io';

import 'package:collection/collection.dart';
import 'package:protobuf/protobuf.dart' show CodedBufferReader;
// ignore: implementation_imports
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;

/// Queryable in-memory SCIP index with O(1) lookups.
///
/// Built from SCIP protobuf data, provides fast access to:
/// - Symbol definitions and references
/// - Class members and hierarchy
/// - File-to-symbol mappings
/// - Call graph (calls/callers)
///
/// ## Usage
///
/// ```dart
/// // Load from SCIP file
/// final index = await ScipIndex.loadFromFile('index.scip', projectRoot: '/my/project');
///
/// // Or build from SCIP protobuf
/// final index = ScipIndex.fromScipIndex(scipData, projectRoot: '/my/project');
///
/// // Query symbols
/// final symbols = index.findSymbols('MyClass');
/// final refs = index.findReferences(symbols.first.symbol);
/// final members = index.membersOf(symbols.first.symbol);
/// ```
///
/// ## Symbol IDs
///
/// Symbols are identified by SCIP-format strings like:
/// `dart pub mypackage 1.0.0 lib/src/my_class.dart/MyClass#login().`
///
/// Use [findSymbols] to search by name, which handles the full ID internally.
class ScipIndex {
  ScipIndex._({
    required Map<String, SymbolInfo> symbolIndex,
    required Map<String, List<OccurrenceInfo>> referenceIndex,
    required Map<String, scip.Document> documentIndex,
    required Map<String, List<String>> childIndex,
    required Map<String, Set<String>> callsIndex,
    required Map<String, Set<String>> callersIndex,
    required String projectRoot,
    String? sourceRoot,
  })  : _symbolIndex = symbolIndex,
        _referenceIndex = referenceIndex,
        _documentIndex = documentIndex,
        _childIndex = childIndex,
        _callsIndex = callsIndex,
        _callersIndex = callersIndex,
        _projectRoot = projectRoot,
        _sourceRoot = sourceRoot;

  final Map<String, SymbolInfo> _symbolIndex;
  final Map<String, List<OccurrenceInfo>> _referenceIndex;
  final Map<String, scip.Document> _documentIndex;
  final Map<String, List<String>> _childIndex; // parent → children
  final Map<String, Set<String>> _callsIndex; // symbol → symbols it calls
  final Map<String, Set<String>> _callersIndex; // symbol → symbols that call it
  final String _projectRoot;
  final String? _sourceRoot;

  /// Default maximum size for protobuf index files (256MB).
  static const int defaultMaxIndexSize = 256 << 20;

  /// Load index from a SCIP protobuf file.
  ///
  /// The [maxSize] parameter controls the maximum allowed index file size.
  /// Defaults to 256MB which is sufficient for large packages like Flutter.
  /// For very large monorepos, you may need to increase this.
  ///
  /// The [sourceRoot] parameter specifies where actual source files are located.
  /// This is useful for external packages where the index is cached separately
  /// from the source (e.g., pub cache). If not provided, defaults to [projectRoot].
  static Future<ScipIndex> loadFromFile(
    String indexPath, {
    required String projectRoot,
    String? sourceRoot,
    int maxSize = defaultMaxIndexSize,
  }) async {
    final bytes = await File(indexPath).readAsBytes();
    final reader = CodedBufferReader(
      bytes,
      sizeLimit: maxSize,
    );
    final index = scip.Index()..mergeFromCodedBufferReader(reader);
    return fromScipIndex(index, projectRoot: projectRoot, sourceRoot: sourceRoot);
  }

  /// Create an empty index with no symbols.
  ///
  /// Useful for bootstrapping when you need an index instance but don't
  /// have any data yet.
  static ScipIndex empty({String projectRoot = '', String? sourceRoot}) {
    return ScipIndex._(
      symbolIndex: {},
      referenceIndex: {},
      documentIndex: {},
      childIndex: {},
      callsIndex: {},
      callersIndex: {},
      projectRoot: projectRoot,
      sourceRoot: sourceRoot,
    );
  }

  /// Build index from SCIP protobuf data.
  ///
  /// The [sourceRoot] parameter specifies where actual source files are located.
  /// If not provided, defaults to [projectRoot].
  static ScipIndex fromScipIndex(
    scip.Index raw, {
    required String projectRoot,
    String? sourceRoot,
  }) {
    final symbolIndex = <String, SymbolInfo>{};
    final referenceIndex = <String, List<OccurrenceInfo>>{};
    final documentIndex = <String, scip.Document>{};
    final childIndex = <String, List<String>>{};
    final callsIndex = <String, Set<String>>{};
    final callersIndex = <String, Set<String>>{};

    for (final doc in raw.documents) {
      documentIndex[doc.relativePath] = doc;

      // First pass: collect definitions with their ranges
      final definitionsInFile = <({String symbol, int startLine, int endLine})>[];

      // Index symbols defined in this file
      for (final sym in doc.symbols) {
        symbolIndex[sym.symbol] = SymbolInfo.fromScip(
          sym,
          file: doc.relativePath,
        );

        // Track parent-child relationships
        final parent = _extractParentSymbol(sym.symbol);
        if (parent != null) {
          childIndex.putIfAbsent(parent, () => []).add(sym.symbol);
        }
      }

      // Index all occurrences (definitions + references)
      for (final occ in doc.occurrences) {
        referenceIndex.putIfAbsent(occ.symbol, () => []).add(
              OccurrenceInfo.fromScip(occ, file: doc.relativePath),
            );

        // Track definitions with their enclosing ranges for call graph
        final isDefinition =
            (occ.symbolRoles & scip.SymbolRole.Definition.value) != 0;
        if (isDefinition && occ.enclosingRange.isNotEmpty) {
          final startLine = occ.range.isNotEmpty ? occ.range[0] : 0;
          final endLine =
              occ.enclosingRange.length > 2 ? occ.enclosingRange[2] : startLine;
          definitionsInFile.add((
            symbol: occ.symbol,
            startLine: startLine,
            endLine: endLine,
          ),);
        }
      }

      // Second pass: build call graph by matching references to enclosing definitions
      for (final occ in doc.occurrences) {
        final isReference =
            (occ.symbolRoles & scip.SymbolRole.Definition.value) == 0;
        if (!isReference) continue;

        final refLine = occ.range.isNotEmpty ? occ.range[0] : 0;
        final referencedSymbol = occ.symbol;

        // Find which definition contains this reference
        for (final def in definitionsInFile) {
          if (refLine >= def.startLine && refLine <= def.endLine) {
            // def.symbol calls referencedSymbol
            callsIndex.putIfAbsent(def.symbol, () => {}).add(referencedSymbol);
            callersIndex
                .putIfAbsent(referencedSymbol, () => {})
                .add(def.symbol);
            break; // Use the first (innermost) match
          }
        }
      }
    }

    // Also index external symbols (from dependencies)
    for (final sym in raw.externalSymbols) {
      symbolIndex[sym.symbol] = SymbolInfo.fromScip(sym, file: null);
    }

    return ScipIndex._(
      symbolIndex: symbolIndex,
      referenceIndex: referenceIndex,
      documentIndex: documentIndex,
      childIndex: childIndex,
      callsIndex: callsIndex,
      callersIndex: callersIndex,
      projectRoot: projectRoot,
      sourceRoot: sourceRoot,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MUTATION (for incremental updates)
  // ═══════════════════════════════════════════════════════════════════════

  /// Update the index with a new/modified document.
  void updateDocument(scip.Document doc) {
    final path = doc.relativePath;

    // Remove old data for this file
    removeDocument(path);

    // Add new document
    _documentIndex[path] = doc;

    // First pass: collect definitions with their ranges
    final definitionsInFile = <({String symbol, int startLine, int endLine})>[];

    // Index symbols
    for (final sym in doc.symbols) {
      _symbolIndex[sym.symbol] = SymbolInfo.fromScip(sym, file: path);

      final parent = _extractParentSymbol(sym.symbol);
      if (parent != null) {
        _childIndex.putIfAbsent(parent, () => []).add(sym.symbol);
      }
    }

    // Index occurrences
    for (final occ in doc.occurrences) {
      _referenceIndex.putIfAbsent(occ.symbol, () => []).add(
            OccurrenceInfo.fromScip(occ, file: path),
          );

      // Track definitions with their enclosing ranges for call graph
      final isDefinition =
          (occ.symbolRoles & scip.SymbolRole.Definition.value) != 0;
      if (isDefinition && occ.enclosingRange.isNotEmpty) {
        final startLine = occ.range.isNotEmpty ? occ.range[0] : 0;
        final endLine =
            occ.enclosingRange.length > 2 ? occ.enclosingRange[2] : startLine;
        definitionsInFile.add((
          symbol: occ.symbol,
          startLine: startLine,
          endLine: endLine,
        ),);
      }
    }

    // Second pass: build call graph
    for (final occ in doc.occurrences) {
      final isReference =
          (occ.symbolRoles & scip.SymbolRole.Definition.value) == 0;
      if (!isReference) continue;

      final refLine = occ.range.isNotEmpty ? occ.range[0] : 0;
      final referencedSymbol = occ.symbol;

      for (final def in definitionsInFile) {
        if (refLine >= def.startLine && refLine <= def.endLine) {
          _callsIndex.putIfAbsent(def.symbol, () => {}).add(referencedSymbol);
          _callersIndex.putIfAbsent(referencedSymbol, () => {}).add(def.symbol);
          break;
        }
      }
    }
  }

  /// Remove a document from the index.
  void removeDocument(String path) {
    final oldDoc = _documentIndex.remove(path);
    if (oldDoc == null) return;

    // Collect symbols defined in this file for call graph cleanup
    final symbolsInFile = <String>{};

    // Remove symbols defined in this file
    for (final sym in oldDoc.symbols) {
      symbolsInFile.add(sym.symbol);
      _symbolIndex.remove(sym.symbol);

      // Remove from parent's children
      final parent = _extractParentSymbol(sym.symbol);
      if (parent != null) {
        _childIndex[parent]?.remove(sym.symbol);
      }
    }

    // Remove occurrences from this file
    for (final refs in _referenceIndex.values) {
      refs.removeWhere((occ) => occ.file == path);
    }

    // Clean up call graph
    for (final sym in symbolsInFile) {
      // Remove from callsIndex
      final calls = _callsIndex.remove(sym);
      if (calls != null) {
        for (final called in calls) {
          _callersIndex[called]?.remove(sym);
        }
      }

      // Remove from callersIndex
      final callers = _callersIndex.remove(sym);
      if (callers != null) {
        for (final caller in callers) {
          _callsIndex[caller]?.remove(sym);
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // QUERY API
  // ═══════════════════════════════════════════════════════════════════════

  /// Find symbols matching a pattern.
  ///
  /// Supports wildcards: `Auth*` matches `AuthRepository`, `AuthService`, etc.
  /// Supports OR patterns: `Scip*|*Index` matches names starting with "Scip"
  /// OR ending with "Index".
  ///
  /// The pattern matches the symbol NAME only (not the full path).
  /// Use `in:path` filter to match against file paths.
  Iterable<SymbolInfo> findSymbols(String pattern) {
    if (pattern.isEmpty) return const [];

    // Convert glob pattern to regex, anchored to match entire name
    final regexPattern = pattern
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');

    // Anchor the pattern to match the entire name
    // For OR patterns like "A*|*B", wrap in non-capturing group
    final anchoredPattern = pattern.contains('|')
        ? '^(?:$regexPattern)\$'
        : '^$regexPattern\$';

    final regex = RegExp(anchoredPattern, caseSensitive: false);

    return _symbolIndex.values.where((sym) {
      // Match against name only (not full symbol path)
      return regex.hasMatch(sym.name);
    });
  }

  /// Get a symbol by exact ID.
  SymbolInfo? getSymbol(String symbolId) => _symbolIndex[symbolId];

  /// Find a symbol by exact name (not ID).
  SymbolInfo? findByName(String name) {
    return _symbolIndex.values.firstWhereOrNull((s) => s.name == name);
  }

  /// Find all references to a symbol.
  List<OccurrenceInfo> findReferences(String symbolId) {
    return _referenceIndex[symbolId]
            ?.where((o) => !o.isDefinition)
            .toList() ??
        [];
  }

  /// Find the definition of a symbol.
  OccurrenceInfo? findDefinition(String symbolId) {
    return _referenceIndex[symbolId]?.firstWhereOrNull((o) => o.isDefinition);
  }

  /// Find all implementations of a class/interface.
  Iterable<SymbolInfo> findImplementations(String symbolId) {
    return _symbolIndex.values.where(
      (s) => s.relationships.any(
        (r) => r.symbol == symbolId && r.isImplementation,
      ),
    );
  }

  /// Get all symbols in a file.
  Iterable<SymbolInfo> symbolsInFile(String path) {
    return _symbolIndex.values.where((s) => s.file == path);
  }

  /// Get members of a class/type.
  Iterable<SymbolInfo> membersOf(String symbolId) {
    final children = _childIndex[symbolId] ?? [];
    return children.map((id) => _symbolIndex[id]).whereType<SymbolInfo>();
  }

  /// Get child symbol IDs of a class/type (raw IDs).
  List<String> getChildren(String symbolId) {
    return _childIndex[symbolId] ?? [];
  }

  /// Get supertypes of a class.
  Iterable<SymbolInfo> supertypesOf(String symbolId) {
    final sym = _symbolIndex[symbolId];
    if (sym == null) return const [];

    return sym.relationships
        .where((r) => r.isImplementation)
        .map((r) => _symbolIndex[r.symbol])
        .whereType<SymbolInfo>();
  }

  /// Get subtypes (implementations) of a class.
  Iterable<SymbolInfo> subtypesOf(String symbolId) {
    return findImplementations(symbolId);
  }

  /// Get the source code for a symbol.
  Future<String?> getSource(String symbolId) async {
    final def = findDefinition(symbolId);
    if (def == null) return null;

    final filePath = '$sourceRoot/${def.file}';
    final file = File(filePath);
    if (!await file.exists()) return null;

    final lines = await file.readAsLines();
    final startLine = def.line;

    // Use enclosingEndLine if available, otherwise find the end by brace matching
    int endLine;
    if (def.enclosingEndLine != null) {
      endLine = def.enclosingEndLine!;
    } else {
      // Find the end of the definition by matching braces
      endLine = _findDefinitionEnd(lines, startLine);
    }

    if (startLine >= lines.length) return null;

    return lines
        .sublist(startLine, endLine.clamp(0, lines.length))
        .join('\n');
  }

  /// Find the end line of a definition by matching braces.
  ///
  /// Handles classes, functions, methods, etc. by counting { and } braces.
  /// Falls back to startLine + 50 if no braces found.
  int _findDefinitionEnd(List<String> lines, int startLine) {
    var braceCount = 0;
    var foundOpenBrace = false;
    var inString = false;
    String? stringChar;
    var inMultilineComment = false;

    for (var i = startLine; i < lines.length; i++) {
      final line = lines[i];

      for (var j = 0; j < line.length; j++) {
        final char = line[j];
        final nextChar = j + 1 < line.length ? line[j + 1] : '';
        final prevChar = j > 0 ? line[j - 1] : '';

        // Handle comments
        if (!inString) {
          if (inMultilineComment) {
            if (char == '*' && nextChar == '/') {
              inMultilineComment = false;
              j++; // Skip the /
            }
            continue;
          }
          if (char == '/' && nextChar == '/') {
            break; // Rest of line is comment
          }
          if (char == '/' && nextChar == '*') {
            inMultilineComment = true;
            j++; // Skip the *
            continue;
          }
        }

        // Handle strings
        if ((char == '"' || char == "'") && prevChar != r'\') {
          if (!inString) {
            inString = true;
            stringChar = char;
            // Check for triple quotes
            if (j + 2 < line.length &&
                line[j + 1] == char &&
                line[j + 2] == char) {
              j += 2;
              stringChar = '$char$char$char';
            }
          } else if (stringChar == char ||
              (stringChar!.length == 3 &&
                  j + 2 < line.length &&
                  line.substring(j, j + 3) == stringChar)) {
            inString = false;
            stringChar = null;
          }
          continue;
        }

        if (inString) continue;

        // Count braces
        if (char == '{') {
          foundOpenBrace = true;
          braceCount++;
        } else if (char == '}') {
          braceCount--;
          if (foundOpenBrace && braceCount == 0) {
            return i + 1; // Include the closing brace line
          }
        }
      }
    }

    // Fallback: if no matching braces found, return a reasonable amount
    return (startLine + 50).clamp(0, lines.length);
  }

  /// Get source context around an occurrence.
  Future<String?> getContext(
    OccurrenceInfo occ, {
    int linesBefore = 2,
    int linesAfter = 2,
  }) async {
    final filePath = '$sourceRoot/${occ.file}';
    final file = File(filePath);
    if (!await file.exists()) return null;

    final lines = await file.readAsLines();
    final start = (occ.line - linesBefore).clamp(0, lines.length);
    final end = (occ.line + linesAfter + 1).clamp(0, lines.length);

    return lines.sublist(start, end).join('\n');
  }

  /// Get all files in the index.
  Iterable<String> get files => _documentIndex.keys;

  /// Get all symbols in the index.
  Iterable<SymbolInfo> get allSymbols => _symbolIndex.values;

  /// Get a document by path.
  scip.Document? getDocument(String path) => _documentIndex[path];

  /// Get the project root.
  String get projectRoot => _projectRoot;

  /// Get the source root where actual source files are located.
  ///
  /// For project indexes, this is the same as [projectRoot].
  /// For external package indexes, this points to the actual source location
  /// (e.g., pub cache path) rather than the cache directory.
  String get sourceRoot => _sourceRoot ?? _projectRoot;

  /// Get stats about the index.
  Map<String, int> get stats => {
        'files': _documentIndex.length,
        'symbols': _symbolIndex.length,
        'references': _referenceIndex.values.fold(0, (a, b) => a + b.length),
        'callEdges': _callsIndex.values.fold(0, (a, b) => a + b.length),
      };

  // ═══════════════════════════════════════════════════════════════════════
  // CALL GRAPH
  // ═══════════════════════════════════════════════════════════════════════

  /// Get symbols that the given symbol calls/references.
  Iterable<SymbolInfo> getCalls(String symbolId) {
    final called = _callsIndex[symbolId];
    if (called == null) return [];
    return called
        .map((id) => _symbolIndex[id])
        .whereType<SymbolInfo>();
  }

  /// Get symbols that call/reference the given symbol.
  Iterable<SymbolInfo> getCallers(String symbolId) {
    final callers = _callersIndex[symbolId];
    if (callers == null) return [];
    return callers
        .map((id) => _symbolIndex[id])
        .whereType<SymbolInfo>();
  }

  /// Get the full call graph for a symbol (calls + callers).
  ({List<SymbolInfo> calls, List<SymbolInfo> callers}) getCallGraph(
    String symbolId,
  ) {
    return (
      calls: getCalls(symbolId).toList(),
      callers: getCallers(symbolId).toList(),
    );
  }

  /// Search for a pattern in source files.
  ///
  /// Returns matches with file, line, and context.
  ///
  /// Parameters:
  /// - [pattern]: The regex pattern to search for
  /// - [pathFilter]: Only search in files starting with this path
  /// - [includeGlob]: Only include files matching this glob (e.g., "*.dart")
  /// - [excludeGlob]: Exclude files matching this glob (e.g., "*_test.dart")
  /// - [linesBefore]: Number of context lines before match (default 2)
  /// - [linesAfter]: Number of context lines after match (default 2)
  /// - [invertMatch]: If true, return lines that DON'T match
  /// - [maxPerFile]: Maximum matches per file (null for unlimited)
  /// - [multiline]: If true, match patterns across multiple lines
  /// - [onlyMatching]: If true, return only the matched text (not full line)
  Future<List<GrepMatchData>> grep(
    RegExp pattern, {
    String? pathFilter,
    String? includeGlob,
    String? excludeGlob,
    int linesBefore = 2,
    int linesAfter = 2,
    bool invertMatch = false,
    int? maxPerFile,
    bool multiline = false,
    bool onlyMatching = false,
  }) async {
    final results = <GrepMatchData>[];

    // Compile glob patterns if provided
    final includeRegex = includeGlob != null ? _globToRegex(includeGlob) : null;
    final excludeRegex = excludeGlob != null ? _globToRegex(excludeGlob) : null;

    for (final path in _documentIndex.keys) {
      // Apply path filter
      if (pathFilter != null && !path.startsWith(pathFilter)) continue;

      // Apply include glob
      if (includeRegex != null && !includeRegex.hasMatch(path)) continue;

      // Apply exclude glob
      if (excludeRegex != null && excludeRegex.hasMatch(path)) continue;

      final filePath = '$sourceRoot/$path';
      final file = File(filePath);
      if (!await file.exists()) continue;

      final content = await file.readAsString();

      if (multiline) {
        // Multiline matching - search across the entire content
        final fileResults = _grepMultiline(
          path,
          content,
          pattern,
          linesBefore: linesBefore,
          linesAfter: linesAfter,
          maxPerFile: maxPerFile,
          onlyMatching: onlyMatching,
        );
        results.addAll(fileResults);
      } else {
        // Line-by-line matching
        final fileResults = _grepLines(
          path,
          content,
          pattern,
          linesBefore: linesBefore,
          linesAfter: linesAfter,
          invertMatch: invertMatch,
          maxPerFile: maxPerFile,
          onlyMatching: onlyMatching,
        );
        results.addAll(fileResults);
      }
    }

    return results;
  }

  /// Line-by-line grep (standard mode).
  List<GrepMatchData> _grepLines(
    String path,
    String content,
    RegExp pattern, {
    required int linesBefore,
    required int linesAfter,
    required bool invertMatch,
    required int? maxPerFile,
    required bool onlyMatching,
  }) {
    final results = <GrepMatchData>[];
    final lines = content.split('\n');
    var fileMatchCount = 0;

    for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
      final line = lines[lineIdx];
      final allMatches = pattern.allMatches(line).toList();
      final hasMatch = allMatches.isNotEmpty;

      // For invert match, we want lines that DON'T match
      final shouldInclude = invertMatch ? !hasMatch : hasMatch;
      if (!shouldInclude) continue;

      // Check max per file limit
      if (maxPerFile != null && fileMatchCount >= maxPerFile) break;

      // Get context lines
      final startCtx = (lineIdx - linesBefore).clamp(0, lines.length);
      final endCtx = (lineIdx + linesAfter + 1).clamp(0, lines.length);
      final context = lines.sublist(startCtx, endCtx);

      // Find containing symbol
      final symbolContext = _findSymbolContext(path, lineIdx);

      if (onlyMatching && !invertMatch) {
        // Return each match separately
        for (final match in allMatches) {
          fileMatchCount++;
          if (maxPerFile != null && fileMatchCount > maxPerFile) break;

          results.add(
            GrepMatchData(
              file: path,
              line: lineIdx,
              column: match.start,
              matchText: match.group(0) ?? '',
              contextLines: const [], // No context for -o mode
              contextBefore: 0,
              symbolContext: symbolContext,
            ),
          );
        }
      } else {
        fileMatchCount++;
        final matchText = invertMatch
            ? line
            : (allMatches.isNotEmpty ? allMatches.first.group(0) ?? line : line);

        results.add(
          GrepMatchData(
            file: path,
            line: lineIdx,
            column: invertMatch ? 0 : (allMatches.firstOrNull?.start ?? 0),
            matchText: matchText,
            contextLines: context,
            contextBefore: lineIdx - startCtx,
            symbolContext: symbolContext,
          ),
        );
      }
    }

    return results;
  }

  /// Multiline grep (matches across line boundaries).
  List<GrepMatchData> _grepMultiline(
    String path,
    String content,
    RegExp pattern, {
    required int linesBefore,
    required int linesAfter,
    required int? maxPerFile,
    required bool onlyMatching,
  }) {
    final results = <GrepMatchData>[];
    final lines = content.split('\n');

    // Build line offset map for converting byte offsets to line numbers
    final lineOffsets = <int>[0];
    for (var i = 0; i < content.length; i++) {
      if (content[i] == '\n') {
        lineOffsets.add(i + 1);
      }
    }

    int offsetToLine(int offset) {
      for (var i = lineOffsets.length - 1; i >= 0; i--) {
        if (lineOffsets[i] <= offset) return i;
      }
      return 0;
    }

    final allMatches = pattern.allMatches(content).toList();
    var matchCount = 0;

    for (final match in allMatches) {
      if (maxPerFile != null && matchCount >= maxPerFile) break;
      matchCount++;

      final startLine = offsetToLine(match.start);
      final endLine = offsetToLine(match.end);
      final matchText = match.group(0) ?? '';

      // Get context
      final startCtx = (startLine - linesBefore).clamp(0, lines.length);
      final endCtx = (endLine + linesAfter + 1).clamp(0, lines.length);
      final context = onlyMatching ? const <String>[] : lines.sublist(startCtx, endCtx);

      final symbolContext = _findSymbolContext(path, startLine);

      results.add(
        GrepMatchData(
          file: path,
          line: startLine,
          column: match.start - lineOffsets[startLine],
          matchText: onlyMatching ? matchText : matchText,
          contextLines: context,
          contextBefore: startLine - startCtx,
          symbolContext: symbolContext,
          matchLineCount: endLine - startLine + 1,
        ),
      );
    }

    return results;
  }

  /// Find the symbol containing a line.
  String? _findSymbolContext(String path, int lineIdx) {
    final fileSymbols = symbolsInFile(path).toList();
    for (final sym in fileSymbols) {
      final def = findDefinition(sym.symbol);
      if (def != null &&
          def.line <= lineIdx &&
          (def.enclosingEndLine ?? def.line + 100) >= lineIdx) {
        return sym.name;
      }
    }
    return null;
  }

  /// Convert a simple glob pattern to a regex.
  RegExp _globToRegex(String glob) {
    final escaped = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final char = glob[i];
      switch (char) {
        case '*':
          escaped.write('.*');
        case '?':
          escaped.write('.');
        case '.':
        case '+':
        case '^':
        case r'$':
        case '(':
        case ')':
        case '[':
        case ']':
        case '{':
        case '}':
        case '|':
        case r'\':
          escaped.write(r'\');
          escaped.write(char);
        default:
          escaped.write(char);
      }
    }
    return RegExp(escaped.toString(), caseSensitive: false);
  }

  /// Get files that contain NO matches for the pattern.
  Future<List<String>> grepFilesWithoutMatch(
    RegExp pattern, {
    String? pathFilter,
    String? includeGlob,
    String? excludeGlob,
  }) async {
    final filesWithoutMatch = <String>[];

    final includeRegex = includeGlob != null ? _globToRegex(includeGlob) : null;
    final excludeRegex = excludeGlob != null ? _globToRegex(excludeGlob) : null;

    for (final path in _documentIndex.keys) {
      if (pathFilter != null && !path.startsWith(pathFilter)) continue;
      if (includeRegex != null && !includeRegex.hasMatch(path)) continue;
      if (excludeRegex != null && excludeRegex.hasMatch(path)) continue;

      final filePath = '$_projectRoot/$path';
      final file = File(filePath);
      if (!await file.exists()) continue;

      final content = await file.readAsString();
      if (!pattern.hasMatch(content)) {
        filesWithoutMatch.add(path);
      }
    }

    return filesWithoutMatch..sort();
  }

  /// Search for symbols using fuzzy matching.
  Iterable<SymbolInfo> findSymbolsFuzzy(
    String pattern, {
    int maxDistance = 2,
  }) {
    final patternLower = pattern.toLowerCase();

    return _symbolIndex.values.where((sym) {
      final nameLower = sym.name.toLowerCase();

      // Exact substring match
      if (nameLower.contains(patternLower)) return true;

      // Edit distance for short patterns
      if (pattern.length <= 10) {
        final distance = _levenshteinDistance(nameLower, patternLower);
        return distance <= maxDistance;
      }

      return false;
    });
  }

  /// Calculate Levenshtein edit distance.
  static int _levenshteinDistance(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    final matrix = List.generate(
      a.length + 1,
      (i) => List.generate(b.length + 1, (j) => 0),
    );

    for (var i = 0; i <= a.length; i++) {
      matrix[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      matrix[0][j] = j;
    }

    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        matrix[i][j] = [
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
    }

    return matrix[a.length][b.length];
  }

  // ═══════════════════════════════════════════════════════════════════════
  // QUALIFIED NAME LOOKUPS
  // ═══════════════════════════════════════════════════════════════════════

  /// Find symbols matching a qualified name like "MyClass.method".
  ///
  /// Returns symbols where the member name matches and the container
  /// (parent class/mixin/etc.) matches the specified container.
  Iterable<SymbolInfo> findQualified(String container, String member) {
    // First, find all symbols matching the member name
    final memberPattern = member
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');
    final memberRegex = RegExp(memberPattern, caseSensitive: false);

    final containerPattern = container
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');
    final containerRegex = RegExp(containerPattern, caseSensitive: false);

    return _symbolIndex.values.where((sym) {
      // Check if member name matches
      if (!memberRegex.hasMatch(sym.name)) return false;

      // Check if this symbol has a parent (container)
      final parentId = _extractParentSymbol(sym.symbol);
      if (parentId == null) return false;

      final parent = _symbolIndex[parentId];
      if (parent == null) return false;

      // Check if container matches
      return containerRegex.hasMatch(parent.name);
    });
  }

  /// Get the container (parent class/mixin/etc.) of a symbol.
  SymbolInfo? getContainer(String symbolId) {
    final parentId = _extractParentSymbol(symbolId);
    if (parentId == null) return null;
    return _symbolIndex[parentId];
  }

  /// Get the container name for a symbol.
  String? getContainerName(String symbolId) {
    return getContainer(symbolId)?.name;
  }

  /// Get detailed match info for disambiguation.
  List<({SymbolInfo symbol, String? container, OccurrenceInfo? definition})>
      getMatchesWithContext(String pattern) {
    final symbols = findSymbols(pattern);
    final results =
        <({SymbolInfo symbol, String? container, OccurrenceInfo? definition})>[];

    for (final sym in symbols) {
      final container = getContainerName(sym.symbol);
      final def = findDefinition(sym.symbol);
      results.add((symbol: sym, container: container, definition: def));
    }

    return results;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════════════

  /// Extract parent symbol from SCIP symbol string.
  ///
  /// SCIP symbols look like:
  /// `scip-dart pub my_package 1.0.0 lib/foo.dart/MyClass#myMethod().`
  ///
  /// For a method like `MyClass#myMethod().`, the parent is `MyClass#`.
  /// For a class like `lib/foo.dart/MyClass#`, the parent is `lib/foo.dart/` (the file).
  static String? _extractParentSymbol(String symbol) {
    final lastSlash = symbol.lastIndexOf('/');
    final lastHash = symbol.lastIndexOf('#');

    // Method of a class: Parent is everything up to and including #
    // e.g., `pkg/MyClass#method().` → `pkg/MyClass#`
    if (lastHash > lastSlash) {
      // Check if there's content after the #
      final afterHash = symbol.substring(lastHash + 1);
      if (afterHash.isNotEmpty) {
        // This is a member of the class, parent is the class
        return symbol.substring(0, lastHash + 1);
      }
    }

    // Class in a file: Parent is the file path
    // e.g., `pkg/MyClass#` → `pkg/` (or null if we only care about class members)
    // For now, we return null for top-level symbols (classes)
    return null;
  }
}

/// Information about a symbol (class, method, function, etc.)
class SymbolInfo {
  SymbolInfo({
    required this.symbol,
    required this.kind,
    required this.documentation,
    required this.relationships,
    required this.displayName,
    this.file,
  });

  factory SymbolInfo.fromScip(scip.SymbolInformation sym, {String? file}) {
    return SymbolInfo(
      symbol: sym.symbol,
      kind: sym.kind,
      documentation: sym.documentation,
      relationships: sym.relationships
          .map(
            (r) => RelationshipInfo(
              symbol: r.symbol,
              isReference: r.isReference,
              isImplementation: r.isImplementation,
              isTypeDefinition: r.isTypeDefinition,
              isDefinition: r.isDefinition,
            ),
          )
          .toList(),
      displayName: sym.displayName.isNotEmpty ? sym.displayName : null,
      file: file,
    );
  }

  final String symbol;
  final scip.SymbolInformation_Kind kind;
  final List<String> documentation;
  final List<RelationshipInfo> relationships;
  final String? displayName;
  final String? file;

  /// Extract the simple name from the symbol ID.
  String get name {
    if (displayName != null && displayName!.isNotEmpty) {
      return displayName!;
    }

    // Extract name from SCIP symbol
    // Format: scheme package version path/Class#method().
    // Also handles backtick-escaped names like `<get>files`.

    // Try to extract getter/setter name: `<get>name`. or `<set>name`.
    final getterMatch = RegExp(r'`<(get|set)>([^`]+)`\.?$').firstMatch(symbol);
    if (getterMatch != null) {
      return getterMatch.group(2)!;
    }

    // Try to extract constructor: `<constructor>`().
    final ctorMatch = RegExp(r'`<constructor>`\(\)\.?$').firstMatch(symbol);
    if (ctorMatch != null) {
      // Return the class name from before the #
      final classMatch = RegExp(r'/([A-Za-z_][A-Za-z0-9_]*)#').firstMatch(symbol);
      return classMatch?.group(1) ?? 'constructor';
    }

    // Try to extract backtick-escaped name: `name`.
    final backtickMatch = RegExp(r'`([^`]+)`\.?$').firstMatch(symbol);
    if (backtickMatch != null) {
      return backtickMatch.group(1)!;
    }

    // Standard name extraction
    final match = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)[\.\#\(\)\[\]]*$')
        .firstMatch(symbol);
    return match?.group(1) ?? symbol;
  }

  /// Whether this symbol is from an external package.
  bool get isExternal => file == null;

  /// Get a human-readable kind string.
  String get kindString {
    switch (kind) {
      case scip.SymbolInformation_Kind.Class:
        return 'class';
      case scip.SymbolInformation_Kind.Method:
        return 'method';
      case scip.SymbolInformation_Kind.Function:
        return 'function';
      case scip.SymbolInformation_Kind.Field:
        return 'field';
      case scip.SymbolInformation_Kind.Constructor:
        return 'constructor';
      case scip.SymbolInformation_Kind.Enum:
        return 'enum';
      case scip.SymbolInformation_Kind.EnumMember:
        return 'enumMember';
      case scip.SymbolInformation_Kind.Interface:
        return 'interface';
      case scip.SymbolInformation_Kind.Variable:
        return 'variable';
      case scip.SymbolInformation_Kind.Property:
        return 'property';
      case scip.SymbolInformation_Kind.Parameter:
        return 'parameter';
      case scip.SymbolInformation_Kind.Mixin:
        return 'mixin';
      case scip.SymbolInformation_Kind.Extension:
        return 'extension';
      case scip.SymbolInformation_Kind.Getter:
        return 'getter';
      case scip.SymbolInformation_Kind.Setter:
        return 'setter';
      default:
        return kind.name.toLowerCase();
    }
  }

  @override
  String toString() => 'SymbolInfo($name: $kindString)';
}

/// Information about a relationship between symbols.
class RelationshipInfo {
  RelationshipInfo({
    required this.symbol,
    required this.isReference,
    required this.isImplementation,
    required this.isTypeDefinition,
    required this.isDefinition,
  });

  final String symbol;
  final bool isReference;
  final bool isImplementation;
  final bool isTypeDefinition;
  final bool isDefinition;
}

/// Information about a symbol occurrence (definition or reference).
class OccurrenceInfo {
  OccurrenceInfo({
    required this.file,
    required this.symbol,
    required this.line,
    required this.column,
    required this.endLine,
    required this.endColumn,
    required this.isDefinition,
    this.enclosingEndLine,
  });

  factory OccurrenceInfo.fromScip(scip.Occurrence occ, {required String file}) {
    // SCIP range format: [startLine, startChar, endLine?, endChar]
    // If 3 elements: endLine = startLine
    final range = occ.range;
    final startLine = range.isNotEmpty ? range[0] : 0;
    final startChar = range.length > 1 ? range[1] : 0;
    final endLine = range.length > 3 ? range[2] : startLine;
    final endChar = range.length > 3 ? range[3] : (range.length > 2 ? range[2] : startChar);

    // Enclosing range (for definitions)
    final enclosing = occ.enclosingRange;
    final enclosingEnd = enclosing.length > 2 ? enclosing[2] : null;

    return OccurrenceInfo(
      file: file,
      symbol: occ.symbol,
      line: startLine,
      column: startChar,
      endLine: endLine,
      endColumn: endChar,
      isDefinition: (occ.symbolRoles & scip.SymbolRole.Definition.value) != 0,
      enclosingEndLine: enclosingEnd,
    );
  }

  final String file;
  final String symbol;
  final int line;
  final int column;
  final int endLine;
  final int endColumn;
  final bool isDefinition;
  final int? enclosingEndLine;

  /// Format as file:line:column.
  String get location => '$file:${line + 1}:${column + 1}';

  @override
  String toString() =>
      'OccurrenceInfo($location, ${isDefinition ? "def" : "ref"})';
}

/// Data for a grep match (used internally).
class GrepMatchData {
  const GrepMatchData({
    required this.file,
    required this.line,
    required this.column,
    required this.matchText,
    required this.contextLines,
    required this.contextBefore,
    this.symbolContext,
    this.matchLineCount = 1,
  });

  final String file;
  final int line;
  final int column;
  final String matchText;
  final List<String> contextLines;
  final int contextBefore;
  final String? symbolContext;

  /// Number of lines the match spans (for multiline matches).
  final int matchLineCount;
}

