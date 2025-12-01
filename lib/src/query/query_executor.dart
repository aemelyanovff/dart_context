import 'dart:io';

// ignore: implementation_imports
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;

import '../index/scip_index.dart';
import 'query_parser.dart';
import 'query_result.dart';

/// Executes queries against a ScipIndex.
class QueryExecutor {
  QueryExecutor(this.index);

  final ScipIndex index;

  /// Execute a query string and return the result.
  ///
  /// Supports pipe chaining: `find Auth* | refs` will find references
  /// for all symbols matching Auth*.
  Future<QueryResult> execute(String queryString) async {
    try {
      // Check for pipe chaining
      if (queryString.contains(' | ')) {
        return _executePipeline(queryString);
      }

      final query = ScipQuery.parse(queryString);
      return executeQuery(query);
    } on FormatException catch (e) {
      return ErrorResult(e.message);
    }
  }

  /// Execute a pipeline of queries separated by |.
  Future<QueryResult> _executePipeline(String queryString) async {
    final parts = queryString.split(' | ').map((s) => s.trim()).toList();
    if (parts.isEmpty) {
      return ErrorResult('Empty pipeline');
    }

    // Execute first query
    QueryResult currentResult = await execute(parts.first);

    // Process subsequent queries with results from previous
    for (var i = 1; i < parts.length; i++) {
      if (currentResult is ErrorResult || currentResult is NotFoundResult) {
        return currentResult; // Stop on error
      }

      final nextQuery = parts[i];
      currentResult = await _executePipeStep(currentResult, nextQuery);
    }

    return currentResult;
  }

  /// Execute a single pipe step with context from previous result.
  Future<QueryResult> _executePipeStep(
    QueryResult previousResult,
    String queryPart,
  ) async {
    // Extract symbols from previous result
    final symbols = _extractSymbols(previousResult);
    if (symbols.isEmpty) {
      return NotFoundResult('No symbols to pipe from previous query');
    }

    // Parse the next action
    final tokens = queryPart.split(' ');
    final action = tokens.first.toLowerCase();

    // Execute action for each symbol
    final results = <QueryResult>[];
    for (final sym in symbols) {
      final fullQuery = '$action ${sym.name}';
      try {
        final result = await execute(fullQuery);
        if (!result.isEmpty) {
          results.add(result);
        }
      } catch (_) {
        // Skip symbols that fail
      }
    }

    if (results.isEmpty) {
      return NotFoundResult('No results from piped query');
    }

    // Merge results based on type
    return _mergeResults(results, action);
  }

  /// Extract symbols from a query result.
  List<SymbolInfo> _extractSymbols(QueryResult result) {
    return switch (result) {
      SearchResult r => r.symbols,
      DefinitionResult r => r.definitions.map(_symbolFromDef).toList(),
      MembersResult r => r.members,
      HierarchyResult r => [...r.supertypes, ...r.subtypes],
      CallGraphResult r => r.connections,
      DependenciesResult r => r.dependencies,
      _ => <SymbolInfo>[],
    };
  }

  /// Convert a DefinitionMatch to SymbolInfo.
  SymbolInfo _symbolFromDef(DefinitionMatch def) {
    return def.symbol;
  }

  /// Merge multiple results into one.
  QueryResult _mergeResults(List<QueryResult> results, String action) {
    if (results.length == 1) return results.first;

    // Handle aggregation based on result type
    return switch (results.first) {
      ReferencesResult _ => _mergeReferences(results.cast<ReferencesResult>()),
      CallGraphResult _ => _mergeCallGraph(results.cast<CallGraphResult>()),
      SearchResult _ => _mergeSearch(results.cast<SearchResult>()),
      _ => PipelineResult(
          action: action,
          results: results,
        ),
    };
  }

  /// Merge multiple reference results.
  QueryResult _mergeReferences(List<ReferencesResult> results) {
    final allRefs = <ReferenceMatch>[];
    for (final r in results) {
      allRefs.addAll(r.references);
    }
    return ReferencesResult(
      symbol: results.first.symbol,
      references: allRefs,
    );
  }

  /// Merge multiple call graph results.
  QueryResult _mergeCallGraph(List<CallGraphResult> results) {
    final allConnections = <String, SymbolInfo>{};
    for (final r in results) {
      for (final conn in r.connections) {
        allConnections[conn.symbol] = conn;
      }
    }
    return CallGraphResult(
      symbol: results.first.symbol,
      direction: results.first.direction,
      connections: allConnections.values.toList(),
    );
  }

  /// Merge multiple search results.
  QueryResult _mergeSearch(List<SearchResult> results) {
    final allSymbols = <String, SymbolInfo>{};
    for (final r in results) {
      for (final sym in r.symbols) {
        allSymbols[sym.symbol] = sym;
      }
    }
    return SearchResult(allSymbols.values.toList());
  }

  /// Execute a parsed query.
  Future<QueryResult> executeQuery(ScipQuery query) async {
    return switch (query.action) {
      QueryAction.definition => _findDefinition(query),
      QueryAction.references => _findReferences(query),
      QueryAction.members => _findMembers(query),
      QueryAction.implementations => _findImplementations(query),
      QueryAction.supertypes => _findSupertypes(query),
      QueryAction.subtypes => _findSubtypes(query),
      QueryAction.hierarchy => _findHierarchy(query),
      QueryAction.source => _getSource(query),
      QueryAction.find => _search(query),
      QueryAction.which => _which(query),
      QueryAction.grep => _grep(query),
      QueryAction.calls => _findCalls(query),
      QueryAction.callers => _findCallers(query),
      QueryAction.imports => _findImports(query),
      QueryAction.exports => _findExports(query),
      QueryAction.deps => _findDeps(query),
      QueryAction.files => _listFiles(),
      QueryAction.stats => _getStats(),
    };
  }

  /// Find symbols based on query, supporting qualified names.
  List<SymbolInfo> _findMatchingSymbols(ScipQuery query) {
    if (query.isQualified) {
      // Qualified lookup: Class.member
      return index.findQualified(query.container!, query.memberName).toList();
    } else {
      // Regular lookup
      return index.findSymbols(query.target).toList();
    }
  }

  Future<QueryResult> _findDefinition(ScipQuery query) async {
    final allSymbols = _findMatchingSymbols(query);

    if (allSymbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    // Filter to primary definitions only (exclude parameters, local variables)
    final primaryKinds = {
      'class',
      'method',
      'function',
      'field',
      'constructor',
      'enum',
      'mixin',
      'extension',
      'getter',
      'setter',
      'property',
    };

    final primarySymbols = allSymbols
        .where((s) => primaryKinds.contains(s.kindString))
        .toList();

    // If we have primary symbols, use those; otherwise fall back to all
    final symbols = primarySymbols.isNotEmpty ? primarySymbols : allSymbols;

    // Sort by relevance: exact name match first, then by kind priority
    final targetName = query.memberName;
    symbols.sort((a, b) {
      final aExact = a.name.toLowerCase() == targetName.toLowerCase();
      final bExact = b.name.toLowerCase() == targetName.toLowerCase();
      if (aExact && !bExact) return -1;
      if (!aExact && bExact) return 1;

      // Prefer classes/functions over methods/fields
      final kindPriority = {
        'class': 0,
        'function': 1,
        'enum': 2,
        'mixin': 3,
        'extension': 4,
        'method': 5,
        'field': 6,
        'constructor': 7,
        'getter': 8,
        'setter': 9,
      };
      final aPriority = kindPriority[a.kindString] ?? 10;
      final bPriority = kindPriority[b.kindString] ?? 10;
      return aPriority.compareTo(bPriority);
    });

    // For def, only return the best match (or a few if same priority)
    final bestMatch = symbols.first;
    final bestMatches = symbols.where((s) {
      // Include symbols with same name and similar priority
      return s.name.toLowerCase() == bestMatch.name.toLowerCase() &&
          _isPrimaryKind(s.kindString);
    }).take(3); // Limit to top 3 matches

    final definitions = <DefinitionMatch>[];

    for (final sym in bestMatches) {
      final def = index.findDefinition(sym.symbol);
      if (def != null) {
        final source = await index.getSource(sym.symbol);
        definitions.add(
          DefinitionMatch(
            symbol: sym,
            location: def,
            source: source,
          ),
        );
      }
    }

    if (definitions.isEmpty) {
      return NotFoundResult(
        'Symbol "${query.target}" found but no definition available (may be external)',
      );
    }

    return DefinitionResult(definitions);
  }

  bool _isPrimaryKind(String kind) {
    return {
      'class',
      'method',
      'function',
      'enum',
      'mixin',
      'extension',
    }.contains(kind);
  }

  Future<QueryResult> _findReferences(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    // If qualified name used, we have a specific symbol
    if (query.isQualified && symbols.length == 1) {
      return _refsForSingleSymbol(symbols.first);
    }

    // If there's only one match, use it directly
    if (symbols.length == 1) {
      return _refsForSingleSymbol(symbols.first);
    }

    // Multiple matches - return aggregated results
    return _aggregatedRefs(query.target, symbols);
  }

  Future<QueryResult> _refsForSingleSymbol(SymbolInfo sym) async {
    final refs = index.findReferences(sym.symbol);

    final referenceMatches = <ReferenceMatch>[];
    for (final ref in refs) {
      final context = await index.getContext(ref);
      referenceMatches.add(
        ReferenceMatch(
          location: ref,
          context: context,
        ),
      );
    }

    return ReferencesResult(
      symbol: sym,
      references: referenceMatches,
    );
  }

  Future<QueryResult> _aggregatedRefs(
    String query,
    List<SymbolInfo> symbols,
  ) async {
    // Filter to primary kinds (avoid showing parameter/variable matches)
    final primarySymbols = symbols.where((s) {
      final kind = s.kindString;
      return kind == 'class' ||
          kind == 'method' ||
          kind == 'function' ||
          kind == 'field' ||
          kind == 'constructor' ||
          kind == 'getter' ||
          kind == 'setter';
    }).toList();

    final symbolsToUse = primarySymbols.isNotEmpty ? primarySymbols : symbols;
    final symbolRefs = <SymbolReferences>[];

    for (final sym in symbolsToUse.take(10)) {
      // Limit to 10 symbols
      final refs = index.findReferences(sym.symbol);
      final container = index.getContainerName(sym.symbol);

      final referenceMatches = <ReferenceMatch>[];
      for (final ref in refs) {
        final context = await index.getContext(ref);
        referenceMatches.add(
          ReferenceMatch(
            location: ref,
            context: context,
          ),
        );
      }

      symbolRefs.add(
        SymbolReferences(
          symbol: sym,
          references: referenceMatches,
          container: container,
        ),
      );
    }

    return AggregatedReferencesResult(
      query: query,
      symbolRefs: symbolRefs,
    );
  }

  Future<QueryResult> _findMembers(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query)
        .where(
          (s) =>
              s.kindString == 'class' ||
              s.kindString == 'mixin' ||
              s.kindString == 'extension' ||
              s.kindString == 'enum',
        )
        .toList();

    if (symbols.isEmpty) {
      return NotFoundResult(
        'No class/mixin/extension found matching "${query.target}"',
      );
    }

    final sym = symbols.first;
    final members = index.membersOf(sym.symbol).toList();

    return MembersResult(
      symbol: sym,
      members: members,
    );
  }

  Future<QueryResult> _findImplementations(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;
    final impls = index.findImplementations(sym.symbol).toList();

    return SearchResult(impls);
  }

  Future<QueryResult> _findSupertypes(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;
    final supertypes = index.supertypesOf(sym.symbol).toList();

    return HierarchyResult(
      symbol: sym,
      supertypes: supertypes,
      subtypes: const <SymbolInfo>[],
    );
  }

  Future<QueryResult> _findSubtypes(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;
    final subtypes = index.subtypesOf(sym.symbol).toList();

    return HierarchyResult(
      symbol: sym,
      supertypes: const <SymbolInfo>[],
      subtypes: subtypes,
    );
  }

  Future<QueryResult> _findHierarchy(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;
    final supertypes = index.supertypesOf(sym.symbol).toList();
    final subtypes = index.subtypesOf(sym.symbol).toList();

    return HierarchyResult(
      symbol: sym,
      supertypes: supertypes,
      subtypes: subtypes,
    );
  }

  Future<QueryResult> _getSource(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;
    final def = index.findDefinition(sym.symbol);

    if (def == null) {
      return NotFoundResult(
        'Symbol "${query.target}" has no definition (may be external)',
      );
    }

    final source = await index.getSource(sym.symbol);
    if (source == null) {
      return NotFoundResult('Could not read source for "${query.target}"');
    }

    return SourceResult(
      symbol: sym,
      source: source,
      file: def.file,
      startLine: def.line,
    );
  }

  Future<QueryResult> _search(ScipQuery query) async {
    final pattern = query.parsedPattern;
    Iterable<SymbolInfo> results;

    try {
      // Use appropriate search method based on pattern type
      if (pattern.type == PatternType.fuzzy) {
        // Fuzzy uses edit distance matching
        results = index.findSymbolsFuzzy(pattern.pattern);
      } else if (pattern.type == PatternType.regex) {
        // Regex searches all symbols
        final regex = pattern.toRegExp();
        results = index.allSymbols.where((sym) {
          return regex.hasMatch(sym.name) || regex.hasMatch(sym.symbol);
        });
      } else if (pattern.type == PatternType.glob) {
        // Glob uses the existing findSymbols
        results = index.findSymbols(query.target);
      } else {
        // Literal - exact match on name
        final regex = pattern.toRegExp();
        results = index.allSymbols.where((sym) {
          return regex.hasMatch(sym.name);
        });
      }
    } on FormatException catch (e) {
      return ErrorResult('Invalid pattern: ${e.message}');
    }

    // Apply kind filter
    final kind = query.kindFilter;
    if (kind != null) {
      results = results.where((s) => s.kind == kind);
    }

    // Apply path filter
    final pathFilter = query.pathFilter;
    if (pathFilter != null) {
      results = results.where(
        (s) => s.file != null && s.file!.startsWith(pathFilter),
      );
    }

    return SearchResult(results.toList());
  }

  /// Search in source code (like grep).
  Future<QueryResult> _grep(ScipQuery query) async {
    final pattern = query.parsedPattern;
    final regex = pattern.toRegExp();
    final contextLines = query.contextLines;
    final pathFilter = query.pathFilter;

    final matches = await index.grep(
      regex,
      pathFilter: pathFilter,
      contextLines: contextLines,
    );

    final grepMatches = matches.map((m) {
      return GrepMatch(
        file: m.file,
        line: m.line,
        column: m.column,
        matchText: m.matchText,
        contextLines: m.contextLines,
        contextBefore: m.contextBefore,
        symbolContext: m.symbolContext,
      );
    }).toList();

    return GrepResult(
      pattern: query.target,
      matches: grepMatches,
    );
  }

  /// Show all matches for a symbol (disambiguation).
  Future<QueryResult> _which(ScipQuery query) async {
    final matches = index.getMatchesWithContext(query.target);

    if (matches.isEmpty) {
      return NotFoundResult('No symbols found matching "${query.target}"');
    }

    final whichMatches = matches.map((m) {
      return WhichMatch(
        symbol: m.symbol,
        location: m.definition?.file ?? m.symbol.file,
        container: m.container,
        line: m.definition?.line,
      );
    }).toList();

    // Sort by kind priority, then by container name
    whichMatches.sort((a, b) {
      final kindPriority = {
        'class': 0,
        'function': 1,
        'enum': 2,
        'mixin': 3,
        'method': 4,
        'field': 5,
        'constructor': 6,
        'getter': 7,
        'setter': 8,
      };
      final aPriority = kindPriority[a.symbol.kindString] ?? 10;
      final bPriority = kindPriority[b.symbol.kindString] ?? 10;
      if (aPriority != bPriority) return aPriority.compareTo(bPriority);

      // Secondary sort by container (null last)
      if (a.container == null && b.container != null) return 1;
      if (a.container != null && b.container == null) return -1;
      if (a.container != null && b.container != null) {
        return a.container!.compareTo(b.container!);
      }
      return 0;
    });

    return WhichResult(
      query: query.target,
      matches: whichMatches,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CALL GRAPH QUERIES
  // ═══════════════════════════════════════════════════════════════════════

  /// Find what a symbol calls.
  Future<QueryResult> _findCalls(ScipQuery query) async {
    final sym = _resolveSymbol(query);
    if (sym == null) {
      return NotFoundResult('Symbol "${query.target}" not found');
    }

    final calls = index.getCalls(sym.symbol).toList();
    return CallGraphResult(
      symbol: sym,
      direction: 'calls',
      connections: calls,
    );
  }

  /// Find what calls a symbol.
  Future<QueryResult> _findCallers(ScipQuery query) async {
    final sym = _resolveSymbol(query);
    if (sym == null) {
      return NotFoundResult('Symbol "${query.target}" not found');
    }

    final callers = index.getCallers(sym.symbol).toList();
    return CallGraphResult(
      symbol: sym,
      direction: 'callers',
      connections: callers,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // IMPORTS/EXPORTS QUERIES
  // ═══════════════════════════════════════════════════════════════════════

  /// Find imports of a file.
  Future<QueryResult> _findImports(ScipQuery query) async {
    final filePath = query.target;
    final fullPath = '${index.projectRoot}/$filePath';

    final file = File(fullPath);
    if (!await file.exists()) {
      return NotFoundResult('File "$filePath" not found');
    }

    final content = await file.readAsString();
    final imports = <String>[];
    final exports = <String>[];

    // Parse import/export statements
    final importRegex = RegExp(r'''import\s+['"]([^'"]+)['"]''');
    final exportRegex = RegExp(r'''export\s+['"]([^'"]+)['"]''');

    for (final match in importRegex.allMatches(content)) {
      imports.add(match.group(1)!);
    }

    for (final match in exportRegex.allMatches(content)) {
      exports.add(match.group(1)!);
    }

    return ImportsResult(
      file: filePath,
      imports: imports,
      exports: exports,
    );
  }

  /// Find exports of a file or directory.
  Future<QueryResult> _findExports(ScipQuery query) async {
    final target = query.target;
    final fullPath = '${index.projectRoot}/$target';

    final entityType = FileSystemEntity.typeSync(fullPath);

    if (entityType == FileSystemEntityType.notFound) {
      return NotFoundResult('Path "$target" not found');
    }

    final exports = <String>[];

    if (entityType == FileSystemEntityType.file) {
      // Single file - get its exports
      final content = await File(fullPath).readAsString();
      final exportRegex = RegExp(r'''export\s+['"]([^'"]+)['"]''');
      for (final match in exportRegex.allMatches(content)) {
        exports.add(match.group(1)!);
      }
    } else {
      // Directory - list public symbols defined in it
      for (final file in index.files) {
        if (file.startsWith(target)) {
          final symbols = index.symbolsInFile(file);
          for (final sym in symbols) {
            // Only include top-level public symbols
            if (!sym.name.startsWith('_') && !sym.symbol.contains('#')) {
              exports.add('${sym.name} (${sym.kindString}) - $file');
            }
          }
        }
      }
    }

    return ImportsResult(
      file: target,
      imports: [], // Only exports for directory
      exports: exports,
    );
  }

  /// Find dependencies of a symbol.
  Future<QueryResult> _findDeps(ScipQuery query) async {
    final sym = _resolveSymbol(query);
    if (sym == null) {
      return NotFoundResult('Symbol "${query.target}" not found');
    }

    // Dependencies = what the symbol calls + types it uses
    final deps = <String, SymbolInfo>{};

    // Get direct calls
    for (final called in index.getCalls(sym.symbol)) {
      deps[called.symbol] = called;
    }

    // For classes, also include member dependencies
    if (sym.kind == scip.SymbolInformation_Kind.Class) {
      final children = index.getChildren(sym.symbol);
      for (final childId in children) {
        for (final called in index.getCalls(childId)) {
          deps[called.symbol] = called;
        }
      }
    }

    // Remove self-references and internal members
    deps.remove(sym.symbol);
    deps.removeWhere((id, _) => id.startsWith(sym.symbol));

    return DependenciesResult(
      symbol: sym,
      dependencies: deps.values.toList(),
    );
  }

  /// Helper to resolve a symbol from a query.
  SymbolInfo? _resolveSymbol(ScipQuery query) {
    List<SymbolInfo> symbols;

    if (query.isQualified) {
      symbols = index.findQualified(query.container!, query.memberName).toList();
    } else {
      symbols = index.findSymbols(query.target).toList();
    }

    if (symbols.isEmpty) return null;

    // Prefer exact name matches
    final targetName = query.isQualified ? query.memberName : query.target;
    final exact = symbols.where((s) => s.name == targetName).toList();
    if (exact.isNotEmpty) return exact.first;

    return symbols.first;
  }

  Future<QueryResult> _listFiles() async {
    return FilesResult(index.files.toList()..sort());
  }

  Future<QueryResult> _getStats() async {
    return StatsResult(index.stats);
  }
}
