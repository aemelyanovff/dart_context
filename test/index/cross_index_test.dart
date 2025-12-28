// Tests for cross-index source operations:
// - IndexRegistry.findOwningIndex
// - IndexRegistry.findDefinition across indexes
// - IndexRegistry.getSource with sourceRoot
// - IndexRegistry.findAllReferences
// - QueryExecutor using registry for source/sig/refs/calls

// ignore_for_file: implementation_imports
import 'dart:io';

import 'package:dart_context/src/index/package_registry.dart';
import 'package:dart_context/src/index/scip_index.dart';
import 'package:dart_context/src/query/query_executor.dart';
import 'package:dart_context/src/query/query_result.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String projectRoot;
  late String externalSourceRoot;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cross_index_test');
    projectRoot = '${tempDir.path}/project';
    externalSourceRoot = '${tempDir.path}/external_pkg';

    // Create project directory
    await Directory(projectRoot).create(recursive: true);
    await Directory('$projectRoot/lib').create(recursive: true);

    // Create external package source directory
    await Directory(externalSourceRoot).create(recursive: true);
    await Directory('$externalSourceRoot/lib').create(recursive: true);

    // Create project source file
    await File('$projectRoot/lib/main.dart').writeAsString('''
import 'package:external_pkg/utils.dart';

void main() {
  final helper = ExternalHelper();
  helper.doWork();
}

class LocalClass {
  void localMethod() {}
}
''');

    // Create external package source file
    await File('$externalSourceRoot/lib/utils.dart').writeAsString('''
class ExternalHelper {
  void doWork() {
    print('working');
  }
  
  String getName() {
    return 'helper';
  }
}
''');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('ScipIndex sourceRoot', () {
    test('sourceRoot defaults to projectRoot', () {
      final index = ScipIndex.empty(projectRoot: '/test');
      expect(index.sourceRoot, '/test');
      expect(index.projectRoot, '/test');
    });

    test('sourceRoot can be different from projectRoot', () async {
      // Create an index with a different source root
      final index = ScipIndex.fromScipIndex(
        scip.Index(documents: []),
        projectRoot: '/cache/index',
        sourceRoot: '/actual/source',
      );
      expect(index.projectRoot, '/cache/index');
      expect(index.sourceRoot, '/actual/source');
    });
  });

  group('IndexRegistry findOwningIndex', () {
    late ScipIndex projectIndex;
    late ScipIndex packageIndex;
    late IndexRegistry registry;

    setUp(() {
      projectIndex = ScipIndex.empty(projectRoot: projectRoot);
      projectIndex.updateDocument(scip.Document(
        relativePath: 'lib/main.dart',
        symbols: [
          scip.SymbolInformation(
            symbol: 'project lib/main.dart/LocalClass#',
            kind: scip.SymbolInformation_Kind.Class,
            displayName: 'LocalClass',
          ),
        ],
        occurrences: [
          scip.Occurrence(
            symbol: 'project lib/main.dart/LocalClass#',
            range: [8, 6, 8, 16],
            symbolRoles: scip.SymbolRole.Definition.value,
          ),
        ],
      ));

      packageIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/utils.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'ExternalHelper',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                range: [0, 6, 0, 20],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        ]),
        projectRoot: '${tempDir.path}/cache/external_pkg',
        sourceRoot: externalSourceRoot,
      );

      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        packageIndexes: {'external_pkg-1.0.0': packageIndex},
      );
    });

    test('finds project symbol in project index', () {
      final owningIndex = registry.findOwningIndex(
        'project lib/main.dart/LocalClass#',
      );
      expect(owningIndex, same(projectIndex));
    });

    test('finds external symbol in package index', () {
      final owningIndex = registry.findOwningIndex(
        'external_pkg lib/utils.dart/ExternalHelper#',
      );
      expect(owningIndex, same(packageIndex));
    });

    test('returns null for unknown symbol', () {
      final owningIndex = registry.findOwningIndex(
        'unknown lib/foo.dart/Unknown#',
      );
      expect(owningIndex, isNull);
    });
  });

  group('IndexRegistry findDefinition', () {
    late ScipIndex projectIndex;
    late ScipIndex packageIndex;
    late IndexRegistry registry;

    setUp(() {
      projectIndex = ScipIndex.empty(projectRoot: projectRoot);
      projectIndex.updateDocument(scip.Document(
        relativePath: 'lib/main.dart',
        symbols: [
          scip.SymbolInformation(
            symbol: 'project lib/main.dart/LocalClass#',
            kind: scip.SymbolInformation_Kind.Class,
          ),
        ],
        occurrences: [
          scip.Occurrence(
            symbol: 'project lib/main.dart/LocalClass#',
            range: [8, 6, 8, 16],
            symbolRoles: scip.SymbolRole.Definition.value,
          ),
        ],
      ));

      packageIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/utils.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                range: [0, 6, 0, 20],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        ]),
        projectRoot: '${tempDir.path}/cache/external_pkg',
        sourceRoot: externalSourceRoot,
      );

      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        packageIndexes: {'external_pkg-1.0.0': packageIndex},
      );
    });

    test('finds definition in project', () {
      final def = registry.findDefinition('project lib/main.dart/LocalClass#');
      expect(def, isNotNull);
      expect(def!.file, 'lib/main.dart');
      expect(def.line, 8);
    });

    test('finds definition in external package', () {
      final def = registry.findDefinition(
        'external_pkg lib/utils.dart/ExternalHelper#',
      );
      expect(def, isNotNull);
      expect(def!.file, 'lib/utils.dart');
      expect(def.line, 0);
    });

    test('returns null for unknown symbol', () {
      final def = registry.findDefinition('unknown lib/foo.dart/Unknown#');
      expect(def, isNull);
    });
  });

  group('IndexRegistry getSource with sourceRoot', () {
    late ScipIndex packageIndex;
    late IndexRegistry registry;

    setUp(() {
      final projectIndex = ScipIndex.empty(projectRoot: projectRoot);

      packageIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/utils.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                range: [0, 0, 9, 1],
                symbolRoles: scip.SymbolRole.Definition.value,
                enclosingRange: [0, 0, 9, 1],
              ),
            ],
          ),
        ]),
        projectRoot: '${tempDir.path}/cache/external_pkg',
        sourceRoot: externalSourceRoot,
      );

      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        packageIndexes: {'external_pkg-1.0.0': packageIndex},
      );
    });

    test('getSource reads from sourceRoot not projectRoot', () async {
      final source = await registry.getSource(
        'external_pkg lib/utils.dart/ExternalHelper#',
      );

      expect(source, isNotNull);
      expect(source, contains('class ExternalHelper'));
      expect(source, contains('doWork'));
    });

    test('resolveFilePath returns correct absolute path', () {
      final path = registry.resolveFilePath(
        'external_pkg lib/utils.dart/ExternalHelper#',
      );

      expect(path, isNotNull);
      expect(path, '$externalSourceRoot/lib/utils.dart');
    });
  });

  group('IndexRegistry findAllReferences', () {
    late ScipIndex projectIndex;
    late ScipIndex packageIndex;
    late IndexRegistry registry;

    setUp(() {
      projectIndex = ScipIndex.empty(projectRoot: projectRoot);
      projectIndex.updateDocument(scip.Document(
        relativePath: 'lib/main.dart',
        symbols: [
          scip.SymbolInformation(
            symbol: 'project lib/main.dart/main().',
            kind: scip.SymbolInformation_Kind.Function,
          ),
        ],
        occurrences: [
          // Reference to ExternalHelper in project
          scip.Occurrence(
            symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
            range: [3, 16, 3, 30],
          ),
        ],
      ));

      packageIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/utils.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
            occurrences: [
              // Definition of ExternalHelper
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                range: [0, 6, 0, 20],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        ]),
        projectRoot: '${tempDir.path}/cache/external_pkg',
        sourceRoot: externalSourceRoot,
      );

      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        packageIndexes: {'external_pkg-1.0.0': packageIndex},
      );
    });

    test('finds references across all indexes', () {
      final refs = registry.findAllReferences(
        'external_pkg lib/utils.dart/ExternalHelper#',
      );

      // Should find ref in project (package definition has no ReadAccess role)
      expect(refs.length, greaterThanOrEqualTo(1));
      final files = refs.map((r) => r.file).toSet();
      expect(files, contains('lib/main.dart')); // Project reference
    });
  });

  group('IndexRegistry getCalls and getCallers', () {
    late ScipIndex projectIndex;
    late IndexRegistry registry;

    setUp(() {
      projectIndex = ScipIndex.empty(projectRoot: projectRoot);
      // Note: Call graph is built during indexing, so this test just
      // verifies the registry method calls the underlying index
      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
      );
    });

    test('getCalls returns empty for unknown symbol', () {
      final calls = registry.getCalls('unknown#method().');
      expect(calls, isEmpty);
    });

    test('getCallers returns empty for unknown symbol', () {
      final callers = registry.getCallers('unknown#method().');
      expect(callers, isEmpty);
    });
  });

  group('QueryExecutor with registry', () {
    late ScipIndex projectIndex;
    late ScipIndex packageIndex;
    late IndexRegistry registry;
    late QueryExecutor executor;

    setUp(() {
      projectIndex = ScipIndex.empty(projectRoot: projectRoot);
      projectIndex.updateDocument(scip.Document(
        relativePath: 'lib/main.dart',
        symbols: [
          scip.SymbolInformation(
            symbol: 'project lib/main.dart/LocalClass#',
            kind: scip.SymbolInformation_Kind.Class,
            displayName: 'LocalClass',
          ),
        ],
        occurrences: [
          scip.Occurrence(
            symbol: 'project lib/main.dart/LocalClass#',
            range: [8, 0, 10, 1],
            symbolRoles: scip.SymbolRole.Definition.value,
            enclosingRange: [8, 0, 10, 1],
          ),
        ],
      ));

      packageIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/utils.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'ExternalHelper',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                range: [0, 0, 9, 1],
                symbolRoles: scip.SymbolRole.Definition.value,
                enclosingRange: [0, 0, 9, 1],
              ),
            ],
          ),
        ]),
        projectRoot: '${tempDir.path}/cache/external_pkg',
        sourceRoot: externalSourceRoot,
      );

      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        packageIndexes: {'external_pkg-1.0.0': packageIndex},
      );

      executor = QueryExecutor(
        projectIndex,
        registry: registry,
      );
    });

    test('find locates symbols in both project and external packages', () async {
      final result = await executor.execute('find External*');

      expect(result, isA<SearchResult>());
      final searchResult = result as SearchResult;
      expect(searchResult.symbols.length, 1);
      expect(searchResult.symbols.first.name, 'ExternalHelper');
    });

    test('source returns external source using sourceRoot', () async {
      final result = await executor.execute('source ExternalHelper');

      expect(result, isA<SourceResult>());
      final sourceResult = result as SourceResult;
      expect(sourceResult.source, contains('class ExternalHelper'));
      expect(sourceResult.source, contains('doWork'));
    });
  });

  group('Qualified lookup across indexes', () {
    late ScipIndex projectIndex;
    late ScipIndex packageIndex;
    late IndexRegistry registry;

    setUp(() {
      projectIndex = ScipIndex.empty(projectRoot: projectRoot);
      packageIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/utils.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'ExternalHelper',
              ),
              scip.SymbolInformation(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#doWork().',
                kind: scip.SymbolInformation_Kind.Method,
                displayName: 'doWork',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                range: [0, 0, 3, 1],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#doWork().',
                range: [2, 2, 2, 10],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        ]),
        projectRoot: '${tempDir.path}/cache/external_pkg',
        sourceRoot: externalSourceRoot,
      );

      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        packageIndexes: {'external_pkg-1.0.0': packageIndex},
      );
    });

    test('findQualified returns external method', () {
      final syms = registry.findQualified('ExternalHelper', 'doWork').toList();
      expect(syms.length, 1);
      expect(syms.first.symbol,
          'external_pkg lib/utils.dart/ExternalHelper#doWork().');
    });
  });

  group('Symbol disambiguation prefers classes over params', () {
    late Directory srcDir;
    late ScipIndex projectIndex;
    late QueryExecutor executor;

    setUp(() async {
      srcDir = await Directory.systemTemp.createTemp('disambig');
      final root = srcDir.path;
      final filePath = '$root/lib/main.dart';
      await File(filePath).create(recursive: true);
      await File(filePath).writeAsString('''
class Container {
  void build() {}
}

void fn({bool container = false}) {}
''');

      projectIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/main.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'proj lib/main.dart/Container#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'Container',
              ),
              scip.SymbolInformation(
                symbol: 'proj lib/main.dart/fn().(container)',
                kind: scip.SymbolInformation_Kind.Parameter,
                displayName: 'container',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'proj lib/main.dart/Container#',
                range: [0, 0, 2, 1],
                symbolRoles: scip.SymbolRole.Definition.value,
                enclosingRange: [0, 0, 2, 1],
              ),
              scip.Occurrence(
                symbol: 'proj lib/main.dart/fn().(container)',
                range: [5, 9, 5, 18],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        ]),
        projectRoot: root,
        sourceRoot: root,
      );

      executor = QueryExecutor(projectIndex);
    });

    tearDown(() async {
      await srcDir.delete(recursive: true);
    });

    test('source Container returns class, not param', () async {
      final result = await executor.execute('source Container');
      expect(result, isA<SourceResult>());
      final src = (result as SourceResult).source;
      expect(src, contains('class Container'));
      expect(src, isNot(contains('bool container')));
    });
  });

  group('Grep with dependencies flag', () {
    late Directory rootDir;
    late ScipIndex projectIndex;
    late ScipIndex packageIndex;
    late IndexRegistry registry;

    setUp(() async {
      rootDir = await Directory.systemTemp.createTemp('grep_deps');
      final projRoot = '${rootDir.path}/project';
      final extRoot = '${rootDir.path}/external';
      await File('$projRoot/lib/main.dart').create(recursive: true);
      await File('$projRoot/lib/main.dart')
          .writeAsString('class Local {}\nStatelessWidget;\n');
      await File('$extRoot/lib/utils.dart').create(recursive: true);
      await File('$extRoot/lib/utils.dart')
          .writeAsString('class External {}\nStatelessWidget;\n');

      projectIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/main.dart',
            symbols: [],
            occurrences: [],
          ),
        ]),
        projectRoot: projRoot,
        sourceRoot: projRoot,
      );

      packageIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/utils.dart',
            symbols: [],
            occurrences: [],
          ),
        ]),
        projectRoot: '${rootDir.path}/cache/external',
        sourceRoot: extRoot,
      );

      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        packageIndexes: {'external-1.0.0': packageIndex},
      );
    });

    tearDown(() async {
      await rootDir.delete(recursive: true);
    });

    test('grep without -D searches project only', () async {
      final matches = await registry.grep(
        RegExp('StatelessWidget'),
        includeExternal: false,
      );
      final files = matches.map((m) => m.file).toSet();
      expect(files, contains('lib/main.dart'));
      expect(files, isNot(contains('lib/utils.dart')));
    });

    test('grep with -D includes external packages', () async {
      final matches = await registry.grep(
        RegExp('StatelessWidget'),
        includeExternal: true,
      );
      final files = matches.map((m) => m.file).toSet();
      expect(files, contains('lib/main.dart'));
      expect(files, contains('lib/utils.dart'));
    });
  });

  group('IndexRegistry allIndexes', () {
    test('returns project, SDK, and package indexes', () {
      final projectIndex = ScipIndex.empty(projectRoot: '/project');
      final sdkIndex = ScipIndex.empty(projectRoot: '/sdk');
      final pkg1Index = ScipIndex.empty(projectRoot: '/pkg1');
      final pkg2Index = ScipIndex.empty(projectRoot: '/pkg2');

      final registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        sdkIndex: sdkIndex,
        packageIndexes: {
          'pkg1-1.0.0': pkg1Index,
          'pkg2-2.0.0': pkg2Index,
        },
      );

      final allIndexes = registry.allIndexes;
      expect(allIndexes.length, 4);
      expect(allIndexes, contains(projectIndex));
      expect(allIndexes, contains(sdkIndex));
      expect(allIndexes, contains(pkg1Index));
      expect(allIndexes, contains(pkg2Index));
    });

    test('returns only project when no external indexes', () {
      final projectIndex = ScipIndex.empty(projectRoot: '/project');
      final registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
      );

      final allIndexes = registry.allIndexes;
      expect(allIndexes.length, 1);
      expect(allIndexes.first, same(projectIndex));
    });
  });

  group('Members filtering with QueryExecutor', () {
    late Directory srcDir;
    late ScipIndex projectIndex;
    late QueryExecutor executor;

    setUp(() async {
      srcDir = await Directory.systemTemp.createTemp('members_filter');
      final root = srcDir.path;
      await File('$root/lib/main.dart').create(recursive: true);
      await File('$root/lib/main.dart').writeAsString('''
class Foo {
  Foo(this.value);
  final int value;
  void bar(int x) {}
}
''');

      projectIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/main.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'proj lib/main.dart/Foo#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'Foo',
              ),
              scip.SymbolInformation(
                symbol: 'proj lib/main.dart/Foo#`<constructor>`().',
                kind: scip.SymbolInformation_Kind.Constructor,
              ),
              scip.SymbolInformation(
                symbol: 'proj lib/main.dart/Foo#`<constructor>`().(value)',
                kind: scip.SymbolInformation_Kind.Parameter,
                displayName: 'value',
              ),
              scip.SymbolInformation(
                symbol: 'proj lib/main.dart/Foo#bar().',
                kind: scip.SymbolInformation_Kind.Method,
                displayName: 'bar',
              ),
              scip.SymbolInformation(
                symbol: 'proj lib/main.dart/Foo#bar().(x)',
                kind: scip.SymbolInformation_Kind.Parameter,
                displayName: 'x',
              ),
              scip.SymbolInformation(
                symbol: 'proj lib/main.dart/Foo#`<get>value`.',
                kind: scip.SymbolInformation_Kind.Property,
                displayName: 'value',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'proj lib/main.dart/Foo#',
                range: [0, 0, 5, 1],
                symbolRoles: scip.SymbolRole.Definition.value,
                enclosingRange: [0, 0, 5, 1],
              ),
              scip.Occurrence(
                symbol: 'proj lib/main.dart/Foo#`<constructor>`().',
                range: [1, 2, 1, 13],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'proj lib/main.dart/Foo#`<constructor>`().(value)',
                range: [1, 13, 1, 18],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'proj lib/main.dart/Foo#bar().',
                range: [3, 2, 3, 7],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'proj lib/main.dart/Foo#bar().(x)',
                range: [3, 8, 3, 9],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'proj lib/main.dart/Foo#`<get>value`.',
                range: [2, 8, 2, 13],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        ]),
        projectRoot: root,
        sourceRoot: root,
      );

      executor = QueryExecutor(projectIndex);
    });

    tearDown(() async {
      await srcDir.delete(recursive: true);
    });

    test('members excludes parameters in output', () async {
      final result = await executor.execute('members Foo');
      expect(result, isA<MembersResult>());
      final members = (result as MembersResult).members;
      final kinds = members.map((m) => m.kindString).toList();
      expect(kinds, isNot(contains('parameter')));
      expect(kinds, containsAll(['constructor', 'method', 'property']));
    });
  });

  group('Implementations and hierarchy', () {
    late ScipIndex index;

    setUp(() {
      index = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/a.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'pkg lib/a.dart/Base#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'Base',
              ),
              scip.SymbolInformation(
                symbol: 'pkg lib/a.dart/Impl#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'Impl',
                relationships: [
                  scip.Relationship(
                    symbol: 'pkg lib/a.dart/Base#',
                    isImplementation: true,
                  ),
                ],
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'pkg lib/a.dart/Base#',
                range: [0, 0, 1, 1],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'pkg lib/a.dart/Impl#',
                range: [3, 0, 4, 1],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        ]),
        projectRoot: '/tmp',
        sourceRoot: '/tmp',
      );
    });

    test('findImplementations finds subtype', () {
      final impls = index.findImplementations('pkg lib/a.dart/Base#').toList();
      expect(impls.map((s) => s.displayName), contains('Impl'));
    });

    test('supertypesOf returns base from relationships', () {
      final supers = index.supertypesOf('pkg lib/a.dart/Impl#').toList();
      expect(supers.map((s) => s.displayName), contains('Base'));
    });
  });

  group('Source extraction bounds', () {
    late Directory dir;
    late ScipIndex index;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('source_bounds');
      final root = dir.path;
      await File('$root/lib/main.dart').create(recursive: true);
      await File('$root/lib/main.dart').writeAsString('''
class C {
  void f() {
    print('x');
  }
}
''');

      index = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/main.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'pkg lib/main.dart/C#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'C',
              ),
              scip.SymbolInformation(
                symbol: 'pkg lib/main.dart/C#f().',
                kind: scip.SymbolInformation_Kind.Method,
                displayName: 'f',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'pkg lib/main.dart/C#',
                range: [0, 0, 5, 1],
                symbolRoles: scip.SymbolRole.Definition.value,
                enclosingRange: [0, 0, 5, 1],
              ),
              scip.Occurrence(
                symbol: 'pkg lib/main.dart/C#f().',
                range: [1, 2, 3, 3],
                symbolRoles: scip.SymbolRole.Definition.value,
                enclosingRange: [1, 2, 4, 1],
              ),
            ],
          ),
        ]),
        projectRoot: root,
        sourceRoot: root,
      );
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('getSource respects enclosingEndLine', () async {
      final src = await index.getSource('pkg lib/main.dart/C#f().');
      expect(src, contains("void f() {"));
      expect(src, contains("print('x');"));
      expect(src, isNot(contains('class C')));
    });
  });

  group('Grep include/exclude globs', () {
    late Directory dir;
    late ScipIndex index;
    late IndexRegistry registry;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('grep_globs');
      final root = dir.path;
      await File('$root/lib/a.dart').create(recursive: true);
      await File('$root/lib/b.txt').create(recursive: true);
      await File('$root/lib/a.dart').writeAsString('hello dart');
      await File('$root/lib/b.txt').writeAsString('hello text');

      index = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/a.dart',
            symbols: [],
            occurrences: [],
          ),
          scip.Document(
            relativePath: 'lib/b.txt',
            symbols: [],
            occurrences: [],
          ),
        ]),
        projectRoot: root,
        sourceRoot: root,
      );

      registry = IndexRegistry.withIndexes(projectIndex: index);
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('--include matches only dart file', () async {
      final matches = await registry.grep(
        RegExp('hello'),
        includeGlob: '*.dart',
      );
      final files = matches.map((m) => m.file).toSet();
      expect(files, contains('lib/a.dart'));
      expect(files, isNot(contains('lib/b.txt')));
    });

    test('--exclude skips txt file', () async {
      final matches = await registry.grep(
        RegExp('hello'),
        excludeGlob: '*.txt',
      );
      final files = matches.map((m) => m.file).toSet();
      expect(files, contains('lib/a.dart'));
      expect(files, isNot(contains('lib/b.txt')));
    });
  });

  group('Cross-index references', () {
    late ScipIndex projectIndex;
    late ScipIndex packageIndex;
    late IndexRegistry registry;

    setUp(() {
      projectIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/main.dart',
            symbols: [],
            occurrences: [
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                range: [0, 0, 0, 5],
              ),
            ],
          ),
        ]),
        projectRoot: '/proj',
        sourceRoot: '/proj',
      );

      packageIndex = ScipIndex.fromScipIndex(
        scip.Index(documents: [
          scip.Document(
            relativePath: 'lib/utils.dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'external_pkg lib/utils.dart/ExternalHelper#',
                range: [0, 0, 0, 10],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        ]),
        projectRoot: '/cache/ext',
        sourceRoot: '/ext',
      );

      registry = IndexRegistry.withIndexes(
        projectIndex: projectIndex,
        packageIndexes: {'external_pkg-1.0.0': packageIndex},
      );
    });

    test('findAllReferences returns refs across indexes (project ref)', () {
      final refs = registry.findAllReferences(
        'external_pkg lib/utils.dart/ExternalHelper#',
      );
      final files = refs.map((r) => r.file).toSet();
      expect(files, contains('lib/main.dart')); // project ref
    });
  });
}

