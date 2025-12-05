import 'dart:io';

import 'package:collection/collection.dart';
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
  })  : _symbolIndex = symbolIndex,
        _referenceIndex = referenceIndex,
        _documentIndex = documentIndex,
        _childIndex = childIndex,
        _callsIndex = callsIndex,
        _callersIndex = callersIndex,
        _projectRoot = projectRoot;

  final Map<String, SymbolInfo> _symbolIndex;
  final Map<String, List<OccurrenceInfo>> _referenceIndex;
  final Map<String, scip.Document> _documentIndex;
  final Map<String, List<String>> _childIndex; // parent → children
  final Map<String, Set<String>> _callsIndex; // symbol → symbols it calls
  final Map<String, Set<String>> _callersIndex; // symbol → symbols that call it
  final String _projectRoot;

  /// Load index from a SCIP protobuf file.
  static Future<ScipIndex> loadFromFile(
    String indexPath, {
    required String projectRoot,
  }) async {
    final bytes = await File(indexPath).readAsBytes();
    final index = scip.Index.fromBuffer(bytes);
    return fromScipIndex(index, projectRoot: projectRoot);
  }

  /// Build index from SCIP protobuf data.
  static ScipIndex fromScipIndex(
    scip.Index raw, {
    required String projectRoot,
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
          ));
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
    );
  }

  /// Create an empty index.
  factory ScipIndex.empty({required String projectRoot}) {
    return ScipIndex._(
      symbolIndex: {},
      referenceIndex: {},
      documentIndex: {},
      childIndex: {},
      callsIndex: {},
      callersIndex: {},
      projectRoot: projectRoot,
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
        ));
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

    final filePath = '$_projectRoot/${def.file}';
    final file = File(filePath);
    if (!await file.exists()) return null;

    final lines = await file.readAsLines();
    final startLine = def.line;
    final endLine = def.enclosingEndLine ?? (startLine + 20);

    if (startLine >= lines.length) return null;

    return lines
        .sublist(startLine, endLine.clamp(0, lines.length))
        .join('\n');
  }

  /// Get source context around an occurrence.
  Future<String?> getContext(
    OccurrenceInfo occ, {
    int linesBefore = 2,
    int linesAfter = 2,
  }) async {
    final filePath = '$_projectRoot/${occ.file}';
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
  /// - [linesBefore]: Number of context lines before match (default 2)
  /// - [linesAfter]: Number of context lines after match (default 2)
  /// - [invertMatch]: If true, return lines that DON'T match
  /// - [maxPerFile]: Maximum matches per file (null for unlimited)
  Future<List<GrepMatchData>> grep(
    RegExp pattern, {
    String? pathFilter,
    int linesBefore = 2,
    int linesAfter = 2,
    bool invertMatch = false,
    int? maxPerFile,
  }) async {
    final results = <GrepMatchData>[];

    for (final path in _documentIndex.keys) {
      // Apply path filter
      if (pathFilter != null && !path.startsWith(pathFilter)) continue;

      final filePath = '$_projectRoot/$path';
      final file = File(filePath);
      if (!await file.exists()) continue;

      final content = await file.readAsString();
      final lines = content.split('\n');
      var fileMatchCount = 0;

      // Find all matches (or non-matches for -v)
      for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
        final line = lines[lineIdx];
        final hasMatch = pattern.hasMatch(line);

        // For invert match, we want lines that DON'T match
        final shouldInclude = invertMatch ? !hasMatch : hasMatch;
        if (!shouldInclude) continue;

        // Check max per file limit
        if (maxPerFile != null && fileMatchCount >= maxPerFile) break;
        fileMatchCount++;

        // Get context lines (separate before/after)
        final startCtx = (lineIdx - linesBefore).clamp(0, lines.length);
        final endCtx = (lineIdx + linesAfter + 1).clamp(0, lines.length);
        final context = lines.sublist(startCtx, endCtx);

        // For invert match, the "match" is the whole line
        final matchText = invertMatch ? line : _getFirstMatch(pattern, line);

        // Find containing symbol
        String? symbolContext;
        final fileSymbols = this.symbolsInFile(path).toList();
        for (final sym in fileSymbols) {
          final def = findDefinition(sym.symbol);
          if (def != null &&
              def.line <= lineIdx &&
              (def.enclosingEndLine ?? def.line + 100) >= lineIdx) {
            symbolContext = sym.name;
            break;
          }
        }

        results.add(
          GrepMatchData(
            file: path,
            line: lineIdx,
            column: invertMatch ? 0 : pattern.firstMatch(line)?.start ?? 0,
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

  /// Get the first match text from a line.
  String _getFirstMatch(RegExp pattern, String line) {
    final match = pattern.firstMatch(line);
    return match?.group(0) ?? line;
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
  static String? _extractParentSymbol(String symbol) {
    // Find the last descriptor marker
    final lastDot = symbol.lastIndexOf('.');
    final lastHash = symbol.lastIndexOf('#');
    final lastParen = symbol.lastIndexOf('(');
    final lastSlash = symbol.lastIndexOf('/');

    // Find the rightmost descriptor start that's after the file path
    final descriptorStarts = [lastDot, lastHash, lastParen]
        .where((i) => i > lastSlash && i > 0)
        .toList();

    if (descriptorStarts.isEmpty) return null;

    final cutPoint = descriptorStarts.reduce((a, b) => a > b ? a : b);

    // The parent is everything before the last descriptor
    // But we need to find the second-to-last descriptor
    final parentEnd = symbol.substring(0, cutPoint).lastIndexOf(
          RegExp(r'[.#(]'),
        );

    if (parentEnd <= lastSlash) return null;

    return symbol.substring(0, parentEnd + 1);
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
  });

  final String file;
  final int line;
  final int column;
  final String matchText;
  final List<String> contextLines;
  final int contextBefore;
  final String? symbolContext;
}

