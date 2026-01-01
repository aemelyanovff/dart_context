import 'dart:io';

// ignore: implementation_imports
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;

import '../index/index_provider.dart';
import '../index/scip_index.dart';
import 'query_parser.dart';
import 'query_result.dart';

/// Executes DSL queries against a ScipIndex.
///
/// The executor parses query strings and returns structured [QueryResult] objects.
///
/// ## Usage
///
/// ```dart
/// final executor = QueryExecutor(index);
///
/// // Execute string queries
/// final result = await executor.execute('def MyClass');
/// print(result.toText());
///
/// // Execute parsed queries
/// final query = ScipQuery.parse('refs login kind:method');
/// final result = await executor.executeQuery(query);
/// print(result.toJson());
/// ```
///
/// ## Pipe Queries
///
/// Queries can be chained with `|` to pass results between stages:
///
/// ```dart
/// // Find all Auth classes, then get their members
/// final result = await executor.execute('find Auth* kind:class | members');
/// ```
///
/// ## Error Handling
///
/// Invalid queries return [ErrorResult], not found symbols return [NotFoundResult].
/// Always check `result.isEmpty` or use pattern matching:
///
/// ```dart
/// final result = await executor.execute('def NonExistent');
/// if (result is NotFoundResult) {
///   print('Symbol not found');
/// }
/// ```
/// Function type for getting signatures from the analyzer.
typedef SignatureProvider = Future<String?> Function(String symbolId);

class QueryExecutor {
  QueryExecutor(
    this.index, {
    this.signatureProvider,
    this.provider,
  });

  final ScipIndex index;

  /// Optional provider for generating signatures using the analyzer.
  /// If not provided, `sig` queries will fall back to extracting
  /// signatures from source code heuristically.
  final SignatureProvider? signatureProvider;

  /// Optional provider for cross-package queries.
  /// When provided, hierarchy queries (supertypes, subtypes, hierarchy, members)
  /// will search across loaded external indexes (SDK, packages).
  final IndexProvider? provider;

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
    final actionStr = tokens.first.toLowerCase();
    
    // Parse action
    final action = _parseAction(actionStr);
    if (action == null) {
      return ErrorResult('Unknown action in pipe: $actionStr');
    }

    // Execute action directly for each symbol (no re-parsing)
    final results = <QueryResult>[];
    for (final sym in symbols) {
      try {
        final result = await _executeForSymbol(action, sym);
        if (result != null && !result.isEmpty) {
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
    return _mergeResults(results, actionStr);
  }

  /// Parse action string, returning null if unknown.
  QueryAction? _parseAction(String action) {
    return switch (action) {
      'def' || 'definition' => QueryAction.definition,
      'refs' || 'references' => QueryAction.references,
      'members' => QueryAction.members,
      'impls' || 'implementations' => QueryAction.implementations,
      'supertypes' || 'super' => QueryAction.supertypes,
      'subtypes' || 'sub' => QueryAction.subtypes,
      'hierarchy' => QueryAction.hierarchy,
      'source' || 'src' => QueryAction.source,
      'sig' || 'signature' => QueryAction.signature,
      'calls' || 'callees' => QueryAction.calls,
      'callers' || 'calledby' => QueryAction.callers,
      'deps' || 'dependencies' => QueryAction.deps,
      _ => null,
    };
  }

  /// Execute an action directly for a symbol (used in piping).
  /// Returns null if the action doesn't support direct symbol input.
  Future<QueryResult?> _executeForSymbol(
    QueryAction action,
    SymbolInfo sym,
  ) async {
    return switch (action) {
      QueryAction.definition => _definitionForSymbol(sym),
      QueryAction.references => _refsForSingleSymbol(sym),
      QueryAction.members => _membersForSymbol(sym),
      QueryAction.implementations => _implementationsForSymbol(sym),
      QueryAction.supertypes => _supertypesForSymbol(sym),
      QueryAction.subtypes => _subtypesForSymbol(sym),
      QueryAction.hierarchy => _hierarchyForSymbol(sym),
      QueryAction.source => _sourceForSymbol(sym),
      QueryAction.signature => _signatureForSymbol(sym),
      QueryAction.calls => _callsForSymbol(sym),
      QueryAction.callers => _callersForSymbol(sym),
      QueryAction.deps => _depsForSymbol(sym),
      _ => null, // Actions like find, grep, files, stats don't take symbol input
    };
  }

  /// Get definition for a specific symbol.
  ///
  /// Uses [registry] for cross-package definition lookup when available.
  Future<QueryResult> _definitionForSymbol(SymbolInfo sym) async {
    // Try registry first for cross-package support
    OccurrenceInfo? def;
    String? source;

    if (provider != null) {
      def = provider!.findDefinition(sym.symbol);
      if (def != null) {
        source = await provider!.getSource(sym.symbol);
      }
    } else {
      def = index.findDefinition(sym.symbol);
      if (def != null) {
        source = await index.getSource(sym.symbol);
      }
    }

    if (def == null) {
      return NotFoundResult(
        'Symbol "${sym.name}" found but no definition available (may be external)',
      );
    }

    return DefinitionResult([
      DefinitionMatch(symbol: sym, location: def, source: source),
    ]);
  }

  /// Get members for a specific symbol.
  /// Uses [registry] for cross-package lookups when available.
  Future<QueryResult> _membersForSymbol(SymbolInfo sym) async {
    if (sym.kindString != 'class' &&
        sym.kindString != 'mixin' &&
        sym.kindString != 'extension' &&
        sym.kindString != 'enum') {
      return NotFoundResult('${sym.name} is not a class/mixin/extension/enum');
    }

    // Use registry for cross-package lookup if available
    final allMembers = provider != null
        ? provider!.membersOf(sym.symbol)
        : index.membersOf(sym.symbol).toList();

    // Filter out parameters - they are indexed as children but aren't class members
    final members = allMembers
        .where((m) => m.kindString != 'parameter')
        .toList();

    return MembersResult(symbol: sym, members: members);
  }

  /// Get implementations for a specific symbol.
  ///
  /// Uses [registry] for cross-package lookups when available.
  Future<QueryResult> _implementationsForSymbol(SymbolInfo sym) async {
    // Use registry for cross-package lookup if available
    final impls = provider != null
        ? provider!.subtypesOf(sym.symbol)
        : index.findImplementations(sym.symbol).toList();
    return SearchResult(impls);
  }

  /// Get supertypes for a specific symbol.
  /// Uses [registry] for cross-package lookups when available.
  Future<QueryResult> _supertypesForSymbol(SymbolInfo sym) async {
    // Use registry for cross-package lookup if available
    final supertypes = provider != null
        ? provider!.supertypesOf(sym.symbol)
        : index.supertypesOf(sym.symbol).toList();
    return HierarchyResult(
      symbol: sym,
      supertypes: supertypes,
      subtypes: const <SymbolInfo>[],
    );
  }

  /// Get subtypes for a specific symbol.
  /// Uses [registry] for cross-package lookups when available.
  Future<QueryResult> _subtypesForSymbol(SymbolInfo sym) async {
    // Use registry for cross-package lookup if available
    final subtypes = provider != null
        ? provider!.subtypesOf(sym.symbol)
        : index.subtypesOf(sym.symbol).toList();
    return HierarchyResult(
      symbol: sym,
      supertypes: const <SymbolInfo>[],
      subtypes: subtypes,
    );
  }

  /// Get full hierarchy for a specific symbol.
  /// Uses [registry] for cross-package lookups when available.
  Future<QueryResult> _hierarchyForSymbol(SymbolInfo sym) async {
    // Use registry for cross-package lookup if available
    final supertypes = provider != null
        ? provider!.supertypesOf(sym.symbol)
        : index.supertypesOf(sym.symbol).toList();
    final subtypes = provider != null
        ? provider!.subtypesOf(sym.symbol)
        : index.subtypesOf(sym.symbol).toList();
    return HierarchyResult(
      symbol: sym,
      supertypes: supertypes,
      subtypes: subtypes,
    );
  }

  /// Get source for a specific symbol.
  ///
  /// Uses [registry] for cross-package source access when available.
  Future<QueryResult> _sourceForSymbol(SymbolInfo sym) async {
    // Try registry first for cross-package support
    OccurrenceInfo? def;
    String? source;

    if (provider != null) {
      def = provider!.findDefinition(sym.symbol);
      if (def != null) {
        source = await provider!.getSource(sym.symbol);
      }
    } else {
      def = index.findDefinition(sym.symbol);
      if (def != null) {
        source = await index.getSource(sym.symbol);
      }
    }

    if (def == null) {
      return NotFoundResult(
        'Symbol "${sym.name}" has no definition',
      );
    }

    if (source == null) {
      return NotFoundResult('Could not read source for "${sym.name}"');
    }

    return SourceResult(
      symbol: sym,
      source: source,
      file: def.file,
      startLine: def.line,
    );
  }

  /// Get signature for a specific symbol.
  ///
  /// Uses [registry] for cross-package signature access when available.
  Future<QueryResult> _signatureForSymbol(SymbolInfo sym) async {
    // Try registry first for cross-package support
    OccurrenceInfo? def;
    if (provider != null) {
      def = provider!.findDefinition(sym.symbol);
    } else {
      def = index.findDefinition(sym.symbol);
    }

    if (def == null) {
      return NotFoundResult(
        'Symbol "${sym.name}" has no definition',
      );
    }

    String? signature;
    if (signatureProvider != null) {
      signature = await signatureProvider!(sym.symbol);
    }

    signature ??= await _extractSignatureFromSource(sym, def);

    if (signature == null) {
      return NotFoundResult('Could not extract signature for "${sym.name}"');
    }

    return SignatureResult(
      symbol: sym,
      signature: signature,
      file: def.file,
      line: def.line,
    );
  }

  /// Get calls for a specific symbol.
  ///
  /// Uses [registry] for cross-package call graph when available.
  Future<QueryResult> _callsForSymbol(SymbolInfo sym) async {
    final calls = provider != null
        ? provider!.getCalls(sym.symbol)
        : index.getCalls(sym.symbol).toList();
    return CallGraphResult(
      symbol: sym,
      direction: 'calls',
      connections: calls,
    );
  }

  /// Get callers for a specific symbol.
  ///
  /// Uses [registry] for cross-package call graph when available.
  /// For workspace mode (with local packages), uses name-based search
  /// to handle different symbol IDs across packages.
  Future<QueryResult> _callersForSymbol(SymbolInfo sym) async {
    List<SymbolInfo> callers;

    // If we have a registry with local indexes (workspace mode), use name-based search
    if (provider != null && provider!.localIndexes.isNotEmpty) {
      callers = provider!.findAllCallersByName(sym.name);
    } else if (provider != null) {
      callers = provider!.getCallers(sym.symbol);
    } else {
      callers = index.getCallers(sym.symbol).toList();
    }

    return CallGraphResult(
      symbol: sym,
      direction: 'callers',
      connections: callers,
    );
  }

  /// Get dependencies for a specific symbol.
  ///
  /// Uses [registry] for cross-package call graph when available.
  Future<QueryResult> _depsForSymbol(SymbolInfo sym) async {
    final deps = <String, SymbolInfo>{};

    // Get calls from all indexes
    final calls = provider != null
        ? provider!.getCalls(sym.symbol)
        : index.getCalls(sym.symbol).toList();

    for (final called in calls) {
      deps[called.symbol] = called;
    }

    if (sym.kind == scip.SymbolInformation_Kind.Class) {
      final children = index.getChildren(sym.symbol);
      for (final childId in children) {
        final childCalls = provider != null
            ? provider!.getCalls(childId)
            : index.getCalls(childId).toList();
        for (final called in childCalls) {
          deps[called.symbol] = called;
        }
      }
    }

    deps.remove(sym.symbol);
    deps.removeWhere((id, _) => id.startsWith(sym.symbol));

    return DependenciesResult(
      symbol: sym,
      dependencies: deps.values.toList(),
    );
  }

  /// Extract symbols from a query result.
  List<SymbolInfo> _extractSymbols(QueryResult result) {
    return switch (result) {
      SearchResult r => r.symbols,
      DefinitionResult r => r.definitions.map(_symbolFromDef).toList(),
      MembersResult r => r.members,
      HierarchyResult r => [...r.supertypes, ...r.subtypes],
      CallGraphResult r => [r.symbol, ...r.connections],
      DependenciesResult r => [r.symbol, ...r.dependencies],
      ReferencesResult r => [r.symbol],
      AggregatedReferencesResult r => r.symbolRefs.map((sr) => sr.symbol).toList(),
      WhichResult r => r.matches.map((m) => m.symbol).toList(),
      GrepResult r => r.symbols, // Symbols containing grep matches
      ImportsResult r => [...r.importedSymbols, ...r.exportedSymbols],
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
      QueryAction.signature => _getSignatureResult(query),
      QueryAction.symbols => _listSymbolsInFile(query),
      QueryAction.get => _getByScipId(query),
      QueryAction.files => _listFiles(),
      QueryAction.stats => _getStats(),
    };
  }

  /// Find symbols based on query, supporting qualified names.
  ///
  /// Searches in the project index first, then in external indexes
  /// (SDK, packages) if a registry is available.
  List<SymbolInfo> _findMatchingSymbols(ScipQuery query) {
    List<SymbolInfo> sorted0(List<SymbolInfo> symbols) {
      const priority = {
        'class': 0,
        'mixin': 0,
        'enum': 0,
        'extension': 0,
        'typealias': 1,
        'function': 2,
        'method': 3,
        'constructor': 4,
        'getter': 5,
        'setter': 5,
        'property': 6,
        'field': 6,
        'variable': 7,
        'parameter': 8,
        'local': 9,
      };

      int kindPriority(SymbolInfo s) => priority[s.kindString] ?? 50;

      // Prefer project symbols over external when priority ties
      bool isProject(SymbolInfo s) =>
          provider == null || provider!.projectIndex.getSymbol(s.symbol) != null;

      final sorted = [...symbols];
      sorted.sort((a, b) {
        final pa = kindPriority(a);
        final pb = kindPriority(b);
        if (pa != pb) return pa - pb;
        // Prefer project symbols when kinds tie
        final projA = isProject(a);
        final projB = isProject(b);
        if (projA != projB) return projA ? -1 : 1;
        return a.name.compareTo(b.name);
      });
      return sorted;
    }

    if (query.isQualified) {
      // Qualified lookup: Class.member
      if (provider != null) {
        return sorted0(
          provider!.findQualified(query.container!, query.memberName).toList(),
        );
      }
      return sorted0(
        index.findQualified(query.container!, query.memberName).toList(),
      );
    } else {
      // Regular lookup - search project first, then external packages
      final results = index.findSymbols(query.target).toList();

      // Also search in registry if available (for cross-package queries)
      if (provider != null) {
        final externalResults = provider!.findSymbols(query.target);
        // Add external results that aren't already in the project results
        final projectSymbols = results.map((s) => s.symbol).toSet();
        for (final sym in externalResults) {
          if (!projectSymbols.contains(sym.symbol)) {
            results.add(sym);
          }
        }
      }

      return sorted0(results);
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

  /// Find references for a single symbol.
  ///
  /// Uses [registry] for cross-package reference search when available.
  /// For workspace mode (with local packages), searches by symbol name
  /// to handle different symbol IDs across packages.
  Future<QueryResult> _refsForSingleSymbol(SymbolInfo sym) async {
    final referenceMatches = <ReferenceMatch>[];

    // If we have a registry with local indexes (workspace mode), use name-based search
    if (provider != null && provider!.localIndexes.isNotEmpty) {
      // Use name-based search for workspace cross-package queries
      final results = provider!.findAllReferencesByName(
        sym.name,
        symbolKind: sym.kindString,
      );

      // Deduplicate by sourceRoot+file+line
      final seen = <String>{};
      for (final result in results) {
        final key = '${result.sourceRoot}/${result.ref.file}:${result.ref.line}';
        if (seen.contains(key)) continue;
        seen.add(key);

        // Get context - need to resolve full path
        String? context;
        final fullPath = '${result.sourceRoot}/${result.ref.file}';
        final file = File(fullPath);
        if (await file.exists()) {
          final lines = await file.readAsLines();
          final start = (result.ref.line - 2).clamp(0, lines.length);
          final end = (result.ref.line + 3).clamp(0, lines.length);
          context = lines.sublist(start, end).join('\n');
        }

        referenceMatches.add(
          ReferenceMatch(
            location: result.ref,
            context: context,
            sourceRoot: result.sourceRoot,
          ),
        );
      }
    } else {
      // Standard mode - use exact symbol ID matching
      final allRefs = <OccurrenceInfo>[];

      // Get direct references to this symbol from all indexes
      if (provider != null) {
        allRefs.addAll(provider!.findAllReferences(sym.symbol));
      } else {
        allRefs.addAll(index.findReferences(sym.symbol));
      }

      // For classes, also include constructor call references
      if (sym.kindString == 'class') {
        final constructors = provider != null
            ? provider!.membersOf(sym.symbol).where(
                  (m) => m.kindString == 'constructor',
                )
            : index.membersOf(sym.symbol).where(
                  (m) => m.kindString == 'constructor',
                );
        for (final ctor in constructors) {
          if (provider != null) {
            allRefs.addAll(provider!.findAllReferences(ctor.symbol));
          } else {
            allRefs.addAll(index.findReferences(ctor.symbol));
          }
        }
      }

      // Deduplicate by file+line
      final seen = <String>{};
      final uniqueRefs = allRefs.where((ref) {
        final key = '${ref.file}:${ref.line}';
        if (seen.contains(key)) return false;
        seen.add(key);
        return true;
      }).toList();

      for (final ref in uniqueRefs) {
        String? context;
        if (provider != null) {
          for (final idx in provider!.allIndexes) {
            if (idx.files.contains(ref.file)) {
              context = await idx.getContext(ref);
              break;
            }
          }
        } else {
          context = await index.getContext(ref);
        }

        referenceMatches.add(
          ReferenceMatch(
            location: ref,
            context: context,
          ),
        );
      }
    }

    return ReferencesResult(
      symbol: sym,
      references: referenceMatches,
    );
  }

  /// Find aggregated references for multiple symbols.
  ///
  /// Uses [registry] for cross-package reference search when available.
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
      // Get references from all indexes
      final refs = provider != null
          ? provider!.findAllReferences(sym.symbol)
          : index.findReferences(sym.symbol).toList();
      final container = index.getContainerName(sym.symbol);

      final referenceMatches = <ReferenceMatch>[];
      for (final ref in refs) {
        // Get context from the appropriate index
        String? context;
        if (provider != null) {
          for (final idx in provider!.allIndexes) {
            if (idx.files.contains(ref.file)) {
              context = await idx.getContext(ref);
              break;
            }
          }
        } else {
          context = await index.getContext(ref);
        }

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
    // Use registry for cross-package lookup if available
    final allMembers = provider != null
        ? provider!.membersOf(sym.symbol)
        : index.membersOf(sym.symbol).toList();

    // Filter out parameters - they are indexed as children but aren't class members
    final members = allMembers
        .where((m) => m.kindString != 'parameter')
        .toList();

    return MembersResult(
      symbol: sym,
      members: members,
    );
  }

  /// Find implementations for a symbol.
  ///
  /// Uses [registry] for cross-package lookups when available.
  Future<QueryResult> _findImplementations(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;
    // Use registry for cross-package lookup if available
    final impls = provider != null
        ? provider!.subtypesOf(sym.symbol)
        : index.findImplementations(sym.symbol).toList();

    return SearchResult(impls);
  }

  Future<QueryResult> _findSupertypes(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;
    // Use registry for cross-package lookup if available
    final supertypes = provider != null
        ? provider!.supertypesOf(sym.symbol)
        : index.supertypesOf(sym.symbol).toList();

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
    // Use registry for cross-package lookup if available
    final subtypes = provider != null
        ? provider!.subtypesOf(sym.symbol)
        : index.subtypesOf(sym.symbol).toList();

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
    // Use registry for cross-package lookup if available
    final supertypes = provider != null
        ? provider!.supertypesOf(sym.symbol)
        : index.supertypesOf(sym.symbol).toList();
    final subtypes = provider != null
        ? provider!.subtypesOf(sym.symbol)
        : index.subtypesOf(sym.symbol).toList();

    return HierarchyResult(
      symbol: sym,
      supertypes: supertypes,
      subtypes: subtypes,
    );
  }

  /// Get source code for a symbol.
  ///
  /// Uses [registry] for cross-package source access when available.
  Future<QueryResult> _getSource(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;

    // Try registry first for cross-package support
    OccurrenceInfo? def;
    String? source;

    if (provider != null) {
      def = provider!.findDefinition(sym.symbol);
      if (def != null) {
        source = await provider!.getSource(sym.symbol);
      }
    } else {
      def = index.findDefinition(sym.symbol);
      if (def != null) {
        source = await index.getSource(sym.symbol);
      }
    }

    if (def == null) {
      return NotFoundResult(
        'Symbol "${query.target}" has no definition',
      );
    }

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

  /// Get signature for a symbol (declaration without body).
  ///
  /// Uses [registry] for cross-package signature access when available.
  Future<QueryResult> _getSignatureResult(ScipQuery query) async {
    final symbols = _findMatchingSymbols(query);

    if (symbols.isEmpty) {
      return NotFoundResult('No symbol found matching "${query.target}"');
    }

    final sym = symbols.first;

    // Try registry first for cross-package support
    OccurrenceInfo? def;
    if (provider != null) {
      def = provider!.findDefinition(sym.symbol);
    } else {
      def = index.findDefinition(sym.symbol);
    }

    if (def == null) {
      return NotFoundResult(
        'Symbol "${query.target}" has no definition',
      );
    }

    // Try using the signature provider (analyzer-based) first
    String? signature;
    if (signatureProvider != null) {
      signature = await signatureProvider!(sym.symbol);
    }

    // Fallback: extract from source heuristically
    signature ??= await _extractSignatureFromSource(sym, def);

    if (signature == null) {
      return NotFoundResult('Could not extract signature for "${query.target}"');
    }

    return SignatureResult(
      symbol: sym,
      signature: signature,
      file: def.file,
      line: def.line,
    );
  }

  /// Extract signature from source code heuristically (fallback).
  ///
  /// Uses [registry] for cross-package source access when available.
  Future<String?> _extractSignatureFromSource(
    SymbolInfo sym,
    OccurrenceInfo def,
  ) async {
    final source = provider != null
        ? await provider!.getSource(sym.symbol)
        : await index.getSource(sym.symbol);
    if (source == null) return null;

    final lines = source.split('\n');
    if (lines.isEmpty) return null;

    final kind = sym.kind;

    // For classes/enums/mixins - extract declaration + " { ... }"
    if (kind == scip.SymbolInformation_Kind.Class ||
        kind == scip.SymbolInformation_Kind.Enum ||
        kind == scip.SymbolInformation_Kind.Mixin ||
        kind == scip.SymbolInformation_Kind.Extension) {
      // Find the opening brace
      final fullSource = lines.join('\n');
      final braceIndex = fullSource.indexOf('{');
      if (braceIndex != -1) {
        return '${fullSource.substring(0, braceIndex + 1)} ... }';
      }
      return '${lines.first} { ... }';
    }

    // For methods/functions - extract up to the body
    if (kind == scip.SymbolInformation_Kind.Method ||
        kind == scip.SymbolInformation_Kind.Function ||
        kind == scip.SymbolInformation_Kind.Constructor) {
      final buffer = StringBuffer();
      var foundCloseParen = false;

      for (final line in lines) {
        for (var i = 0; i < line.length; i++) {
          final char = line[i];

          if (char == ')') {
            foundCloseParen = true;
          }

          // Stop at body start
          if (foundCloseParen) {
            if (char == '{' ||
                (char == '=' && i + 1 < line.length && line[i + 1] == '>')) {
              return buffer.toString().trim();
            }
            if (char == ';') {
              buffer.write(char);
              return buffer.toString().trim();
            }
          }

          buffer.write(char);
        }
        buffer.write('\n');
      }
      return buffer.toString().trim();
    }

    // For getters/setters
    if (kind == scip.SymbolInformation_Kind.Getter ||
        kind == scip.SymbolInformation_Kind.Setter) {
      final line = lines.first;
      final arrowIndex = line.indexOf('=>');
      final braceIndex = line.indexOf('{');

      if (arrowIndex != -1 && (braceIndex == -1 || arrowIndex < braceIndex)) {
        return line.substring(0, arrowIndex).trim();
      }
      if (braceIndex != -1) {
        return line.substring(0, braceIndex).trim();
      }
    }

    // Default: return first line
    return lines.first.trim();
  }

  Future<QueryResult> _search(ScipQuery query) async {
    final pattern = query.parsedPattern;
    final projectResults = <SymbolInfo>[];
    final externalResults = <SymbolInfo>[];

    // Get all local indexes to search
    // When registry is available, use its local indexes (which already includes
    // the project index). Otherwise, just use the standalone index.
    final allLocalIndexes = provider != null
        ? provider!.localIndexes.values.toList()
        : <ScipIndex>[index];

    try {
      // Use appropriate search method based on pattern type
      if (pattern.type == PatternType.fuzzy) {
        // Fuzzy uses edit distance matching
        for (final idx in allLocalIndexes) {
          projectResults.addAll(idx.findSymbolsFuzzy(pattern.pattern));
        }
        // Note: fuzzy search not implemented for registry external indexes yet
      } else if (pattern.type == PatternType.regex) {
        // Regex searches all symbols
        final regex = pattern.toRegExp();
        // Search all local indexes (project + workspace packages)
        for (final idx in allLocalIndexes) {
          projectResults.addAll(idx.allSymbols.where((sym) {
            return regex.hasMatch(sym.name) || regex.hasMatch(sym.symbol);
          }),);
        }
        // Also search in all external packages (SDK, hosted, Flutter, git)
        if (provider != null) {
          for (final idx in provider!.allExternalIndexes) {
            externalResults.addAll(idx.allSymbols.where((sym) {
              return regex.hasMatch(sym.name) || regex.hasMatch(sym.symbol);
            }),);
          }
        }
      } else if (pattern.type == PatternType.glob) {
        // Glob uses the existing findSymbols
        for (final idx in allLocalIndexes) {
          projectResults.addAll(idx.findSymbols(query.target));
        }
        // Also search in external packages only (local already searched above)
        if (provider != null) {
          for (final idx in provider!.allExternalIndexes) {
            externalResults.addAll(idx.findSymbols(query.target));
          }
        }
      } else {
        // Literal - exact match on name
        final regex = pattern.toRegExp();
        // Search all local indexes
        for (final idx in allLocalIndexes) {
          projectResults.addAll(idx.allSymbols.where((sym) {
            return regex.hasMatch(sym.name);
          }),);
        }
        // Also search in all external packages (SDK, hosted, Flutter, git)
        if (provider != null) {
          for (final idx in provider!.allExternalIndexes) {
            externalResults.addAll(idx.allSymbols.where((sym) {
              return regex.hasMatch(sym.name);
            }),);
          }
        }
      }
    } on FormatException catch (e) {
      return ErrorResult('Invalid pattern: ${e.message}');
    }

    // Combine results, avoiding duplicates
    final projectSymbols = projectResults.map((s) => s.symbol).toSet();
    final allResults = <SymbolInfo>[
      ...projectResults,
      ...externalResults.where((s) => !projectSymbols.contains(s.symbol)),
    ];

    Iterable<SymbolInfo> results = allResults;

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

    // Build the regex pattern
    String regexPattern;
    bool caseSensitive = pattern.caseSensitive;

    if (query.fixedStrings) {
      // -F: Treat pattern as literal string
      regexPattern = RegExp.escape(query.target);
    } else if (query.wordBoundary) {
      // -w: Wrap pattern in word boundaries
      regexPattern = r'\b' + pattern.pattern + r'\b';
    } else {
      regexPattern = pattern.type == PatternType.regex
          ? pattern.pattern
          : pattern.toRegExp().pattern;
    }

    // Handle multiline flag
    final regex = RegExp(
      regexPattern,
      caseSensitive: caseSensitive,
      multiLine: query.multiline,
      dotAll: query.multiline, // Make . match newlines in multiline mode
    );

    final pathFilter = query.pathFilter;

    // Handle -L (files without match)
    if (query.filesWithoutMatch) {
      final files = await index.grepFilesWithoutMatch(
        regex,
        pathFilter: pathFilter,
        includeGlob: query.includeGlob,
        excludeGlob: query.excludeGlob,
      );
      return GrepFilesResult(
        pattern: query.target,
        files: files,
        isWithoutMatch: true,
      );
    }

    // Use index directly for now (provider.grep has type mismatch issues)
    // TODO: Unify grep types in index and provider
    final matches = await index.grep(
      regex,
      pathFilter: pathFilter,
      includeGlob: query.includeGlob,
      excludeGlob: query.excludeGlob,
      linesBefore: query.linesBefore,
      linesAfter: query.linesAfter,
      invertMatch: query.invertMatch,
      maxPerFile: query.maxCount,
      multiline: query.multiline,
      onlyMatching: query.onlyMatching,
    );

    // Handle files-only output (-l)
    if (query.filesOnly) {
      final files = matches.map((m) => m.file).toSet().toList()..sort();
      return GrepFilesResult(
        pattern: query.target,
        files: files,
      );
    }

    // Handle count-only output (-c)
    if (query.countOnly) {
      final counts = <String, int>{};
      for (final match in matches) {
        counts[match.file] = (counts[match.file] ?? 0) + 1;
      }
      return GrepCountResult(
        pattern: query.target,
        fileCounts: counts,
      );
    }

    final grepMatches = matches.map((m) {
      return GrepMatch(
        file: m.file,
        line: m.line,
        column: m.column,
        matchText: m.matchText,
        contextLines: m.contextLines,
        contextBefore: m.contextBefore,
        symbolContext: m.symbolContext,
        matchLineCount: m.matchLineCount,
      );
    }).toList();

    // Extract symbols from matches
    final symbols = <String, SymbolInfo>{};
    for (final match in matches) {
      if (match.symbolContext != null) {
        // Try to find the symbol by name in the file
        final fileSymbols = index.symbolsInFile(match.file);
        for (final sym in fileSymbols) {
          if (sym.name == match.symbolContext) {
            symbols[sym.symbol] = sym;
            break;
          }
        }
      } else {
        // Find symbols at the match line
        final fileSymbols = index.symbolsInFile(match.file);
        for (final sym in fileSymbols) {
          final def = index.findDefinition(sym.symbol);
          if (def != null &&
              def.line <= match.line &&
              (def.enclosingEndLine ?? def.line + 100) >= match.line) {
            symbols[sym.symbol] = sym;
            break;
          }
        }
      }
    }

    return GrepResult(
      pattern: query.target,
      matches: grepMatches,
      symbols: symbols.values.toList(),
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
  ///
  /// Uses [registry] for cross-package call graph when available.
  Future<QueryResult> _findCalls(ScipQuery query) async {
    final sym = _resolveSymbol(query);
    if (sym == null) {
      return NotFoundResult('Symbol "${query.target}" not found');
    }

    final calls = provider != null
        ? provider!.getCalls(sym.symbol)
        : index.getCalls(sym.symbol).toList();
    return CallGraphResult(
      symbol: sym,
      direction: 'calls',
      connections: calls,
    );
  }

  /// Find what calls a symbol.
  ///
  /// Uses [registry] for cross-package call graph when available.
  Future<QueryResult> _findCallers(ScipQuery query) async {
    final sym = _resolveSymbol(query);
    if (sym == null) {
      return NotFoundResult('Symbol "${query.target}" not found');
    }

    final callers = provider != null
        ? provider!.getCallers(sym.symbol)
        : index.getCallers(sym.symbol).toList();
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

    // Look up symbols from imported files
    final importedSymbols = <SymbolInfo>[];
    for (final importPath in imports) {
      // Try to find the file in the index
      // Import paths might be relative or package paths
      String? resolvedPath;
      
      // Try direct match
      if (index.files.contains(importPath)) {
        resolvedPath = importPath;
      } else {
        // Try to find file with matching name
        final fileName = importPath.split('/').last;
        for (final file in index.files) {
          if (file.endsWith(fileName)) {
            resolvedPath = file;
            break;
          }
        }
      }

      if (resolvedPath != null) {
        importedSymbols.addAll(index.symbolsInFile(resolvedPath));
      }
    }

    // Get exported symbols from this file
    final exportedSymbols = index.symbolsInFile(filePath)
        .where((sym) => !sym.name.startsWith('_')) // Public symbols only
        .toList();

    return ImportsResult(
      file: filePath,
      imports: imports,
      exports: exports,
      importedSymbols: importedSymbols,
      exportedSymbols: exportedSymbols,
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
    final exportedSymbols = <SymbolInfo>[];

    if (entityType == FileSystemEntityType.file) {
      // Single file - get its exports
      final content = await File(fullPath).readAsString();
      final exportRegex = RegExp(r'''export\s+['"]([^'"]+)['"]''');
      for (final match in exportRegex.allMatches(content)) {
        exports.add(match.group(1)!);
      }
      // Get exported symbols from this file
      exportedSymbols.addAll(
        index.symbolsInFile(target).where(
          (sym) => !sym.name.startsWith('_'), // Public symbols only
        ),
      );
    } else {
      // Directory - list public symbols defined in it
      for (final file in index.files) {
        if (file.startsWith(target)) {
          final symbols = index.symbolsInFile(file);
          for (final sym in symbols) {
            // Only include top-level public symbols
            if (!sym.name.startsWith('_') && !sym.symbol.contains('#')) {
              exports.add('${sym.name} (${sym.kindString}) - $file');
              exportedSymbols.add(sym);
            }
          }
        }
      }
    }

    return ImportsResult(
      file: target,
      imports: [], // Only exports for directory
      exports: exports,
      exportedSymbols: exportedSymbols,
    );
  }

  /// Find dependencies of a symbol.
  ///
  /// Uses [registry] for cross-package call graph when available.
  Future<QueryResult> _findDeps(ScipQuery query) async {
    final sym = _resolveSymbol(query);
    if (sym == null) {
      return NotFoundResult('Symbol "${query.target}" not found');
    }

    // Dependencies = what the symbol calls + types it uses
    final deps = <String, SymbolInfo>{};

    // Get direct calls from all indexes
    final calls = provider != null
        ? provider!.getCalls(sym.symbol)
        : index.getCalls(sym.symbol).toList();

    for (final called in calls) {
      deps[called.symbol] = called;
    }

    // For classes, also include member dependencies
    if (sym.kind == scip.SymbolInformation_Kind.Class) {
      final children = index.getChildren(sym.symbol);
      for (final childId in children) {
        final childCalls = provider != null
            ? provider!.getCalls(childId)
            : index.getCalls(childId).toList();
        for (final called in childCalls) {
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

  /// Helper to resolve a single symbol from a query.
  ///
  /// Uses [_findMatchingSymbols] and returns the best match:
  /// - Prefers exact name matches
  /// - Falls back to first match
  SymbolInfo? _resolveSymbol(ScipQuery query) {
    final symbols = _findMatchingSymbols(query);
    if (symbols.isEmpty) return null;

    // Prefer exact name matches
    final targetName = query.isQualified ? query.memberName : query.target;
    final exact = symbols.where((s) => s.name == targetName).toList();
    if (exact.isNotEmpty) return exact.first;

    return symbols.first;
  }

  Future<QueryResult> _listFiles() async {
    // In workspace mode, aggregate files from all local packages
    if (provider != null && provider!.localIndexes.isNotEmpty) {
      final allFiles = <String>[];
      for (final idx in provider!.localIndexes.values) {
        allFiles.addAll(idx.files);
      }
      return FilesResult(allFiles.toList()..sort());
    }
    return FilesResult(index.files.toList()..sort());
  }

  Future<QueryResult> _getStats() async {
    // In workspace mode, aggregate stats from all local packages
    if (provider != null && provider!.localIndexes.isNotEmpty) {
      var totalFiles = 0;
      var totalSymbols = 0;
      var totalReferences = 0;

      for (final idx in provider!.localIndexes.values) {
        final stats = idx.stats;
        totalFiles += stats['files'] ?? 0;
        totalSymbols += stats['symbols'] ?? 0;
        totalReferences += stats['references'] ?? 0;
      }

      return StatsResult({
        'files': totalFiles,
        'symbols': totalSymbols,
        'references': totalReferences,
        'packages': provider!.localIndexes.length,
      });
    }
    return StatsResult(index.stats);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // FILE-SCOPED AND DIRECT LOOKUP QUERIES
  // ═══════════════════════════════════════════════════════════════════════

  /// List all symbols defined in a file.
  ///
  /// Usage: `symbols lib/auth/service.dart`
  Future<QueryResult> _listSymbolsInFile(ScipQuery query) async {
    final filePath = query.target;

    // Search in all local indexes
    final symbols = <SymbolInfo>[];

    if (provider != null && provider!.localIndexes.isNotEmpty) {
      for (final idx in provider!.localIndexes.values) {
        // Try both with and without the file path as-is
        var fileSymbols = idx.symbolsInFile(filePath).toList();

        // If not found, try matching by suffix
        if (fileSymbols.isEmpty) {
          for (final file in idx.files) {
            if (file.endsWith(filePath) || filePath.endsWith(file)) {
              fileSymbols = idx.symbolsInFile(file).toList();
              if (fileSymbols.isNotEmpty) break;
            }
          }
        }

        symbols.addAll(fileSymbols);
      }
    } else {
      var fileSymbols = index.symbolsInFile(filePath).toList();

      // If not found, try matching by suffix
      if (fileSymbols.isEmpty) {
        for (final file in index.files) {
          if (file.endsWith(filePath) || filePath.endsWith(file)) {
            fileSymbols = index.symbolsInFile(file).toList();
            if (fileSymbols.isNotEmpty) break;
          }
        }
      }

      symbols.addAll(fileSymbols);
    }

    if (symbols.isEmpty) {
      return NotFoundResult('No symbols found in file "$filePath"');
    }

    // Sort by line number, then by kind priority
    symbols.sort((a, b) {
      final aLine = index.findDefinition(a.symbol)?.line ?? 0;
      final bLine = index.findDefinition(b.symbol)?.line ?? 0;
      if (aLine != bLine) return aLine.compareTo(bLine);

      // Secondary sort by kind (classes first, then methods, etc.)
      const kindPriority = {
        'class': 0,
        'mixin': 1,
        'enum': 2,
        'extension': 3,
        'function': 4,
        'method': 5,
        'constructor': 6,
        'field': 7,
        'getter': 8,
        'setter': 9,
      };
      final aPriority = kindPriority[a.kindString] ?? 10;
      final bPriority = kindPriority[b.kindString] ?? 10;
      return aPriority.compareTo(bPriority);
    });

    return FileSymbolsResult(
      file: filePath,
      symbols: symbols,
    );
  }

  /// Get a symbol by its exact SCIP ID.
  ///
  /// Usage: `get "dart pub my_app 1.0.0 lib/auth.dart/AuthService#login()."`
  Future<QueryResult> _getByScipId(ScipQuery query) async {
    final symbolId = query.target;

    // Search in all indexes
    SymbolInfo? symbol;

    if (provider != null) {
      symbol = provider!.getSymbol(symbolId);
    } else {
      symbol = index.getSymbol(symbolId);
    }

    if (symbol == null) {
      return NotFoundResult('No symbol found with ID "$symbolId"');
    }

    // Get definition and source
    OccurrenceInfo? def;
    String? source;

    if (provider != null) {
      def = provider!.findDefinition(symbol.symbol);
      if (def != null) {
        source = await provider!.getSource(symbol.symbol);
      }
    } else {
      def = index.findDefinition(symbol.symbol);
      if (def != null) {
        source = await index.getSource(symbol.symbol);
      }
    }

    // If no definition found, create a synthetic location
    final location = def ??
        OccurrenceInfo(
          symbol: symbol.symbol,
          file: symbol.file ?? 'unknown',
          line: 0,
          column: 0,
          endLine: 0,
          endColumn: 0,
          isDefinition: true,
        );

    return DefinitionResult([
      DefinitionMatch(
        symbol: symbol,
        location: location,
        source: source,
      ),
    ]);
  }
}
