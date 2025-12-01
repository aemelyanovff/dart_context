import '../index/scip_index.dart';

/// Result of a query execution.
sealed class QueryResult {
  const QueryResult();

  /// Convert to human/LLM readable text.
  String toText();

  /// Convert to structured JSON.
  Map<String, dynamic> toJson();

  /// Whether the query found any results.
  bool get isEmpty;

  /// Number of results.
  int get count;
}

/// Result containing symbol definitions.
class DefinitionResult extends QueryResult {
  const DefinitionResult(this.definitions);

  final List<DefinitionMatch> definitions;

  @override
  bool get isEmpty => definitions.isEmpty;

  @override
  int get count => definitions.length;

  @override
  String toText() {
    if (definitions.isEmpty) {
      return 'No definitions found.';
    }

    final buffer = StringBuffer();
    for (final def in definitions) {
      buffer.writeln('## ${def.symbol.name} (${def.symbol.kindString})');
      buffer.writeln('File: ${def.location.location}');
      if (def.symbol.documentation.isNotEmpty) {
        buffer.writeln('');
        buffer.writeln(def.symbol.documentation.join('\n'));
      }
      if (def.source != null) {
        buffer.writeln('');
        buffer.writeln('```dart');
        buffer.writeln(def.source);
        buffer.writeln('```');
      }
      buffer.writeln('');
    }
    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'definitions',
        'count': definitions.length,
        'results': definitions
            .map(
              (d) => {
                'symbol': d.symbol.symbol,
                'name': d.symbol.name,
                'kind': d.symbol.kindString,
                'file': d.location.file,
                'line': d.location.line + 1,
                'column': d.location.column + 1,
                if (d.source != null) 'source': d.source,
              },
            )
            .toList(),
      };
}

/// A single definition match.
class DefinitionMatch {
  const DefinitionMatch({
    required this.symbol,
    required this.location,
    this.source,
  });

  final SymbolInfo symbol;
  final OccurrenceInfo location;
  final String? source;
}

/// Result containing references.
class ReferencesResult extends QueryResult {
  const ReferencesResult({
    required this.symbol,
    required this.references,
  });

  final SymbolInfo symbol;
  final List<ReferenceMatch> references;

  @override
  bool get isEmpty => references.isEmpty;

  @override
  int get count => references.length;

  @override
  String toText() {
    if (references.isEmpty) {
      return 'No references found for ${symbol.name}.';
    }

    final buffer = StringBuffer();
    buffer.writeln('## References to ${symbol.name} (${references.length})');
    buffer.writeln('');

    // Group by file
    final byFile = <String, List<ReferenceMatch>>{};
    for (final ref in references) {
      byFile.putIfAbsent(ref.location.file, () => []).add(ref);
    }

    for (final entry in byFile.entries) {
      buffer.writeln('### ${entry.key}');
      for (final ref in entry.value) {
        buffer.writeln('- Line ${ref.location.line + 1}');
        if (ref.context != null) {
          buffer.writeln('  ```dart');
          for (final line in ref.context!.split('\n')) {
            buffer.writeln('  $line');
          }
          buffer.writeln('  ```');
        }
      }
      buffer.writeln('');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'references',
        'symbol': symbol.symbol,
        'name': symbol.name,
        'count': references.length,
        'results': references
            .map(
              (r) => {
                'file': r.location.file,
                'line': r.location.line + 1,
                'column': r.location.column + 1,
                if (r.context != null) 'context': r.context,
              },
            )
            .toList(),
      };
}

/// A single reference match.
class ReferenceMatch {
  const ReferenceMatch({
    required this.location,
    this.context,
  });

  final OccurrenceInfo location;
  final String? context;
}

/// Result containing class members.
class MembersResult extends QueryResult {
  const MembersResult({
    required this.symbol,
    required this.members,
  });

  final SymbolInfo symbol;
  final List<SymbolInfo> members;

  @override
  bool get isEmpty => members.isEmpty;

  @override
  int get count => members.length;

  @override
  String toText() {
    if (members.isEmpty) {
      return 'No members found for ${symbol.name}.';
    }

    final buffer = StringBuffer();
    buffer.writeln('## Members of ${symbol.name} (${members.length})');
    buffer.writeln('');

    // Group by kind
    final byKind = <String, List<SymbolInfo>>{};
    for (final member in members) {
      byKind.putIfAbsent(member.kindString, () => []).add(member);
    }

    for (final entry in byKind.entries) {
      buffer.writeln('### ${_capitalize(entry.key)}s');
      for (final member in entry.value) {
        buffer.writeln('- ${member.name}');
      }
      buffer.writeln('');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'members',
        'symbol': symbol.symbol,
        'name': symbol.name,
        'count': members.length,
        'results': members
            .map(
              (m) => {
                'symbol': m.symbol,
                'name': m.name,
                'kind': m.kindString,
              },
            )
            .toList(),
      };

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    final capitalized = '${s[0].toUpperCase()}${s.substring(1)}';
    // Fix common pluralization issues
    if (capitalized.endsWith('ys') && !capitalized.endsWith('ays')) {
      return '${capitalized.substring(0, capitalized.length - 2)}ies';
    }
    return capitalized;
  }
}

/// Result containing symbol search matches.
class SearchResult extends QueryResult {
  const SearchResult(this.symbols);

  final List<SymbolInfo> symbols;

  @override
  bool get isEmpty => symbols.isEmpty;

  @override
  int get count => symbols.length;

  @override
  String toText() {
    if (symbols.isEmpty) {
      return 'No symbols found.';
    }

    final buffer = StringBuffer();
    buffer.writeln('## Found ${symbols.length} symbols');
    buffer.writeln('');

    for (final sym in symbols) {
      final location = sym.file != null ? ' (${sym.file})' : ' (external)';
      buffer.writeln('- **${sym.name}** [${sym.kindString}]$location');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'search',
        'count': symbols.length,
        'results': symbols
            .map(
              (s) => {
                'symbol': s.symbol,
                'name': s.name,
                'kind': s.kindString,
                if (s.file != null) 'file': s.file,
              },
            )
            .toList(),
      };
}

/// Result containing source code.
class SourceResult extends QueryResult {
  const SourceResult({
    required this.symbol,
    required this.source,
    required this.file,
    required this.startLine,
  });

  final SymbolInfo symbol;
  final String source;
  final String file;
  final int startLine;

  @override
  bool get isEmpty => source.isEmpty;

  @override
  int get count => 1;

  @override
  String toText() {
    final buffer = StringBuffer();
    buffer.writeln('## ${symbol.name} (${symbol.kindString})');
    buffer.writeln('File: $file:${startLine + 1}');
    buffer.writeln('');
    buffer.writeln('```dart');
    buffer.writeln(source);
    buffer.writeln('```');
    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'source',
        'symbol': symbol.symbol,
        'name': symbol.name,
        'kind': symbol.kindString,
        'file': file,
        'startLine': startLine + 1,
        'source': source,
      };
}

/// Result containing hierarchy information.
class HierarchyResult extends QueryResult {
  const HierarchyResult({
    required this.symbol,
    required this.supertypes,
    required this.subtypes,
  });

  final SymbolInfo symbol;
  final List<SymbolInfo> supertypes;
  final List<SymbolInfo> subtypes;

  @override
  bool get isEmpty => supertypes.isEmpty && subtypes.isEmpty;

  @override
  int get count => supertypes.length + subtypes.length;

  @override
  String toText() {
    final buffer = StringBuffer();
    buffer.writeln('## Hierarchy of ${symbol.name}');
    buffer.writeln('');

    if (supertypes.isNotEmpty) {
      buffer.writeln('### Supertypes (${supertypes.length})');
      for (final st in supertypes) {
        buffer.writeln('- ${st.name}');
      }
      buffer.writeln('');
    }

    if (subtypes.isNotEmpty) {
      buffer.writeln('### Subtypes (${subtypes.length})');
      for (final st in subtypes) {
        buffer.writeln('- ${st.name}');
      }
      buffer.writeln('');
    }

    if (isEmpty) {
      buffer.writeln('No supertypes or subtypes found.');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'hierarchy',
        'symbol': symbol.symbol,
        'name': symbol.name,
        'supertypes':
            supertypes.map((s) => {'symbol': s.symbol, 'name': s.name}).toList(),
        'subtypes':
            subtypes.map((s) => {'symbol': s.symbol, 'name': s.name}).toList(),
      };
}

/// Result containing file list.
class FilesResult extends QueryResult {
  const FilesResult(this.files);

  final List<String> files;

  @override
  bool get isEmpty => files.isEmpty;

  @override
  int get count => files.length;

  @override
  String toText() {
    if (files.isEmpty) {
      return 'No files indexed.';
    }

    final buffer = StringBuffer();
    buffer.writeln('## Indexed Files (${files.length})');
    buffer.writeln('');
    for (final file in files) {
      buffer.writeln('- $file');
    }
    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'files',
        'count': files.length,
        'files': files,
      };
}

/// Result containing index statistics.
class StatsResult extends QueryResult {
  const StatsResult(this.stats);

  final Map<String, int> stats;

  @override
  bool get isEmpty => false;

  @override
  int get count => 1;

  @override
  String toText() {
    final buffer = StringBuffer();
    buffer.writeln('## Index Statistics');
    buffer.writeln('');
    buffer.writeln('- Files: ${stats['files'] ?? 0}');
    buffer.writeln('- Symbols: ${stats['symbols'] ?? 0}');
    buffer.writeln('- References: ${stats['references'] ?? 0}');
    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'stats',
        'stats': stats,
      };
}

/// Result for not found / no match.
class NotFoundResult extends QueryResult {
  const NotFoundResult(this.message);

  final String message;

  @override
  bool get isEmpty => true;

  @override
  int get count => 0;

  @override
  String toText() => message;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'not_found',
        'message': message,
      };
}

/// Result for errors.
class ErrorResult extends QueryResult {
  const ErrorResult(this.error);

  final String error;

  @override
  bool get isEmpty => true;

  @override
  int get count => 0;

  @override
  String toText() => 'Error: $error';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'error',
        'error': error,
      };
}

/// Result for disambiguation (which command).
class WhichResult extends QueryResult {
  const WhichResult({
    required this.query,
    required this.matches,
  });

  final String query;
  final List<WhichMatch> matches;

  @override
  bool get isEmpty => matches.isEmpty;

  @override
  int get count => matches.length;

  @override
  String toText() {
    if (matches.isEmpty) {
      return 'No symbols found matching "$query".';
    }

    if (matches.length == 1) {
      final m = matches.first;
      return 'Found 1 match for "$query":\n'
          '  ${m.symbol.name} [${m.symbol.kindString}] in ${m.location ?? 'external'}';
    }

    final buffer = StringBuffer();
    buffer.writeln('## Found ${matches.length} symbols matching "$query"');
    buffer.writeln('');
    buffer.writeln('Use a qualified name to disambiguate:');
    buffer.writeln('');

    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final location = m.location ?? 'external';
      final container = m.container;
      final qualifiedHint = container != null ? '$container.${m.symbol.name}' : m.symbol.name;
      
      buffer.writeln('${i + 1}. **${m.symbol.name}** [${m.symbol.kindString}]');
      buffer.writeln('   File: $location');
      if (container != null) {
        buffer.writeln('   Container: $container');
        buffer.writeln('   Use: `refs $qualifiedHint`');
      }
      buffer.writeln('');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'which',
        'query': query,
        'count': matches.length,
        'matches': matches
            .map(
              (m) => {
                'symbol': m.symbol.symbol,
                'name': m.symbol.name,
                'kind': m.symbol.kindString,
                if (m.location != null) 'file': m.location,
                if (m.container != null) 'container': m.container,
                if (m.line != null) 'line': m.line! + 1,
              },
            )
            .toList(),
      };
}

/// A single match for disambiguation.
class WhichMatch {
  const WhichMatch({
    required this.symbol,
    this.location,
    this.container,
    this.line,
  });

  final SymbolInfo symbol;
  final String? location;
  final String? container;
  final int? line;
}

/// Result containing aggregated references from multiple symbols.
class AggregatedReferencesResult extends QueryResult {
  const AggregatedReferencesResult({
    required this.query,
    required this.symbolRefs,
  });

  final String query;
  final List<SymbolReferences> symbolRefs;

  @override
  bool get isEmpty => symbolRefs.every((sr) => sr.references.isEmpty);

  @override
  int get count => symbolRefs.fold(0, (sum, sr) => sum + sr.references.length);

  @override
  String toText() {
    if (isEmpty) {
      return 'No references found for "$query".';
    }

    final buffer = StringBuffer();
    buffer.writeln('## References to "$query" (${symbolRefs.length} symbols, $count total refs)');
    buffer.writeln('');

    for (final sr in symbolRefs) {
      final container = sr.container != null ? '${sr.container}.' : '';
      buffer.writeln('### $container${sr.symbol.name} [${sr.symbol.kindString}] (${sr.references.length} refs)');
      if (sr.symbol.file != null) {
        buffer.writeln('Defined in: ${sr.symbol.file}');
      }
      buffer.writeln('');

      // Group by file
      final byFile = <String, List<ReferenceMatch>>{};
      for (final ref in sr.references) {
        byFile.putIfAbsent(ref.location.file, () => []).add(ref);
      }

      for (final entry in byFile.entries) {
        buffer.writeln('  **${entry.key}**');
        for (final ref in entry.value) {
          buffer.writeln('  - Line ${ref.location.line + 1}');
        }
      }
      buffer.writeln('');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'aggregated_references',
        'query': query,
        'totalRefs': count,
        'symbols': symbolRefs
            .map(
              (sr) => {
                'symbol': sr.symbol.symbol,
                'name': sr.symbol.name,
                'kind': sr.symbol.kindString,
                if (sr.container != null) 'container': sr.container,
                'refCount': sr.references.length,
                'references': sr.references
                    .map(
                      (r) => {
                        'file': r.location.file,
                        'line': r.location.line + 1,
                        'column': r.location.column + 1,
                      },
                    )
                    .toList(),
              },
            )
            .toList(),
      };
}

/// References for a single symbol (used in aggregated results).
class SymbolReferences {
  const SymbolReferences({
    required this.symbol,
    required this.references,
    this.container,
  });

  final SymbolInfo symbol;
  final List<ReferenceMatch> references;
  final String? container;
}

/// Result of a call graph query.
class CallGraphResult extends QueryResult {
  const CallGraphResult({
    required this.symbol,
    required this.direction,
    required this.connections,
  });

  final SymbolInfo symbol;
  final String direction; // "calls" or "callers"
  final List<SymbolInfo> connections;

  @override
  bool get isEmpty => connections.isEmpty;

  @override
  int get count => connections.length;

  @override
  String toText() {
    if (connections.isEmpty) {
      return direction == 'calls'
          ? '${symbol.name} does not call any symbols.'
          : '${symbol.name} is not called by any symbols.';
    }

    final buffer = StringBuffer();
    final verb = direction == 'calls' ? 'calls' : 'is called by';
    buffer.writeln('## ${symbol.name} $verb ${connections.length} symbols:');
    buffer.writeln('');

    // Group by kind
    final byKind = <String, List<SymbolInfo>>{};
    for (final conn in connections) {
      final kind = conn.kindString;
      byKind.putIfAbsent(kind, () => []).add(conn);
    }

    for (final entry in byKind.entries) {
      buffer.writeln('### ${entry.key}s (${entry.value.length})');
      for (final sym in entry.value) {
        final file = sym.file ?? 'external';
        buffer.writeln('- `${sym.name}` ($file)');
      }
      buffer.writeln('');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'call_graph',
        'symbol': symbol.name,
        'direction': direction,
        'count': connections.length,
        'connections': connections
            .map(
              (c) => {
                'name': c.name,
                'kind': c.kindString,
                'file': c.file,
              },
            )
            .toList(),
      };
}

/// Result of imports/exports analysis.
class ImportsResult extends QueryResult {
  const ImportsResult({
    required this.file,
    required this.imports,
    required this.exports,
  });

  final String file;
  final List<String> imports;
  final List<String> exports;

  @override
  bool get isEmpty => imports.isEmpty && exports.isEmpty;

  @override
  int get count => imports.length + exports.length;

  @override
  String toText() {
    final buffer = StringBuffer();
    buffer.writeln('## $file');
    buffer.writeln('');

    if (imports.isNotEmpty) {
      buffer.writeln('### Imports (${imports.length})');
      for (final imp in imports) {
        buffer.writeln('- $imp');
      }
      buffer.writeln('');
    }

    if (exports.isNotEmpty) {
      buffer.writeln('### Exports (${exports.length})');
      for (final exp in exports) {
        buffer.writeln('- $exp');
      }
      buffer.writeln('');
    }

    if (isEmpty) {
      buffer.writeln('No imports or exports found.');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'imports',
        'file': file,
        'imports': imports,
        'exports': exports,
      };
}

/// Result of dependencies analysis.
class DependenciesResult extends QueryResult {
  const DependenciesResult({
    required this.symbol,
    required this.dependencies,
  });

  final SymbolInfo symbol;
  final List<SymbolInfo> dependencies;

  @override
  bool get isEmpty => dependencies.isEmpty;

  @override
  int get count => dependencies.length;

  @override
  String toText() {
    if (dependencies.isEmpty) {
      return '${symbol.name} has no dependencies.';
    }

    final buffer = StringBuffer();
    buffer.writeln('## Dependencies of ${symbol.name} (${dependencies.length})');
    buffer.writeln('');

    // Group by kind
    final byKind = <String, List<SymbolInfo>>{};
    for (final dep in dependencies) {
      final kind = dep.kindString;
      byKind.putIfAbsent(kind, () => []).add(dep);
    }

    for (final entry in byKind.entries) {
      buffer.writeln('### ${entry.key}s (${entry.value.length})');
      for (final sym in entry.value) {
        final file = sym.file ?? 'external';
        buffer.writeln('- `${sym.name}` ($file)');
      }
      buffer.writeln('');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'dependencies',
        'symbol': symbol.name,
        'count': dependencies.length,
        'dependencies': dependencies
            .map(
              (d) => {
                'name': d.name,
                'kind': d.kindString,
                'file': d.file,
              },
            )
            .toList(),
      };
}

/// Result of a pipeline query (aggregation of multiple results).
class PipelineResult extends QueryResult {
  const PipelineResult({
    required this.action,
    required this.results,
  });

  final String action;
  final List<QueryResult> results;

  @override
  bool get isEmpty => results.isEmpty || results.every((r) => r.isEmpty);

  @override
  int get count => results.fold(0, (sum, r) => sum + r.count);

  @override
  String toText() {
    if (results.isEmpty) {
      return 'Pipeline produced no results.';
    }

    final buffer = StringBuffer();
    buffer.writeln('## Pipeline Results: $action (${results.length} queries)');
    buffer.writeln('');

    for (var i = 0; i < results.length; i++) {
      buffer.writeln('### Result ${i + 1}');
      buffer.writeln(results[i].toText());
      buffer.writeln('');
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'pipeline',
        'action': action,
        'count': results.length,
        'totalCount': count,
        'results': results.map((r) => r.toJson()).toList(),
      };
}

/// Result of a grep search across source files.
class GrepResult extends QueryResult {
  const GrepResult({
    required this.pattern,
    required this.matches,
  });

  final String pattern;
  final List<GrepMatch> matches;

  @override
  bool get isEmpty => matches.isEmpty;

  @override
  int get count => matches.length;

  @override
  String toText() {
    if (matches.isEmpty) {
      return 'No matches found for pattern "$pattern".';
    }

    final buffer = StringBuffer();
    buffer.writeln('## Grep: $pattern (${matches.length} matches)');
    buffer.writeln('');

    // Group by file
    final byFile = <String, List<GrepMatch>>{};
    for (final match in matches) {
      byFile.putIfAbsent(match.file, () => []).add(match);
    }

    for (final entry in byFile.entries) {
      buffer.writeln('### ${entry.key} (${entry.value.length} matches)');
      buffer.writeln('');

      for (final match in entry.value) {
        // Show context with line numbers (grep-style)
        final lines = match.contextLines;
        for (var i = 0; i < lines.length; i++) {
          final lineNum = match.startLine - match.contextBefore + i + 1;
          final isMatchLine =
              i >= match.contextBefore &&
              i < match.contextBefore + match.matchLineCount;
          final prefix = isMatchLine ? '>' : ' ';
          buffer.writeln('$prefix${lineNum.toString().padLeft(4)}| ${lines[i]}');
        }
        buffer.writeln('');
      }
    }

    return buffer.toString().trimRight();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'grep',
        'pattern': pattern,
        'count': matches.length,
        'matches': matches
            .map(
              (m) => {
                'file': m.file,
                'line': m.line + 1,
                'column': m.column + 1,
                'matchText': m.matchText,
                'context': m.contextLines.join('\n'),
              },
            )
            .toList(),
      };
}

/// A single grep match.
class GrepMatch {
  const GrepMatch({
    required this.file,
    required this.line,
    required this.column,
    required this.matchText,
    required this.contextLines,
    required this.contextBefore,
    this.matchLineCount = 1,
    this.symbolContext,
  });

  final String file;
  final int line;
  final int column;
  final String matchText;
  final List<String> contextLines;
  final int contextBefore;
  final int matchLineCount;
  final String? symbolContext; // e.g., "in MyClass.myMethod"

  int get startLine => line - contextBefore;
}

