# Query DSL Reference

code_context provides a human and LLM-friendly query DSL for navigating your codebase.

## Commands

| Query | Description | Example |
|-------|-------------|---------|
| `def <symbol>` | Find definition of a symbol | `def AuthRepository` |
| `refs <symbol>` | Find all references to a symbol | `refs login` |
| `sig <symbol>` | Get signature (without body) | `sig UserService` |
| `source <symbol>` | Get full source code | `source handleLogin` |
| `members <symbol>` | Get members of a class/mixin/extension | `members UserService` |
| `impls <symbol>` | Find implementations of a class/interface | `impls Repository` |
| `hierarchy <symbol>` | Full type hierarchy (supers + subs) | `hierarchy MyWidget` |
| `supertypes <symbol>` | Get supertypes of a class | `supertypes MyWidget` |
| `subtypes <symbol>` | Get subtypes/implementations | `subtypes Repository` |
| `find <pattern>` | Search for symbols matching pattern | `find Auth*` |
| `which <symbol>` | Disambiguate multiple matches | `which login` |
| `grep <pattern>` | Search in source code | `grep /TODO\|FIXME/` |
| `calls <symbol>` | What does this symbol call? | `calls AuthService.login` |
| `callers <symbol>` | What calls this symbol? | `callers validateUser` |
| `deps <symbol>` | Dependencies of a symbol | `deps AuthService` |
| `imports <file>` | What does this file import? | `imports lib/auth.dart` |
| `exports <path>` | What does this file/directory export? | `exports lib/` |
| `symbols <file>` | List all symbols in a file | `symbols lib/auth.dart` |
| `get <scip-id>` | Direct lookup by SCIP symbol ID | `get "scip-dart pub ..."` |
| `files` | List all indexed files | `files` |
| `stats` | Get index statistics | `stats` |

## Pattern Syntax

| Pattern | Type | Description | Example |
|---------|------|-------------|---------|
| `Auth*` | Glob | Wildcard matching | `*` = any chars, `?` = one char |
| `/TODO\|FIXME/` | Regex | Regular expression (between slashes) | |
| `/error/i` | Regex | Case-insensitive regex (with `i` flag) | |
| `~authentcate` | Fuzzy | Typo-tolerant matching | Finds "authenticate" |
| `login` | Literal | Exact match | |

## Qualified Names

When multiple symbols share the same name, use qualified names to disambiguate:

```bash
# Multiple "login" methods exist
refs AuthService.login      # References to login in AuthService only
def UserRepository.login    # Definition of login in UserRepository

# Discover all matches first
which login
# Output:
# 1. login [method] in AuthService (lib/auth/service.dart)
# 2. login [method] in UserRepository (lib/data/repo.dart)
# 3. LoginPage [class] (lib/ui/login_page.dart)
```

## Filters (for `find`)

| Filter | Description | Example |
|--------|-------------|---------|
| `kind:<kind>` | Filter by symbol kind | `find * kind:class` |
| `in:<path>` | Filter by file path prefix | `find * in:lib/auth/` |
| `lang:<language>` | Filter by programming language | `find String lang:Dart` |

**Symbol kinds:** `class`, `method`, `function`, `field`, `enum`, `mixin`, `extension`, `getter`, `setter`, `constructor`

**Languages:** `Dart` (more coming as language bindings are added)

## Grep Flags

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

## Pipe Queries

Chain queries with `|` to process results:

```bash
find Auth* kind:class | members   # Get members of all Auth classes
find *Service | refs              # Find refs for all services
grep TODO | refs                  # Find refs for symbols containing TODOs
members MyClass | source          # Get source for all members
```

## Examples

```bash
# Find all classes starting with "Auth"
find Auth* kind:class

# Find all methods in lib/auth/
find * kind:method in:lib/auth/

# Find definition with wildcard
def AuthRepo*

# Get hierarchy of a widget
hierarchy MyWidget

# Grep for patterns
grep /TODO|FIXME/              # Find TODOs and FIXMEs
grep /throw.*Exception/        # Find exception throws
grep error in:lib/             # Find "error" in lib/
grep TODO -c                   # Count TODOs per file
grep TODO -l                   # List files with TODOs
grep TODO -L                   # List files WITHOUT TODOs
grep test -w                   # Match whole word "test" only
grep /\w+Service/ -o           # Extract service class names
grep -F '$_controller'         # Search literal $ without escaping
grep TODO --exclude:test/*     # Skip test files

# Fuzzy matching (typo-tolerant)
find ~authentcate              # Finds "authenticate" despite typo
find ~respnse                  # Finds "response"

# Case-insensitive search
grep /error/i                  # Matches "Error", "ERROR", "error"

# Call graph queries
calls AuthService.login        # What does login() call?
callers validateUser           # What calls validateUser()?
deps AuthService               # All dependencies of AuthService

# Import/export analysis
imports lib/auth/service.dart  # What does this file import?
exports lib/auth/              # What does this directory export?

# File-scoped queries
symbols lib/auth/service.dart  # List all symbols in this file

# Direct symbol lookup (by SCIP ID)
get "scip-dart pub my_app 1.0.0 lib/auth.dart/AuthService#"

# Disambiguation workflow
which handleSubmit             # See all matches
refs FormWidget.handleSubmit   # Get refs for specific one
```

