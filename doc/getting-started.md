# Getting Started

## Installation

### As a Library

```bash
dart pub add code_context
dart pub add dart_binding  # For Dart projects
```

### As a CLI Tool

```bash
dart pub global activate code_context
```

## Quick Start

### Library Usage

```dart
import 'package:code_context/code_context.dart';
import 'package:dart_binding/dart_binding.dart';

void main() async {
  // Register available language bindings
  CodeContext.registerBinding(DartBinding());

  // Open a project (auto-detects language)
  final context = await CodeContext.open('/path/to/project');

  // Query with DSL
  final result = await context.query('def AuthRepository');
  print(result.toText());

  // Find references
  final refs = await context.query('refs login');
  print(refs.toText());

  // Get class members
  final members = await context.query('members MyClass');
  print(members.toJson());

  // Load external dependencies (SDK, packages)
  if (!context.hasDependencies) {
    await context.loadDependencies();
  }

  // Query across dependencies
  final sdkResult = await context.query('find String kind:class');
  print(sdkResult.toText());

  // Cleanup
  await context.dispose();
}
```

### CLI Usage

```bash
# Find definition
code_context def AuthRepository

# Find references
code_context refs login

# Get class members
code_context members MyClass

# Search with filters
code_context "find Auth* kind:class"
code_context "find * kind:method in:lib/auth/"
code_context "find String kind:class lang:Dart"

# With external dependencies
code_context --with-deps "find BuildContext"

# Interactive mode
code_context -i

# Watch mode (shows file changes)
code_context -w

# Watch mode with auto-rerun query
code_context -w "find * kind:class"

# JSON output
code_context -f json refs login

# Force full re-index (skip cache)
code_context --no-cache stats

# Dart-specific commands
code_context dart:index-sdk /path/to/sdk
code_context dart:index-flutter
code_context dart:index-deps
code_context dart:list-indexes
```

## Query DSL

| Query | Description | Example |
|-------|-------------|---------|
| `def <symbol>` | Find definition | `def AuthRepository` |
| `refs <symbol>` | Find references | `refs login` |
| `find <pattern>` | Search symbols | `find Auth*` |
| `grep <pattern>` | Search source | `grep /TODO\|FIXME/` |
| `members <symbol>` | Class members | `members MyClass` |

## Filters

| Filter | Description | Example |
|--------|-------------|---------|
| `kind:<kind>` | Filter by symbol kind | `kind:class`, `kind:method` |
| `in:<path>` | Filter by file path | `in:lib/auth/` |
| `lang:<language>` | Filter by language | `lang:Dart` |

## Next Steps

- [Query DSL Reference](query-dsl.md) - Full command reference
- [Architecture](architecture.md) - How it works
- [MCP Integration](mcp-integration.md) - Using with Cursor/AI agents
- [Monorepo Support](monorepo.md) - Multi-package workspaces
- [Cross-Package Queries](cross-package-queries.md) - Querying SDK and dependencies
- [Analyzer Integration](analyzer-integration.md) - Sharing analyzer contexts
