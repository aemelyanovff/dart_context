# Monorepo Support

code_context automatically discovers and indexes all packages in any directory structure.

## Supported Structures

- **Melos monorepos** (projects with `melos.yaml`)
- **Dart 3.0+ pub workspaces** (pubspec.yaml with `workspace:` field)
- **Any folder** with multiple `pubspec.yaml` files

## Discovery

```bash
# List all discovered packages in a directory
code_context list-packages /path/to/monorepo
```

## Per-Package Indexes

For mono repos, indexes are stored per-package:

```
/path/to/monorepo/
└── packages/
    ├── my_core/
    │   └── .dart_context/           # Per-package index
    │       ├── index.scip
    │       └── manifest.json
    └── my_app/
        └── .dart_context/
            ├── index.scip
            └── manifest.json
```

## Cross-Package Queries

When opening a directory with multiple packages:
- All packages are discovered recursively
- Cross-package queries work automatically
- A single file watcher at the root handles all packages
- Each package maintains its own incremental cache

```dart
import 'package:code_context/code_context.dart';
import 'package:dart_binding/dart_binding.dart';

// Register bindings
CodeContext.registerBinding(DartBinding());

// Opening a mono repo
final context = await CodeContext.open('/path/to/monorepo');

// Cross-package queries work seamlessly
final result = await context.query('refs SharedUtils'); // Finds refs in other packages

// Find which package owns a file
final pkg = context.findPackageForPath('/path/to/monorepo/packages/my_app/lib/main.dart');
print(pkg?.name); // my_app
```

## Example: Melos Monorepo

```
my_monorepo/
├── melos.yaml
├── packages/
│   ├── core/
│   │   ├── pubspec.yaml
│   │   └── lib/
│   ├── api/
│   │   ├── pubspec.yaml
│   │   └── lib/
│   └── app/
│       ├── pubspec.yaml
│       └── lib/
└── .dart_context/          # Optional: root-level index
```

```bash
# Open the monorepo root
code_context -p /path/to/my_monorepo

# Query across all packages
code_context refs CoreService    # Finds refs in core, api, and app
```

## Example: Pub Workspace

```yaml
# pubspec.yaml (root)
name: my_workspace
publish_to: none

workspace:
  - packages/core
  - packages/api
  - packages/app
```

```bash
# Open the workspace
code_context -p /path/to/my_workspace

# All workspace packages are indexed
code_context stats
```

