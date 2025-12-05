import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../dart_context.dart';

/// Mix this in to any MCPServer to add Dart code intelligence via dart_context.
///
/// Provides a single `dart_query` tool that accepts DSL queries like:
/// - `def AuthRepository` - Find definition
/// - `refs login` - Find references
/// - `find Auth* kind:class` - Search with filters
/// - `members MyClass` - Get class members
/// - `hierarchy MyWidget` - Get type hierarchy
///
/// Example usage:
/// ```dart
/// class MyServer extends MCPServer with DartContextSupport {
///   // ...
/// }
/// ```
base mixin DartContextSupport on ToolsSupport, RootsTrackingSupport {
  /// Cached DartContext instances per project root.
  final Map<String, DartContext> _contexts = {};

  /// Whether to use cached indexes.
  bool get useCache => true;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);

    if (!supportsRoots) {
      log(
        LoggingLevel.warning,
        'DartContextSupport requires the "roots" capability which is not '
        'supported. dart_query tool has been disabled.',
      );
      return result;
    }

    registerTool(dartQueryTool, _handleDartQuery);

    return result;
  }

  @override
  Future<void> updateRoots() async {
    await super.updateRoots();

    final currentRoots = await roots;
    final currentRootUris = currentRoots.map((r) => r.uri).toSet();

    // Remove contexts for roots that no longer exist
    final removedRoots =
        _contexts.keys.where((r) => !currentRootUris.contains(r)).toList();
    for (final root in removedRoots) {
      await _contexts[root]?.dispose();
      _contexts.remove(root);
      log(LoggingLevel.debug, 'Removed DartContext for: $root');
    }

    // Add contexts for new roots (lazily - will be created on first query)
  }

  @override
  Future<void> shutdown() async {
    for (final context in _contexts.values) {
      await context.dispose();
    }
    _contexts.clear();
    await super.shutdown();
  }

  /// Get or create a DartContext for the given project path.
  Future<DartContext?> _getContextForPath(String filePath) async {
    final currentRoots = await roots;

    // Find the root that contains this file
    for (final root in currentRoots) {
      final rootPath = Uri.parse(root.uri).toFilePath();
      if (filePath.startsWith(rootPath)) {
        // Check if we already have a context for this root
        if (_contexts.containsKey(root.uri)) {
          return _contexts[root.uri];
        }

        // Create a new context
        try {
          log(LoggingLevel.info, 'Creating DartContext for: ${root.uri}');
          final context = await DartContext.open(
            rootPath,
            watch: true,
            useCache: useCache,
          );
          _contexts[root.uri] = context;

          log(
            LoggingLevel.info,
            'Indexed ${context.stats['files']} files, '
            '${context.stats['symbols']} symbols',
          );

          return context;
        } catch (e) {
          log(LoggingLevel.error, 'Failed to create DartContext: $e');
          return null;
        }
      }
    }

    return null;
  }

  /// Get context for the first available root.
  Future<DartContext?> _getDefaultContext() async {
    final currentRoots = await roots;
    if (currentRoots.isEmpty) return null;

    final firstRoot = currentRoots.first;
    final rootPath = Uri.parse(firstRoot.uri).toFilePath();

    if (_contexts.containsKey(firstRoot.uri)) {
      return _contexts[firstRoot.uri];
    }

    try {
      log(LoggingLevel.info, 'Creating DartContext for: ${firstRoot.uri}');
      final context = await DartContext.open(
        rootPath,
        watch: true,
        useCache: useCache,
      );
      _contexts[firstRoot.uri] = context;

      log(
        LoggingLevel.info,
        'Indexed ${context.stats['files']} files, '
        '${context.stats['symbols']} symbols',
      );

      return context;
    } catch (e) {
      log(LoggingLevel.error, 'Failed to create DartContext: $e');
      return null;
    }
  }

  Future<CallToolResult> _handleDartQuery(CallToolRequest request) async {
    final query = request.arguments?['query'] as String?;
    if (query == null || query.isEmpty) {
      return CallToolResult(
        content: [TextContent(text: 'Missing required argument `query`.')],
        isError: true,
      );
    }

    // Get context - use project hint if provided, otherwise use default
    final projectHint = request.arguments?['project'] as String?;
    DartContext? context;

    if (projectHint != null) {
      context = await _getContextForPath(projectHint);
    } else {
      context = await _getDefaultContext();
    }

    if (context == null) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'No Dart project found. Make sure roots are set and contain a pubspec.yaml.',
          ),
        ],
        isError: true,
      );
    }

    try {
      final result = await context.query(query);
      return CallToolResult(
        content: [TextContent(text: result.toText())],
        isError: false,
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Query error: $e')],
        isError: true,
      );
    }
  }

  /// The dart_query tool definition.
  static final dartQueryTool = Tool(
    name: 'dart_query',
    description: '''Query Dart codebase for semantic information using a simple DSL.

## Query Commands

| Query | Description | Example |
|-------|-------------|---------|
| `def <symbol>` | Find definition | `def AuthRepository` |
| `refs <symbol>` | Find all references | `refs login` |
| `sig <symbol>` | Get signature (no body) | `sig UserService` |
| `members <symbol>` | Get class members | `members UserService` |
| `impls <symbol>` | Find implementations | `impls Repository` |
| `hierarchy <symbol>` | Type hierarchy | `hierarchy MyWidget` |
| `source <symbol>` | Full source code | `source handleLogin` |
| `find <pattern>` | Search symbols | `find Auth*` |
| `which <symbol>` | Disambiguate matches | `which login` |
| `grep <pattern>` | Search in source | `grep /TODO\|FIXME/` |
| `calls <symbol>` | What does it call? | `calls AuthService.login` |
| `callers <symbol>` | What calls it? | `callers validateUser` |
| `imports <file>` | File imports | `imports lib/auth.dart` |
| `exports <path>` | Directory exports | `exports lib/` |
| `deps <symbol>` | Dependencies | `deps AuthService` |
| `files` | List indexed files | `files` |
| `stats` | Index statistics | `stats` |

## Pattern Syntax

| Pattern | Type | Example |
|---------|------|---------|
| `Auth*` | Glob | Wildcard matching |
| `/TODO\|FIXME/` | Regex | Regular expression |
| `/error/i` | Regex | Case-insensitive |
| `~authentcate` | Fuzzy | Typo-tolerant |
| `Class.method` | Qualified | Disambiguate |

## Filters

| Filter | Description | Example |
|--------|-------------|---------|
| `kind:<type>` | Symbol kind | `find * kind:class` |
| `in:<path>` | File path | `find * in:lib/auth/` |

## Grep Flags

| Flag | Description | Example |
|------|-------------|---------|
| `-i` | Case insensitive | `grep error -i` |
| `-v` | Invert match (non-matching) | `grep TODO -v` |
| `-w` | Word boundary | `grep test -w` |
| `-l` | Files only | `grep TODO -l` |
| `-c` | Count per file | `grep error -c` |
| `-C:n` | Context lines | `grep TODO -C:3` |
| `-A:n` | Lines after | `grep error -A:5` |
| `-B:n` | Lines before | `grep error -B:2` |
| `-m:n` | Max matches | `grep TODO -m:10` |

Kinds: class, method, function, field, enum, mixin, extension, getter, setter, constructor

## Pipe Queries

Chain queries with `|` to process results:
- `find Auth* kind:class | members` - Get members of all Auth classes
- `find *Service | refs` - Find refs for all services
- `grep TODO | refs` - Find refs for symbols containing TODOs

## Examples

```
def AuthRepository              # Definition with source
refs AuthService.login          # References to specific method
sig UserService                 # Class signature (methods as {})
find ~authentcate               # Fuzzy search (finds "authenticate")
grep /throw.*Exception/         # Find exception throws
which login                     # Show all "login" matches
find Auth* kind:class | members # Pipe: classes → their members
```

Semantic code navigation - understands definitions, references, types, call graphs, and relationships.''',
    annotations: ToolAnnotations(
      title: 'Dart Code Query',
      readOnlyHint: true,
    ),
    inputSchema: Schema.object(
      properties: {
        'query': Schema.string(
          description:
              'The query in DSL format. Examples: "def AuthRepository", "refs login", "find Auth* kind:class"',
        ),
        'project': Schema.string(
          description:
              'Optional path hint to select which project root to query (if multiple roots are configured).',
        ),
      },
      required: ['query'],
    ),
  );
}


