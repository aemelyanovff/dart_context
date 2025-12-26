# dart_context

Lightweight semantic code intelligence for Dart. Query your codebase with a simple DSL.

## Features

- **Index caching**: Persistent cache for instant startup (~300ms vs ~10s)
- **Incremental indexing**: Watches files and updates the index automatically
- **Simple query DSL**: Human and LLM-friendly query language
- **Fast lookups**: O(1) symbol lookups via in-memory indexes
- **SCIP-compatible**: Uses [scip-dart](https://github.com/Workiva/scip-dart) for standard code intelligence format

## Installation

```bash
dart pub add dart_context
```

Or for CLI usage:

```bash
dart pub global activate dart_context
```

## Usage

### As a Library

```dart
import 'package:dart_context/dart_context.dart';

void main() async {
  // Open a project
  final context = await DartContext.open('/path/to/project');

  // Query with DSL
  final result = await context.query('def AuthRepository');
  print(result.toText());

  // Find references
  final refs = await context.query('refs login');
  print(refs.toText());

  // Get class members
  final members = await context.query('members MyClass');
  print(members.toJson());

  // Watch for updates
  context.updates.listen((update) {
    print('Index updated: $update');
  });

  // Cleanup
  await context.dispose();
}
```

### CLI

```bash
# Find definition
dart_context def AuthRepository

# Find references
dart_context refs login

# Get class members
dart_context members MyClass

# Search with filters
dart_context "find Auth* kind:class"
dart_context "find * kind:method in:lib/auth/"

# Interactive mode
dart_context -i

# Watch mode (shows file changes)
dart_context -w

# Watch mode with auto-rerun query
dart_context -w "find * kind:class"

# JSON output
dart_context -f json refs login

# Force full re-index (skip cache)
dart_context --no-cache stats
```

## Query DSL

| Query | Description |
|-------|-------------|
| `def <symbol>` | Find definition of a symbol |
| `refs <symbol>` | Find all references to a symbol |
| `members <symbol>` | Get members of a class/mixin/extension |
| `impls <symbol>` | Find implementations of a class/interface |
| `supertypes <symbol>` | Get supertypes of a class |
| `subtypes <symbol>` | Get subtypes (implementations) |
| `hierarchy <symbol>` | Full hierarchy (supertypes + subtypes) |
| `source <symbol>` | Get source code for a symbol |
| `find <pattern>` | Search for symbols matching pattern |
| `which <symbol>` | Show all matches (for disambiguation) |
| `grep <pattern>` | Search in source code (like grep) |
| `calls <symbol>` | What does this symbol call? |
| `callers <symbol>` | What calls this symbol? |
| `imports <file>` | What does this file import? |
| `exports <path>` | What does this file/directory export? |
| `deps <symbol>` | Dependencies of a symbol |
| `sig <symbol>` | Get signature (without body) |
| `files` | List all indexed files |
| `stats` | Get index statistics |

### Qualified Names (Disambiguation)

When multiple symbols have the same name, use qualified names:

```bash
# Multiple "login" methods exist - use qualified name
refs AuthService.login      # References to login in AuthService only
def UserRepository.login    # Definition of login in UserRepository

# Discover all matches first
which login
# Output:
# 1. login [method] in AuthService (lib/auth/service.dart)
# 2. login [method] in UserRepository (lib/data/repo.dart)
# 3. LoginPage [class] (lib/ui/login_page.dart)
```

### Pattern Syntax

| Pattern | Type | Description |
|---------|------|-------------|
| `Auth*` | Glob | Wildcard matching (* = any chars, ? = one char) |
| `/TODO\|FIXME/` | Regex | Regular expression (between slashes) |
| `/error/i` | Regex | Case-insensitive regex (with `i` flag) |
| `~authentcate` | Fuzzy | Typo-tolerant matching (finds "authenticate") |
| `login` | Literal | Exact match |

### Filters (for `find`)

| Filter | Description |
|--------|-------------|
| `kind:<kind>` | Filter by symbol kind (class, method, function, field, etc.) |
| `in:<path>` | Filter by file path prefix |

### Grep Flags

| Flag | Description | Example |
|------|-------------|---------|
| `-i` | Case insensitive | `grep error -i` |
| `-v` | Invert match (non-matching lines) | `grep TODO -v` |
| `-w` | Word boundary (whole words only) | `grep test -w` |
| `-l` | List files with matches only | `grep TODO -l` |
| `-L` | List files without matches | `grep TODO -L` |
| `-c` | Count matches per file | `grep error -c` |
| `-o` | Show only matched text | `grep /\w+Error/ -o` |
| `-F` | Fixed strings (literal, no regex) | `grep -F '$variable'` |
| `-M` | Multiline matching | `grep /class.*\{/ -M` |
| `-D` | Search external dependencies | `grep StatelessWidget -D` |
| `-C:n` | Context lines (before + after) | `grep TODO -C:3` |
| `-A:n` | Lines after match | `grep error -A:5` |
| `-B:n` | Lines before match | `grep error -B:2` |
| `-m:n` | Max matches per file | `grep TODO -m:10` |
| `--include:glob` | Only search matching files | `grep error --include:*.dart` |
| `--exclude:glob` | Skip matching files | `grep TODO --exclude:test/*` |

### Examples

```bash
# Find all classes starting with "Auth"
find Auth* kind:class

# Find all methods in lib/auth/
find * kind:method in:lib/auth/

# Find definition with wildcard
def AuthRepo*

# Get hierarchy of a widget
hierarchy MyWidget

# Disambiguation workflow
which handleSubmit         # See all matches
refs FormWidget.handleSubmit  # Get refs for specific one

# Grep for patterns in source code
grep /TODO|FIXME/          # Find TODOs and FIXMEs
grep /throw.*Exception/    # Find exception throws
grep error in:lib/         # Find "error" in lib/
grep TODO -c               # Count TODOs per file
grep TODO -l               # List files with TODOs
grep TODO -L               # List files WITHOUT TODOs
grep test -w               # Match whole word "test" only
grep /\w+Service/ -o       # Extract service class names
grep -F '$_controller'     # Search literal $ without escaping
grep TODO --exclude:test/* # Skip test files

# Fuzzy matching (typo-tolerant)
find ~authentcate          # Finds "authenticate" despite typo
find ~respnse              # Finds "response"

# Case-insensitive search
grep /error/i              # Matches "Error", "ERROR", "error"

# Call graph queries
calls AuthService.login    # What does login() call?
callers validateUser       # What calls validateUser()?
deps AuthService           # All dependencies of AuthService

# Import/export analysis
imports lib/auth/service.dart  # What does this file import?
exports lib/auth/              # What does this directory export?

# Pipe queries (chain multiple queries)
find Auth* | refs          # Find references for all Auth* symbols
members MyClass | source   # Get source for all members
find *Service | calls      # What do all services call?
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           dart_context                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────────────┐│
│  │ LLM / Agent  │────▶│ Query String │────▶│    QueryExecutor         ││
│  │              │     │ "refs login" │     │                          ││
│  └──────────────┘     └──────────────┘     │  parse() → execute()     ││
│                                            └────────────┬─────────────┘│
│                                                         │              │
│                                                         ▼              │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                        ScipIndex                                 │  │
│  │  O(1) lookups: symbol → info, symbol → references, file → doc    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                  ▲                                     │
│                                  │                                     │
│  ┌───────────────────────────────┴──────────────────────────────────┐  │
│  │                  IncrementalScipIndexer                          │  │
│  │  File watching + hash tracking + Dart analyzer + SCIP generation │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## How It Works

1. **Cache Check**: On `open()`, looks for valid cache in `.dart_context/` directory
2. **Initial/Incremental Index**: Full scan if no cache, or only changed files if cache exists
3. **File Watching**: Uses filesystem events to detect changes
4. **Incremental Updates**: Only re-analyzes changed files (via SHA-256 hash comparison)
5. **Cache Persistence**: Saves index to disk after updates for fast subsequent startups
6. **Query Execution**: Parses DSL and executes against in-memory indexes

### Caching

The index is cached in `.dart_context/` within your project:
- `index.scip` - Serialized SCIP protobuf index
- `manifest.json` - File hashes for cache validation

Use `--no-cache` to force a full re-index:
```bash
dart_context --no-cache -p /path/to/project stats
```

### Cross-Package Queries

dart_context supports querying across external dependencies (SDK, Flutter, pub packages) by pre-computing their indexes:

```bash
# Pre-index Flutter SDK packages (do this once per Flutter version)
dart_context index-flutter /path/to/flutter

# Pre-index the Dart SDK (do this once per SDK version)
dart_context index-sdk /path/to/dart-sdk

# Pre-index all dependencies from pubspec.lock
dart_context index-deps

# List available pre-computed indexes
dart_context list-indexes

# Query with dependencies loaded
dart_context --with-deps "hierarchy MyWidget"

# Search dependencies with grep -D flag
dart_context --with-deps "grep Navigator -D -l"
```

Indexes are stored in `~/.dart_context/` with a structure that mirrors pub cache:
```
~/.dart_context/                      # Global cache
├── sdk/
│   └── 3.2.0/index.scip             # Dart SDK indexes
├── flutter/
│   └── 3.32.0/flutter/index.scip    # Flutter SDK packages
├── hosted/
│   ├── collection-1.18.0/index.scip # Pub packages
│   └── analyzer-6.3.0/index.scip
└── git/
    └── fluxon-bfef6c5e/index.scip   # Git dependencies
```

This enables queries like:
- `hierarchy SignatureVisitor` - See that it extends `RecursiveAstVisitor` from analyzer
- `supertypes MyWidget` - Full Flutter widget hierarchy
- `refs StatefulWidget` - Find all uses of Flutter's StatefulWidget

**Note**: Pre-indexing is optional and takes time. By default, dart_context only indexes your project code.

### Mono Repo / Workspace Support

dart_context automatically detects and supports mono repo workspaces:

- **Melos workspaces** (projects with `melos.yaml`)
- **Dart 3.0+ pub workspaces** (pubspec.yaml with `workspace:` field)

```bash
# Show workspace information
dart_context workspace info

# Index all packages in the workspace
dart_context workspace index

# Sync package indexes to workspace registry
dart_context workspace sync
```

For mono repos, indexes are stored in two locations:

```
/path/to/monorepo/
├── .dart_context/                    # Workspace registry
│   ├── workspace.json                # Workspace metadata
│   └── local/                        # Local package indexes
│       ├── hologram_core/index.scip
│       └── hologram_shared/index.scip
└── packages/
    └── hologram_core/
        └── .dart_context/            # Per-package working index
            └── index.scip
```

When opening a project that's part of a workspace:
- Cross-package queries work automatically between workspace packages
- A single file watcher at the workspace root handles all packages
- Changes to one package update both its index and the workspace registry

```dart
// Opening a workspace package
final context = await DartContext.open('/path/to/monorepo/packages/my_app');

// Workspace info is available
print(context.workspace?.type); // melos, pubWorkspace, or single
print(context.workspace?.packages.length);

// Cross-package queries work seamlessly
final result = await context.query('refs SharedUtils'); // Finds refs in other packages
```

## Performance

| Metric | Value |
|--------|-------|
| Initial indexing | ~10-15s for 85 files |
| Cached startup | ~300ms (35x faster) |
| Incremental update | ~100-200ms per file |
| Query execution | <10ms |
| Cache size | ~2.5MB for 85 files |

## MCP Integration

### Using with Cursor

A ready-to-use MCP server is included. Add to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "dart_context": {
      "type": "stdio",
      "command": "dart",
      "args": ["run", "/path/to/dart_context/bin/mcp_server.dart"]
    }
  }
}
```

Restart Cursor, then ask Claude to use the tools:
- "Use dart_status to check the index"
- "Use dart_index_flutter to index the Flutter SDK"
- "Use dart_query to find references to MyClass"

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `dart_query` | Query codebase with DSL (refs, def, find, grep, etc.) |
| `dart_index_flutter` | Index Flutter SDK packages (~1 min, one-time) |
| `dart_index_deps` | Index pub dependencies from pubspec.lock |
| `dart_refresh` | Refresh project index and reload dependencies |
| `dart_status` | Show index status (files, symbols, packages loaded) |

### Custom MCP Server

Add `DartContextSupport` to your own MCP server:

```dart
import 'package:dart_context/dart_context_mcp.dart';
import 'package:dart_mcp/server.dart';

base class MyServer extends MCPServer 
    with LoggingSupport, ToolsSupport, RootsTrackingSupport, DartContextSupport {
  // Your server implementation
}
```

The tools automatically:
- Index project roots on first query
- Cache indexes for fast subsequent queries  
- Watch for file changes and update incrementally
- Load pre-computed SDK/package indexes
- Watch package_config.json and notify when deps change

## External Analyzer Integration

When integrating with an existing analyzer (e.g., HologramAnalyzer), you can avoid
creating duplicate analyzer contexts by using an adapter:

```dart
import 'package:dart_context/dart_context.dart';
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

### With Fluxon Service (Hologram)

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

### Incremental Updates from Resolved Units

If you already have resolved units, you can update the index directly:

```dart
// When HologramAnalyzer completes analysis
analyzer.onFileDartAnalysisCompleted = (filePath, result) {
  if (result is ResolvedUnitResult) {
    indexer.indexWithResolvedUnit(filePath, result);
  }
};
```

## TODO

- Add path regex filter for `find`/`grep` (e.g., `path:/core\/(infra|db)\//`).

## Related Projects

- [scip-dart](https://github.com/Workiva/scip-dart) - SCIP indexer for Dart
- [SCIP](https://github.com/sourcegraph/scip) - Code Intelligence Protocol
- [dart_graph](https://github.com/example/dart_graph) - Full graph-based code intelligence (heavier)

## License

MIT

