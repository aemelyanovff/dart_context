/// Query DSL parser for dart_context.
///
/// Supported queries:
/// - `def <symbol>` - Find definition
/// - `refs <symbol>` - Find references
/// - `members <symbol>` - Get class members
/// - `impls <symbol>` - Find implementations
/// - `supertypes <symbol>` - Get supertypes
/// - `subtypes <symbol>` - Get subtypes
/// - `hierarchy <symbol>` - Full hierarchy (supertypes + subtypes)
/// - `source <symbol>` - Get source code
/// - `find <pattern> [kind:<kind>] [in:<path>]` - Search symbols
/// - `which <symbol>` - Show all matches for disambiguation
/// - `grep <pattern> [in:<path>] [-i] [-C:n]` - Search in source code (like grep)
/// - `calls <symbol>` - What does this symbol call?
/// - `callers <symbol>` - What calls this symbol?
/// - `imports <file>` - What does this file import?
/// - `exports <file>` - What does this file/directory export?
/// - `deps <symbol>` - Dependencies of a symbol
/// - `sig <symbol>` - Get signature (without body)
///
/// Qualified names:
/// - `refs MyClass.login` - References to login method in MyClass
/// - `def AuthService.authenticate` - Definition of authenticate in AuthService
///
/// Filters (for `find` and `grep`):
/// - `kind:class` - Filter by symbol kind
/// - `in:lib/` - Filter by file path prefix
///
/// Grep flags:
/// - `-i` - Case insensitive
/// - `-v` - Invert match (show non-matching lines)
/// - `-w` - Word boundary (match whole words)
/// - `-l` - Files only (just show filenames)
/// - `-c` - Count only (count matches per file)
/// - `-C:n` - Context lines (before and after)
/// - `-A:n` - Lines after match
/// - `-B:n` - Lines before match
/// - `-m:n` - Max matches (stop after n matches)
///
/// Pattern syntax:
/// - `Auth*` - Glob pattern (wildcard)
/// - `/auth/i` - Regex pattern (between slashes, flags after)
/// - `~login` - Fuzzy match (typo-tolerant)
///
/// Pipe/batch queries:
/// - `find Auth* | refs` - Find refs for all matching symbols
/// - `members MyClass | source` - Get source for all members
///
/// Examples:
/// - `def AuthRepository`
/// - `refs MyClass.login`
/// - `calls AuthService.login`
/// - `callers validateUser`
/// - `imports lib/auth/service.dart`
/// - `sig AuthService.login` - Get method signature
/// - `find Auth* kind:class | members`
library;

// ignore: implementation_imports
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;

/// Parsed query from the DSL.
class ScipQuery {
  ScipQuery._({
    required this.action,
    required this.target,
    required this.filters,
  });

  /// The query action (def, refs, members, etc.)
  final QueryAction action;

  /// The target symbol pattern.
  final String target;

  /// Optional filters (kind, in).
  final Map<String, String> filters;

  /// Parse a query string into a structured query.
  ///
  /// Throws [FormatException] if the query is invalid.
  factory ScipQuery.parse(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw FormatException('Empty query');
    }

    // Tokenize (respecting quoted strings)
    final tokens = _tokenize(trimmed);
    if (tokens.isEmpty) {
      throw FormatException('Empty query');
    }

    // Parse action
    final actionStr = tokens[0].toLowerCase();
    final action = _parseAction(actionStr);

    // Parse target and filters
    String? target;
    final filters = <String, String>{};

    for (var i = 1; i < tokens.length; i++) {
      final token = tokens[i];

      // Handle grep-style flags like -i, -C:5, -A:3
      if (token.startsWith('-') && token.length >= 2) {
        final flagPart = token.substring(1);
        if (flagPart.contains(':')) {
          // Flag with value: -C:5
          final colonIndex = flagPart.indexOf(':');
          final key = flagPart.substring(0, colonIndex);
          final value = flagPart.substring(colonIndex + 1);
          filters[key] = value;
        } else {
          // Boolean flag: -i
          filters[flagPart] = 'true';
        }
      } else if (token.contains(':')) {
        // It's a filter (key:value)
        final colonIndex = token.indexOf(':');
        final key = token.substring(0, colonIndex);
        final value = token.substring(colonIndex + 1);
        filters[key] = value;
      } else if (target == null) {
        target = token;
      } else {
        // Multiple targets - join them (e.g., "Class.method")
        target = '$target.$token';
      }
    }

    // Some actions don't require a target
    if (action != QueryAction.files &&
        action != QueryAction.stats &&
        (target == null || target.isEmpty)) {
      throw FormatException('Missing target symbol for action: $actionStr');
    }

    return ScipQuery._(
      action: action,
      target: target ?? '',
      filters: filters,
    );
  }

  /// Tokenize a query string.
  static List<String> _tokenize(String query) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    String? quoteChar;

    for (var i = 0; i < query.length; i++) {
      final char = query[i];

      if ((char == '"' || char == "'") && !inQuotes) {
        inQuotes = true;
        quoteChar = char;
      } else if (char == quoteChar && inQuotes) {
        inQuotes = false;
        quoteChar = null;
      } else if (char == ' ' && !inQuotes) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(char);
      }
    }

    if (buffer.isNotEmpty) {
      tokens.add(buffer.toString());
    }

    return tokens;
  }

  /// Parse action string to enum.
  static QueryAction _parseAction(String action) {
    return switch (action) {
      'def' || 'definition' => QueryAction.definition,
      'refs' || 'references' => QueryAction.references,
      'members' => QueryAction.members,
      'impls' || 'implementations' => QueryAction.implementations,
      'supertypes' || 'super' => QueryAction.supertypes,
      'subtypes' || 'sub' => QueryAction.subtypes,
      'hierarchy' => QueryAction.hierarchy,
      'source' || 'src' => QueryAction.source,
      'find' || 'search' => QueryAction.find,
      'which' || 'disambiguate' => QueryAction.which,
      'grep' || 'rg' => QueryAction.grep,
      'calls' || 'callees' => QueryAction.calls,
      'callers' || 'calledby' => QueryAction.callers,
      'imports' => QueryAction.imports,
      'exports' => QueryAction.exports,
      'deps' || 'dependencies' => QueryAction.deps,
      'sig' || 'signature' => QueryAction.signature,
      'files' => QueryAction.files,
      'stats' => QueryAction.stats,
      _ => throw FormatException('Unknown action: $action'),
    };
  }

  /// Get the kind filter as a SymbolKind.
  scip.SymbolInformation_Kind? get kindFilter {
    final kindStr = filters['kind'];
    if (kindStr == null) return null;

    return switch (kindStr.toLowerCase()) {
      'class' => scip.SymbolInformation_Kind.Class,
      'method' => scip.SymbolInformation_Kind.Method,
      'function' => scip.SymbolInformation_Kind.Function,
      'field' => scip.SymbolInformation_Kind.Field,
      'constructor' => scip.SymbolInformation_Kind.Constructor,
      'enum' => scip.SymbolInformation_Kind.Enum,
      'enummember' => scip.SymbolInformation_Kind.EnumMember,
      'interface' => scip.SymbolInformation_Kind.Interface,
      'variable' => scip.SymbolInformation_Kind.Variable,
      'property' => scip.SymbolInformation_Kind.Property,
      'parameter' => scip.SymbolInformation_Kind.Parameter,
      'mixin' => scip.SymbolInformation_Kind.Mixin,
      'extension' => scip.SymbolInformation_Kind.Extension,
      'getter' => scip.SymbolInformation_Kind.Getter,
      'setter' => scip.SymbolInformation_Kind.Setter,
      _ => null,
    };
  }

  /// Get the path filter.
  String? get pathFilter => filters['in'];

  /// Get context lines for grep (-C:n).
  /// Returns null if -A or -B are specified separately.
  int? get contextLines {
    // If -A or -B specified, don't use -C
    if (filters.containsKey('A') || filters.containsKey('B')) {
      return null;
    }
    final value = filters['C'] ?? filters['context'];
    if (value == null) return 2; // Default
    return int.tryParse(value) ?? 2;
  }

  /// Get lines after match (-A:n).
  int get linesAfter {
    final value = filters['A'] ?? filters['after'];
    if (value != null) return int.tryParse(value) ?? 2;
    return contextLines ?? 2;
  }

  /// Get lines before match (-B:n).
  int get linesBefore {
    final value = filters['B'] ?? filters['before'];
    if (value != null) return int.tryParse(value) ?? 2;
    return contextLines ?? 2;
  }

  /// Check if case insensitive (-i).
  bool get caseInsensitive => filters.containsKey('i');

  /// Check if invert match (-v).
  bool get invertMatch => filters.containsKey('v');

  /// Check if word boundary match (-w).
  bool get wordBoundary => filters.containsKey('w');

  /// Check if files-only output (-l).
  bool get filesOnly => filters.containsKey('l');

  /// Check if count-only output (-c).
  bool get countOnly => filters.containsKey('c');

  /// Get max matches (-m:n). Returns null for unlimited.
  int? get maxCount {
    final value = filters['m'] ?? filters['max'];
    if (value == null) return null;
    return int.tryParse(value);
  }

  /// Parse the target as a pattern.
  ParsedPattern get parsedPattern => ParsedPattern.parse(
        target,
        defaultCaseSensitive: !caseInsensitive,
      );

  /// Check if target is a qualified name (e.g., "MyClass.method").
  bool get isQualified => target.contains('.') && !target.startsWith('/');

  /// Get the container part of a qualified name (e.g., "MyClass" from "MyClass.method").
  String? get container => isQualified ? target.split('.').first : null;

  /// Get the member part of a qualified name (e.g., "method" from "MyClass.method").
  String get memberName => isQualified ? target.split('.').last : target;

  @override
  String toString() {
    final filterStr =
        filters.entries.map((e) => '${e.key}:${e.value}').join(' ');
    return 'ScipQuery(${action.name} $target${filterStr.isNotEmpty ? ' $filterStr' : ''})';
  }
}

/// Query action types.
enum QueryAction {
  /// Find definition of a symbol.
  definition,

  /// Find all references to a symbol.
  references,

  /// Get members of a class/type.
  members,

  /// Find implementations of a class/interface.
  implementations,

  /// Get supertypes of a class.
  supertypes,

  /// Get subtypes (implementations) of a class.
  subtypes,

  /// Get full hierarchy (supertypes + subtypes).
  hierarchy,

  /// Get source code for a symbol.
  source,

  /// Search for symbols matching a pattern.
  find,

  /// Show all matches for a symbol (disambiguation).
  which,

  /// Search in source code (like grep).
  grep,

  /// What does this symbol call?
  calls,

  /// What calls this symbol?
  callers,

  /// What does this file import?
  imports,

  /// What does this file/directory export?
  exports,

  /// Dependencies of a symbol.
  deps,

  /// Get signature (without body).
  signature,

  /// List all indexed files.
  files,

  /// Get index statistics.
  stats,
}

/// Pattern type for matching.
enum PatternType {
  /// Glob pattern with wildcards (* and ?).
  glob,

  /// Regular expression (enclosed in /.../).
  regex,

  /// Fuzzy match (prefix ~).
  fuzzy,

  /// Literal exact match.
  literal,
}

/// Parsed pattern with type information.
class ParsedPattern {
  ParsedPattern._({
    required this.original,
    required this.type,
    required this.pattern,
    required this.caseSensitive,
  });

  final String original;
  final PatternType type;
  final String pattern;
  final bool caseSensitive;

  /// Parse a pattern string into structured form.
  factory ParsedPattern.parse(String input,
      {bool defaultCaseSensitive = true}) {
    var caseSensitive = defaultCaseSensitive;

    // Check for regex pattern: /pattern/ or /pattern/i
    if (input.startsWith('/')) {
      final lastSlash = input.lastIndexOf('/');
      if (lastSlash > 0) {
        final pattern = input.substring(1, lastSlash);
        final flags = input.substring(lastSlash + 1);
        if (flags.contains('i')) caseSensitive = false;
        return ParsedPattern._(
          original: input,
          type: PatternType.regex,
          pattern: pattern,
          caseSensitive: caseSensitive,
        );
      }
    }

    // Check for fuzzy pattern: ~pattern
    if (input.startsWith('~')) {
      return ParsedPattern._(
        original: input,
        type: PatternType.fuzzy,
        pattern: input.substring(1),
        caseSensitive: false, // Fuzzy is always case-insensitive
      );
    }

    // Check for glob pattern: contains * or ?
    if (input.contains('*') || input.contains('?')) {
      return ParsedPattern._(
        original: input,
        type: PatternType.glob,
        pattern: input,
        caseSensitive: caseSensitive,
      );
    }

    // Otherwise literal
    return ParsedPattern._(
      original: input,
      type: PatternType.literal,
      pattern: input,
      caseSensitive: caseSensitive,
    );
  }

  /// Convert to a RegExp for matching.
  ///
  /// Throws [FormatException] if the pattern is an invalid regex.
  RegExp toRegExp() {
    final regexPattern = switch (type) {
      PatternType.regex => pattern,
      PatternType.glob => _globToRegex(pattern),
      PatternType.fuzzy => _fuzzyToRegex(pattern),
      PatternType.literal => RegExp.escape(pattern),
    };

    try {
      return RegExp(regexPattern, caseSensitive: caseSensitive);
    } on FormatException catch (e) {
      throw FormatException('Invalid regex pattern: ${e.message}');
    }
  }

  /// Convert glob pattern to regex.
  ///
  /// Converts glob wildcards to regex equivalents:
  /// - `*` becomes `.*` (zero or more characters)
  /// - `?` becomes `.` (exactly one character)
  static String _globToRegex(String glob) {
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
    return escaped.toString();
  }

  /// Convert fuzzy pattern to regex that tolerates typos.
  ///
  /// Creates a pattern that allows:
  /// - Missing characters
  /// - Extra characters
  /// - Swapped adjacent characters
  /// - Wrong characters
  static String _fuzzyToRegex(String fuzzy) {
    if (fuzzy.isEmpty) return '.*';

    // Build a regex that matches with some tolerance
    // Allow each character to be optional or have one mistake
    final buffer = StringBuffer();

    for (var i = 0; i < fuzzy.length; i++) {
      final char = RegExp.escape(fuzzy[i]);

      // Allow this character to be missing, or have an extra char before it
      buffer.write('(?:');
      buffer.write('.?'); // Optional extra character
      buffer.write(char);
      buffer.write('|');
      buffer.write(char);
      buffer.write('.?'); // Optional missing character
      buffer.write(')');
    }

    return buffer.toString();
  }

  /// Check if a string matches this pattern.
  bool matches(String text) {
    if (type == PatternType.fuzzy) {
      // For fuzzy, use Levenshtein distance
      return _fuzzyMatch(text, pattern);
    }
    return toRegExp().hasMatch(text);
  }

  /// Fuzzy match using edit distance.
  static bool _fuzzyMatch(String text, String pattern, {int maxDistance = 2}) {
    final textLower = text.toLowerCase();
    final patternLower = pattern.toLowerCase();

    // Check if pattern appears as substring (best match)
    if (textLower.contains(patternLower)) return true;

    // Check edit distance for short strings
    if (pattern.length <= 10) {
      final distance = levenshteinDistance(textLower, patternLower);
      return distance <= maxDistance;
    }

    // For longer patterns, check if most characters are present
    var matchCount = 0;
    for (final char in patternLower.split('')) {
      if (textLower.contains(char)) matchCount++;
    }
    return matchCount >= pattern.length * 0.7;
  }

  /// Calculate Levenshtein edit distance between two strings.
  ///
  /// Returns the minimum number of single-character edits (insertions,
  /// deletions, or substitutions) required to change one string into the other.
  static int levenshteinDistance(String a, String b) {
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
          matrix[i - 1][j] + 1, // deletion
          matrix[i][j - 1] + 1, // insertion
          matrix[i - 1][j - 1] + cost, // substitution
        ].reduce((a, b) => a < b ? a : b);
      }
    }

    return matrix[a.length][b.length];
  }
}
