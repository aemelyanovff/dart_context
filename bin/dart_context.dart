import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_context/dart_context.dart';
import 'package:dart_context/src/index/external_index_builder.dart';
import 'package:dart_context/src/index/index_registry.dart';
import 'package:dart_context/src/index/scip_index.dart';

void main(List<String> arguments) async {
  // Check for subcommands first
  if (arguments.isNotEmpty) {
    switch (arguments.first) {
      case 'index-sdk':
        await _indexSdk(arguments.skip(1).toList());
        return;
      case 'index-flutter':
        await _indexFlutter(arguments.skip(1).toList());
        return;
      case 'index-deps':
        await _indexDependencies(arguments.skip(1).toList());
        return;
      case 'list-indexes':
        await _listIndexes();
        return;
    }
  }

  final parser = ArgParser()
    ..addOption(
      'project',
      abbr: 'p',
      help: 'Path to the Dart project (defaults to current directory)',
      defaultsTo: '.',
    )
    ..addOption(
      'format',
      abbr: 'f',
      help: 'Output format: text or json',
      defaultsTo: 'text',
      allowed: ['text', 'json'],
    )
    ..addFlag(
      'watch',
      abbr: 'w',
      help: 'Watch for file changes and show updates',
      defaultsTo: false,
    )
    ..addFlag(
      'interactive',
      abbr: 'i',
      help: 'Run in interactive REPL mode',
      defaultsTo: false,
    )
    ..addFlag(
      'no-cache',
      help: 'Disable cache and force full re-index',
      defaultsTo: false,
    )
    ..addFlag(
      'with-deps',
      help: 'Load pre-indexed dependencies for cross-package queries',
      defaultsTo: false,
    )
    ..addFlag(
      'help',
      abbr: 'h',
      help: 'Show this help message',
      negatable: false,
    );

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error: $e');
    _printUsage(parser);
    exit(1);
  }

  if (args['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  final projectPath = args['project'] as String;
  final format = args['format'] as String;
  final watch = args['watch'] as bool;
  final interactive = args['interactive'] as bool;
  final noCache = args['no-cache'] as bool;
  final withDeps = args['with-deps'] as bool;

  // Validate project path
  final pubspecFile = File('$projectPath/pubspec.yaml');
  if (!await pubspecFile.exists()) {
    stderr.writeln('Error: No pubspec.yaml found in $projectPath');
    stderr.writeln('Make sure you are in a Dart project directory.');
    exit(1);
  }

  stderr.writeln('Opening project: $projectPath');
  if (withDeps) {
    stderr.writeln('Loading pre-indexed dependencies...');
  }

  DartContext? context;
  try {
    final stopwatch = Stopwatch()..start();
    context = await DartContext.open(
      projectPath,
      watch: watch || interactive,
      useCache: !noCache,
      loadDependencies: withDeps,
    );
    stopwatch.stop();

    final depsInfo = withDeps && context.hasDependencies
        ? ', ${context.registry!.packageIndexes.length} packages loaded'
        : '';
    stderr.writeln(
      'Indexed ${context.stats['files']} files, '
      '${context.stats['symbols']} symbols'
      '$depsInfo '
      '(${stopwatch.elapsedMilliseconds}ms)',
    );

    if (interactive) {
      await _runInteractive(context, format);
    } else if (watch) {
      // Watch mode: show updates and optionally re-run query
      final query = args.rest.isNotEmpty ? args.rest.join(' ') : null;
      await _runWatch(context, format, query);
    } else if (args.rest.isEmpty) {
      // No query provided, show stats
      final result = await context.query('stats');
      _printResult(result, format);
    } else {
      // Execute the query from command line
      final query = args.rest.join(' ');
      final result = await context.query(query);
      _printResult(result, format);
    }
  } catch (e, st) {
    stderr.writeln('Error: $e');
    if (Platform.environment['DEBUG'] != null) {
      stderr.writeln(st);
    }
    exit(1);
  } finally {
    await context?.dispose();
  }
}

void _printUsage(ArgParser parser) {
  stdout.writeln(
      'dart_context - Lightweight semantic code intelligence for Dart');
  stdout.writeln('');
  stdout.writeln('Usage: dart_context [options] <query>');
  stdout.writeln('       dart_context <subcommand> [args]');
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln(parser.usage);
  stdout.writeln('');
  stdout.writeln('Subcommands:');
  stdout.writeln('  index-sdk <sdk-path>   Pre-index the Dart SDK');
  stdout.writeln('  index-flutter [path]   Pre-index Flutter packages');
  stdout.writeln('  index-deps             Pre-index all pub dependencies');
  stdout
      .writeln('  list-indexes           List available pre-computed indexes');
  stdout.writeln('');
  stdout.writeln('Query DSL:');
  stdout.writeln('  def <symbol>           Find definition');
  stdout.writeln('  refs <symbol>          Find references');
  stdout.writeln('  sig <symbol>           Get signature (without body)');
  stdout.writeln('  source <symbol>        Get full source code');
  stdout.writeln('  members <symbol>       Get class members');
  stdout.writeln('  impls <symbol>         Find implementations');
  stdout.writeln('  supertypes <symbol>    Get supertypes');
  stdout.writeln('  subtypes <symbol>      Get subtypes');
  stdout.writeln('  hierarchy <symbol>     Full hierarchy');
  stdout.writeln('  calls <symbol>         What does symbol call?');
  stdout.writeln('  callers <symbol>       What calls symbol?');
  stdout.writeln('  deps <symbol>          Dependencies of symbol');
  stdout.writeln('  find <pattern>         Search symbols');
  stdout.writeln('  which <symbol>         Show all matches (disambiguation)');
  stdout.writeln('  grep <pattern>         Search source code');
  stdout.writeln('  imports <file>         File imports');
  stdout.writeln('  exports <path>         File/directory exports');
  stdout.writeln('  files                  List indexed files');
  stdout.writeln('  stats                  Index statistics');
  stdout.writeln('');
  stdout.writeln('Filters:');
  stdout.writeln(
      '  kind:<kind>            Filter by kind (class, method, function, etc.)');
  stdout.writeln('  in:<path>              Filter by file path prefix');
  stdout.writeln('');
  stdout.writeln('Grep Flags:');
  stdout.writeln('  -i  Case insensitive     -c  Count per file');
  stdout.writeln('  -l  Files with matches   -L  Files without matches');
  stdout.writeln('  -o  Only matching text   -w  Word boundary');
  stdout.writeln('  -v  Invert match         -F  Fixed strings (literal)');
  stdout.writeln('  -C:n Context lines       -A:n/-B:n After/before lines');
  stdout.writeln('  --include:glob  Only search matching files');
  stdout.writeln('  --exclude:glob  Skip matching files');
  stdout.writeln('');
  stdout.writeln('Pipe Queries:');
  stdout.writeln('  find Auth* | members     Chain queries with |');
  stdout.writeln('  grep TODO | refs         Process results through pipes');
  stdout.writeln('');
  stdout.writeln('Examples:');
  stdout.writeln('  dart_context def AuthRepository');
  stdout.writeln('  dart_context refs login');
  stdout.writeln('  dart_context "find Auth* kind:class"');
  stdout.writeln('  dart_context "grep TODO -c"');
  stdout.writeln('  dart_context "grep /TODO|FIXME/ -l"');
  stdout.writeln('  dart_context "find *Service | members"');
  stdout.writeln('  dart_context -i                    # Interactive mode');
  stdout.writeln('  dart_context -w                    # Watch mode');
  stdout.writeln(
      '  dart_context -w "find * kind:class"  # Watch + re-run on changes');
  stdout.writeln('');
  stdout.writeln('Pre-indexing dependencies (for cross-package queries):');
  stdout.writeln('  dart_context index-sdk /path/to/dart-sdk');
  stdout.writeln('  dart_context index-deps');
  stdout.writeln('  dart_context --with-deps "hierarchy MyClass"');
}

void _printResult(QueryResult result, String format) {
  if (format == 'json') {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.toJson()));
  } else {
    stdout.writeln(result.toText());
  }
}

Future<void> _runWatch(
  DartContext context,
  String format,
  String? query,
) async {
  // Run initial query if provided
  if (query != null) {
    final result = await context.query(query);
    _printResult(result, format);
    stdout.writeln('');
  }

  stderr.writeln('Watching for changes... (Ctrl+C to stop)');
  stderr.writeln('');

  final completer = Completer<void>();

  // Handle Ctrl+C
  late StreamSubscription<ProcessSignal> sigintSubscription;
  sigintSubscription = ProcessSignal.sigint.watch().listen((_) {
    stderr.writeln('');
    stderr.writeln('Stopping watch...');
    sigintSubscription.cancel();
    completer.complete();
  });

  // Watch for file updates
  final subscription = context.updates.listen((update) async {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);

    if (update is FileUpdatedUpdate) {
      stderr.writeln('[$timestamp] Updated: ${update.path}');

      // Re-run query if provided
      if (query != null) {
        final result = await context.query(query);
        stdout.writeln('');
        _printResult(result, format);
      }
    } else if (update is FileRemovedUpdate) {
      stderr.writeln('[$timestamp] Removed: ${update.path}');

      // Re-run query if provided
      if (query != null) {
        final result = await context.query(query);
        stdout.writeln('');
        _printResult(result, format);
      }
    } else if (update is IndexErrorUpdate) {
      stderr.writeln('[$timestamp] Error: ${update.path} - ${update.message}');
    }
  });

  try {
    await completer.future;
  } finally {
    await subscription.cancel();
  }

  stderr.writeln('Watch mode stopped.');
}

Future<void> _runInteractive(DartContext context, String format) async {
  stdout.writeln('');
  stdout.writeln('Interactive mode. Type "help" for commands, "quit" to exit.');
  stdout.writeln('');

  // Watch for file updates
  final subscription = context.updates.listen((update) {
    stderr.writeln('  [update] $update');
  });

  try {
    while (true) {
      stdout.write('> ');
      final line = stdin.readLineSync();

      if (line == null || line == 'quit' || line == 'exit') {
        break;
      }

      if (line.isEmpty) continue;

      if (line == 'help') {
        stdout.writeln('Query Commands:');
        stdout.writeln('  def <symbol>          Find definition');
        stdout.writeln('  refs <symbol>         Find references');
        stdout.writeln('  sig <symbol>          Get signature (without body)');
        stdout.writeln('  source <symbol>       Get full source code');
        stdout.writeln('  members <symbol>      Get class members');
        stdout.writeln('  impls <symbol>        Find implementations');
        stdout.writeln('  supertypes <symbol>   Get supertypes');
        stdout.writeln('  subtypes <symbol>     Get subtypes');
        stdout.writeln('  hierarchy <symbol>    Full hierarchy (super + sub)');
        stdout.writeln('  calls <symbol>        What does it call?');
        stdout.writeln('  callers <symbol>      What calls it?');
        stdout.writeln('  deps <symbol>         Dependencies of a symbol');
        stdout.writeln('  find <pattern>        Search symbols');
        stdout.writeln(
            '  which <symbol>        Show all matches (disambiguation)');
        stdout.writeln('  grep <pattern>        Search in source code');
        stdout.writeln('  imports <file>        What does this file import?');
        stdout.writeln('  exports <path>        What does this path export?');
        stdout.writeln('');
        stdout.writeln('Pattern Syntax:');
        stdout.writeln('  Auth*                 Glob wildcard matching');
        stdout.writeln('  /TODO|FIXME/          Regex pattern');
        stdout.writeln('  /error/i              Case-insensitive regex');
        stdout.writeln('  ~authentcate          Fuzzy (typo-tolerant)');
        stdout
            .writeln('  Class.method          Qualified name (disambiguation)');
        stdout.writeln('');
        stdout.writeln('Filters (for find/grep):');
        stdout.writeln('  kind:class            Filter by kind');
        stdout.writeln('  in:lib/auth/          Filter by path');
        stdout.writeln('');
        stdout.writeln('Grep Flags:');
        stdout.writeln('  -i                    Case insensitive');
        stdout.writeln('  -c                    Count matches per file');
        stdout.writeln('  -l                    List files with matches');
        stdout.writeln('  -L                    List files without matches');
        stdout.writeln('  -o                    Show only matching text');
        stdout.writeln('  -w                    Word boundary matching');
        stdout.writeln('  -v                    Invert match');
        stdout
            .writeln('  -C:3                  Context lines (before + after)');
        stdout.writeln('  -A:5 -B:2             Lines after / before');
        stdout.writeln('');
        stdout.writeln('Pipe Queries:');
        stdout.writeln('  find Auth* | members  Chain queries with |');
        stdout.writeln('  grep TODO | refs      Process results through pipes');
        stdout.writeln('');
        stdout.writeln('Utility:');
        stdout.writeln('  files                 List indexed files');
        stdout.writeln('  stats                 Index statistics');
        stdout.writeln('  refresh               Refresh all files');
        stdout.writeln('  quit                  Exit');
        continue;
      }

      if (line == 'refresh') {
        stderr.writeln('Refreshing...');
        await context.refreshAll();
        stderr.writeln('Done. ${context.stats['symbols']} symbols indexed.');
        continue;
      }

      final result = await context.query(line);
      _printResult(result, format);
      stdout.writeln('');
    }
  } finally {
    await subscription.cancel();
  }

  stdout.writeln('Goodbye!');
}

/// Index the Dart/Flutter SDK for cross-package queries.
Future<void> _indexSdk(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart_context index-sdk <sdk-path>');
    stderr.writeln('');
    stderr.writeln('Example:');
    stderr.writeln('  dart_context index-sdk /opt/flutter/bin/cache/dart-sdk');
    stderr.writeln('  dart_context index-sdk \$(dirname \$(which dart))/..');
    exit(1);
  }

  final sdkPath = args.first;
  final sdkDir = Directory(sdkPath);

  if (!await sdkDir.exists()) {
    stderr.writeln('Error: SDK path does not exist: $sdkPath');
    exit(1);
  }

  // Check for version file
  final versionFile = File('$sdkPath/version');
  if (!await versionFile.exists()) {
    stderr.writeln('Error: Not a valid Dart SDK (no version file found)');
    exit(1);
  }

  final version = (await versionFile.readAsString()).trim();
  stderr.writeln('Indexing Dart SDK $version...');
  stderr.writeln('This may take a few minutes.');
  stderr.writeln('');

  // Create a temporary registry for building
  final tempIndex = await ScipIndex.loadFromFile(
    '$sdkPath/lib/core/core.dart', // This won't work, need to create empty index
    projectRoot: sdkPath,
  ).catchError((_) async {
    // Create minimal index just to bootstrap the registry
    return ScipIndex.empty(projectRoot: sdkPath);
  });

  final registry = IndexRegistry(projectIndex: tempIndex);
  final builder = ExternalIndexBuilder(registry: registry);

  final stopwatch = Stopwatch()..start();
  final result = await builder.indexSdk(sdkPath);
  stopwatch.stop();

  if (result.success) {
    stdout.writeln('✓ SDK indexed successfully');
    stdout.writeln('  Version: ${result.stats?['version']}');
    stdout.writeln('  Symbols: ${result.stats?['symbols']}');
    stdout.writeln('  Files: ${result.stats?['files']}');
    stdout.writeln('  Time: ${stopwatch.elapsed.inSeconds}s');
    stdout.writeln('');
    stdout.writeln('Index saved to: ${registry.sdkIndexPath(version)}');
  } else {
    stderr.writeln('✗ Failed to index SDK: ${result.error}');
    exit(1);
  }
}

/// Index the Flutter framework packages.
///
/// This indexes the main Flutter packages (flutter, flutter_test, etc.)
/// to enable queries like `hierarchy StatelessWidget`.
Future<void> _indexFlutter(List<String> args) async {
  // Default to FLUTTER_ROOT env var or common paths
  String? flutterPath;
  if (args.isNotEmpty) {
    flutterPath = args.first;
  } else {
    flutterPath = Platform.environment['FLUTTER_ROOT'];
    if (flutterPath == null) {
      // Try to find Flutter from the flutter command
      try {
        final result = await Process.run('which', ['flutter']);
        if (result.exitCode == 0) {
          final flutterBin = result.stdout.toString().trim();
          // Flutter binary is at FLUTTER_ROOT/bin/flutter
          flutterPath = Directory(flutterBin).parent.parent.path;
        }
      } catch (_) {}
    }
  }

  if (flutterPath == null || !await Directory(flutterPath).exists()) {
    stderr.writeln('Usage: dart_context index-flutter [flutter-path]');
    stderr.writeln('');
    stderr.writeln(
        'If no path is provided, uses FLUTTER_ROOT environment variable');
    stderr.writeln('or tries to find Flutter from PATH.');
    stderr.writeln('');
    stderr.writeln('Example:');
    stderr.writeln('  dart_context index-flutter');
    stderr.writeln('  dart_context index-flutter /opt/flutter');
    exit(1);
  }

  final packagesPath = '$flutterPath/packages';
  if (!await Directory(packagesPath).exists()) {
    stderr.writeln('Error: Flutter packages not found at $packagesPath');
    exit(1);
  }

  // Get Flutter version
  final versionFile = File('$flutterPath/version');
  final version = await versionFile.exists()
      ? (await versionFile.readAsString()).trim()
      : 'unknown';

  stderr.writeln('Indexing Flutter $version packages...');
  stderr.writeln('Path: $flutterPath');
  stderr.writeln('');

  // List of Flutter packages to index
  final flutterPackages = [
    'flutter',
    'flutter_test',
    'flutter_driver',
    'flutter_localizations',
    'flutter_web_plugins',
  ];

  final tempIndex = ScipIndex.empty(projectRoot: flutterPath);
  final registry = IndexRegistry(projectIndex: tempIndex);
  final builder = ExternalIndexBuilder(registry: registry);

  final stopwatch = Stopwatch()..start();
  var successCount = 0;
  var failCount = 0;

  for (final pkgName in flutterPackages) {
    final pkgPath = '$packagesPath/$pkgName';
    if (!await Directory(pkgPath).exists()) {
      stderr.writeln('  Skipping $pkgName (not found)');
      continue;
    }

    // Check if package_config.json exists, run flutter pub get if not
    final pkgConfigFile = File('$pkgPath/.dart_tool/package_config.json');
    if (!await pkgConfigFile.exists()) {
      stderr.writeln('  Running flutter pub get in $pkgName...');
      final result = await Process.run(
        'flutter',
        ['pub', 'get'],
        workingDirectory: pkgPath,
      );
      if (result.exitCode != 0) {
        stderr.writeln('  ✗ Failed to get dependencies for $pkgName');
        failCount++;
        continue;
      }
    }

    stderr.write('  Indexing $pkgName... ');
    final result = await builder.indexPackage(
      pkgName,
      version,
      pkgPath,
    );

    if (result.success) {
      stdout.writeln('✓ (${result.stats?['symbols']} symbols)');
      successCount++;
    } else {
      stdout.writeln('✗ ${result.error}');
      failCount++;
    }
  }

  stopwatch.stop();
  stdout.writeln('');
  stdout.writeln('Results:');
  stdout.writeln('  Indexed: $successCount packages');
  stdout.writeln('  Failed: $failCount packages');
  stdout.writeln('  Time: ${stopwatch.elapsed.inSeconds}s');
  stdout.writeln('');
  stdout.writeln('Indexes saved to: ${registry.globalCachePath}/packages/');
}

/// Index all pub dependencies for cross-package queries.
Future<void> _indexDependencies(List<String> args) async {
  final projectPath = args.isNotEmpty ? args.first : '.';

  final lockfile = File('$projectPath/pubspec.lock');
  if (!await lockfile.exists()) {
    stderr.writeln('Error: No pubspec.lock found in $projectPath');
    stderr.writeln('Run "dart pub get" first.');
    exit(1);
  }

  stderr.writeln('Indexing dependencies from $projectPath...');
  stderr.writeln('This may take several minutes for large projects.');
  stderr.writeln('');

  // Create a temporary index for the registry
  final tempIndex = ScipIndex.empty(projectRoot: projectPath);
  final registry = IndexRegistry(projectIndex: tempIndex);
  final builder = ExternalIndexBuilder(registry: registry);

  final stopwatch = Stopwatch()..start();
  final result = await builder.indexDependencies(projectPath);
  stopwatch.stop();

  if (!result.success) {
    stderr.writeln('✗ Failed: ${result.error}');
    exit(1);
  }

  stdout.writeln('Results:');
  stdout.writeln('  Indexed: ${result.indexed}');
  stdout.writeln('  Skipped (already indexed): ${result.skipped}');
  stdout.writeln('  Failed: ${result.failed}');
  stdout.writeln('  Time: ${stopwatch.elapsed.inSeconds}s');
  stdout.writeln('');

  if (result.failed > 0) {
    stdout.writeln('Failed packages:');
    for (final pkg in result.results.where((r) => !r.success && !r.skipped)) {
      stdout.writeln('  - ${pkg.name}-${pkg.version}: ${pkg.error}');
    }
  }
}

/// List available pre-computed indexes.
Future<void> _listIndexes() async {
  final tempIndex = ScipIndex.empty(projectRoot: '.');
  final registry = IndexRegistry(projectIndex: tempIndex);
  final builder = ExternalIndexBuilder(registry: registry);

  stdout.writeln('Pre-computed indexes in ${registry.globalCachePath}:');
  stdout.writeln('');

  // List SDK indexes
  final sdkVersions = await builder.listSdkIndexes();
  stdout.writeln('SDK Indexes:');
  if (sdkVersions.isEmpty) {
    stdout.writeln('  (none)');
  } else {
    for (final version in sdkVersions) {
      stdout.writeln('  - Dart SDK $version');
    }
  }
  stdout.writeln('');

  // List package indexes
  final packages = await builder.listPackageIndexes();
  stdout.writeln('Package Indexes:');
  if (packages.isEmpty) {
    stdout.writeln('  (none)');
  } else {
    for (final pkg in packages) {
      stdout.writeln('  - ${pkg.name} ${pkg.version}');
    }
  }
  stdout.writeln('');

  stdout.writeln('To index SDK: dart_context index-sdk <path>');
  stdout.writeln('To index deps: dart_context index-deps');
}
