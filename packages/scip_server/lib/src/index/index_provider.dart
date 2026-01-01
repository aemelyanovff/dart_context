import 'scip_index.dart';

/// Abstract interface for providing indexes and cross-index operations.
///
/// This interface abstracts the concept of an index registry, allowing
/// the query executor to work with multiple indexes (local packages,
/// external dependencies) without knowing the language-specific details.
abstract class IndexProvider {
  /// The primary index (first local package or main project index).
  ScipIndex get projectIndex;

  /// All local package indexes (for workspace/monorepo queries).
  Map<String, ScipIndex> get localIndexes;

  /// All external indexes (SDK, packages, etc.).
  Iterable<ScipIndex> get allExternalIndexes;

  /// All indexes combined (local + external).
  Iterable<ScipIndex> get allIndexes;

  /// Find a symbol by exact ID across all indexes.
  SymbolInfo? getSymbol(String symbolId);

  /// Find definition of a symbol across all indexes.
  OccurrenceInfo? findDefinition(String symbolId);

  /// Find all references to a symbol across all indexes.
  List<OccurrenceInfo> findAllReferences(String symbolId);

  /// Find symbols by name pattern across all indexes.
  List<SymbolInfo> findSymbols(String pattern);

  /// Find qualified symbols (e.g., "Class.method").
  List<SymbolInfo> findQualified(String container, String member);

  /// Get members of a class/type.
  List<SymbolInfo> membersOf(String symbolId);

  /// Get supertypes of a class.
  List<SymbolInfo> supertypesOf(String symbolId);

  /// Get subtypes/implementations of a class.
  List<SymbolInfo> subtypesOf(String symbolId);

  /// Get what a symbol calls.
  List<SymbolInfo> getCalls(String symbolId);

  /// Get what calls a symbol.
  List<SymbolInfo> getCallers(String symbolId);

  /// Find all callers by symbol name (for cross-package queries).
  List<SymbolInfo> findAllCallersByName(String symbolName);

  /// Find all references by symbol name (for cross-package queries).
  List<ReferenceWithSource> findAllReferencesByName(
    String symbolName, {
    String? symbolKind,
  });

  /// Get source code for a symbol.
  Future<String?> getSource(String symbolId);

  /// Grep across all indexes.
  Future<List<GrepMatchInfo>> grep(
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
    bool includeExternal = false,
  });
}

/// A reference with its source root information.
class ReferenceWithSource {
  const ReferenceWithSource({
    required this.ref,
    required this.sourceRoot,
  });

  final OccurrenceInfo ref;
  final String sourceRoot;
}

/// Grep match information.
class GrepMatchInfo {
  const GrepMatchInfo({
    required this.file,
    required this.line,
    required this.column,
    required this.matchText,
    this.contextLines,
    this.contextBefore,
    this.symbolContext,
    this.matchLineCount = 1,
  });

  final String file;
  final int line;
  final int column;
  final String matchText;
  final List<String>? contextLines;
  final List<String>? contextBefore;
  final String? symbolContext;
  final int matchLineCount;
}

