# Cross-Package Queries

code_context supports querying across external dependencies (SDK, Flutter, pub packages) by pre-computing their indexes.

## Pre-Indexing Commands

```bash
# Pre-index the Dart SDK (do this once per SDK version)
code_context dart:index-sdk /path/to/dart-sdk

# Pre-index Flutter SDK packages (do this once per Flutter version)
code_context dart:index-flutter /path/to/flutter

# Pre-index all dependencies from pubspec.lock
code_context dart:index-deps

# List available pre-computed indexes
code_context dart:list-indexes
```

## Using Pre-Computed Indexes

```bash
# Query with dependencies loaded
code_context --with-deps "hierarchy MyWidget"

# Search dependencies with grep -D flag
code_context --with-deps "grep Navigator -D -l"

# Filter by language (useful for SDK queries)
code_context --with-deps "find String kind:class lang:Dart"
```

## Global Cache Structure

Indexes are stored in `~/.dart_context/` with a structure that mirrors pub cache:

```
~/.dart_context/                      # Global cache
├── sdk/
│   └── 3.7.1/index.scip              # Dart SDK (versioned)
├── flutter/
│   └── 3.32.0/flutter/index.scip     # Flutter SDK packages
├── hosted/
│   ├── collection-1.18.0/index.scip  # Pub packages
│   └── analyzer-6.3.0/index.scip
└── git/
    └── fluxon-bfef6c5e/index.scip    # Git dependencies
```

## Example Queries

With pre-computed indexes, you can:

```bash
# See widget hierarchy
code_context --with-deps "hierarchy SignatureVisitor"
# Output: Shows that it extends RecursiveAstVisitor from analyzer

# Get full Flutter supertypes
code_context --with-deps "supertypes MyWidget"
# Output: Full hierarchy including StatelessWidget, Widget, etc.

# Find all uses of a Flutter class
code_context --with-deps "refs StatefulWidget"
# Output: All files using StatefulWidget

# Search in dependencies
code_context --with-deps "grep /build.*Widget/ -D"
# Output: Matches in Flutter source code

# Find SDK types with language filter
code_context --with-deps "find int kind:class lang:Dart"
```

## Loading Dependencies Programmatically

```dart
import 'package:code_context/code_context.dart';
import 'package:dart_binding/dart_binding.dart';

CodeContext.registerBinding(DartBinding());
final context = await CodeContext.open('/path/to/project');

// Load all dependencies from pubspec.lock
final result = await context.loadDependencies();
print('Loaded ${result.loaded} packages');
print('Skipped ${result.skipped} (already cached)');
print('Failed: ${result.failed}');

// Now queries include dependencies
final hierarchy = await context.query('hierarchy MyWidget');
```

## Performance Considerations

- Pre-indexing takes time (~30s for SDK, ~1-2 min for Flutter SDK)
- Once indexed, loading is instant (just reads from disk)
- Only index what you need (SDK vs Flutter vs all deps)
- Indexes are shared across projects (stored globally)
- SDK/Flutter indexes are versioned (no conflicts between versions)

**Note**: Pre-indexing is optional. By default, code_context only indexes your project code.
