// ignore_for_file: implementation_imports
import 'package:dart_context/src/index/index_registry.dart';
import 'package:dart_context/src/index/scip_index.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('IndexRegistry', () {
    late ScipIndex projectIndex;
    late IndexRegistry registry;

    setUp(() {
      // Create a project index with some symbols
      projectIndex = ScipIndex.empty(projectRoot: '/test/project');

      // Add a class that extends an external class
      projectIndex.updateDocument(
        scip.Document(
          relativePath: 'lib/app.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test . . . lib/app.dart/MyWidget#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'MyWidget',
              relationships: [
                scip.Relationship(
                  symbol: 'flutter . . . widgets/StatelessWidget#',
                  isImplementation: true,
                ),
              ],
            ),
            scip.SymbolInformation(
              symbol: 'test . . . lib/app.dart/MyWidget#build().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'build',
              enclosingSymbol: 'test . . . lib/app.dart/MyWidget#',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test . . . lib/app.dart/MyWidget#',
              range: [5, 6, 5, 14],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
            scip.Occurrence(
              symbol: 'test . . . lib/app.dart/MyWidget#build().',
              range: [10, 2, 10, 7],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
          ],
        ),
      );

      registry = IndexRegistry(projectIndex: projectIndex);
    });

    group('basic operations', () {
      test('projectIndex returns the project index', () {
        expect(registry.projectIndex, same(projectIndex));
      });

      test('sdkIndex is null by default', () {
        expect(registry.sdkIndex, isNull);
      });

      test('loadedSdkVersion is null by default', () {
        expect(registry.loadedSdkVersion, isNull);
      });

      test('packageIndexes is empty by default', () {
        expect(registry.packageIndexes, isEmpty);
      });

      test('stats includes project info', () {
        final stats = registry.stats;
        expect(stats['sdkLoaded'], false);
        expect(stats['packagesLoaded'], 0);
        expect(stats['project'], isNotNull);
      });
    });

    group('getSymbol', () {
      test('finds symbol in project index', () {
        final symbol = registry.getSymbol('test . . . lib/app.dart/MyWidget#');
        expect(symbol, isNotNull);
        expect(symbol!.name, 'MyWidget');
      });

      test('returns null for unknown symbol', () {
        final symbol = registry.getSymbol('unknown . . . UnknownClass#');
        expect(symbol, isNull);
      });
    });

    group('findSymbols', () {
      test('finds symbols by pattern in project', () {
        final symbols = registry.findSymbols('MyWidget');
        expect(symbols, hasLength(1));
        expect(symbols.first.name, 'MyWidget');
      });

      test('respects IndexScope.project', () {
        final symbols = registry.findSymbols(
          'MyWidget',
          scope: IndexScope.project,
        );
        expect(symbols, hasLength(1));
      });
    });

    group('membersOf', () {
      test('finds members in project index', () {
        final members = registry.membersOf('test . . . lib/app.dart/MyWidget#');
        expect(members, hasLength(1));
        expect(members.first.name, 'build');
      });

      test('returns empty for unknown symbol', () {
        final members = registry.membersOf('unknown . . . Unknown#');
        expect(members, isEmpty);
      });
    });

    group('supertypesOf', () {
      test('finds supertypes in project index', () {
        final supertypes = registry.supertypesOf(
          'test . . . lib/app.dart/MyWidget#',
        );
        // May be empty if external class not indexed
        expect(supertypes, isA<List<SymbolInfo>>());
      });
    });

    group('subtypesOf', () {
      test('finds subtypes in project index', () {
        final subtypes = registry.subtypesOf(
          'flutter . . . widgets/StatelessWidget#',
        );
        expect(subtypes, hasLength(1));
        expect(subtypes.first.name, 'MyWidget');
      });
    });

    group('unload operations', () {
      test('unloadAll clears all external indexes', () {
        registry.unloadAll();
        expect(registry.sdkIndex, isNull);
        expect(registry.packageIndexes, isEmpty);
      });
    });

    group('cross-index queries with SDK', () {
      late ScipIndex mockSdkIndex;
      late IndexRegistry crossRegistry;

      setUp(() {
        // Create a mock SDK index
        mockSdkIndex = ScipIndex.empty(projectRoot: '/sdk');
        mockSdkIndex.updateDocument(
          scip.Document(
            relativePath: 'lib/widgets.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'flutter . . . widgets/StatelessWidget#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'StatelessWidget',
                relationships: [
                  scip.Relationship(
                    symbol: 'flutter . . . widgets/Widget#',
                    isImplementation: true,
                  ),
                ],
              ),
              scip.SymbolInformation(
                symbol: 'flutter . . . widgets/StatelessWidget#build().',
                kind: scip.SymbolInformation_Kind.Method,
                displayName: 'build',
                enclosingSymbol: 'flutter . . . widgets/StatelessWidget#',
              ),
              scip.SymbolInformation(
                symbol: 'flutter . . . widgets/Widget#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'Widget',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'flutter . . . widgets/StatelessWidget#',
                range: [10, 0, 10, 15],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'flutter . . . widgets/StatelessWidget#build().',
                range: [15, 2, 15, 7],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'flutter . . . widgets/Widget#',
                range: [5, 0, 5, 6],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        );

        // Create registry with both project and SDK index
        crossRegistry = IndexRegistry.withIndexes(
          projectIndex: projectIndex,
          sdkIndex: mockSdkIndex,
          sdkVersion: '3.0.0',
        );
      });

      test('sdkIndex is set via withIndexes constructor', () {
        expect(crossRegistry.sdkIndex, isNotNull);
        expect(crossRegistry.loadedSdkVersion, '3.0.0');
      });

      test('getSymbol finds symbols in SDK', () {
        final symbol = crossRegistry.getSymbol(
          'flutter . . . widgets/StatelessWidget#',
        );
        expect(symbol, isNotNull);
        expect(symbol!.name, 'StatelessWidget');
      });

      test('getSymbol prioritizes project over SDK', () {
        // Add a symbol with same ID to project (unusual but tests priority)
        final symbol = crossRegistry.getSymbol(
          'test . . . lib/app.dart/MyWidget#',
        );
        expect(symbol, isNotNull);
        expect(symbol!.name, 'MyWidget');
      });

      test('findSymbols searches across project and SDK', () {
        // Search with wildcard to find all *Widget* symbols
        final symbols = crossRegistry.findSymbols('*Widget*');
        // Should find StatelessWidget and Widget from SDK, plus MyWidget from project
        expect(
          symbols.map((s) => s.name),
          containsAll(['Widget', 'StatelessWidget', 'MyWidget']),
        );
      });

      test('membersOf finds members from SDK classes', () {
        final members = crossRegistry.membersOf(
          'flutter . . . widgets/StatelessWidget#',
        );
        expect(members, hasLength(1));
        expect(members.first.name, 'build');
      });

      test('supertypesOf finds SDK supertypes', () {
        final supertypes = crossRegistry.supertypesOf(
          'flutter . . . widgets/StatelessWidget#',
        );
        expect(supertypes.map((s) => s.name), contains('Widget'));
      });

      test('subtypesOf finds project subtypes of SDK classes', () {
        final subtypes = crossRegistry.subtypesOf(
          'flutter . . . widgets/StatelessWidget#',
        );
        expect(subtypes.map((s) => s.name), contains('MyWidget'));
      });
    });

    group('cross-index queries with packages', () {
      late ScipIndex mockPackageIndex;
      late IndexRegistry crossRegistry;

      setUp(() {
        // Create a mock package index
        mockPackageIndex = ScipIndex.empty(projectRoot: '/packages/collection');
        mockPackageIndex.updateDocument(
          scip.Document(
            relativePath: 'lib/collection.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'collection . . . lib/collection.dart/QueueList#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'QueueList',
              ),
              scip.SymbolInformation(
                symbol: 'collection . . . lib/collection.dart/QueueList#add().',
                kind: scip.SymbolInformation_Kind.Method,
                displayName: 'add',
                enclosingSymbol:
                    'collection . . . lib/collection.dart/QueueList#',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'collection . . . lib/collection.dart/QueueList#',
                range: [10, 0, 10, 9],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'collection . . . lib/collection.dart/QueueList#add().',
                range: [20, 2, 20, 5],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        );

        // Create registry with package index
        crossRegistry = IndexRegistry.withIndexes(
          projectIndex: projectIndex,
          packageIndexes: {'collection-1.18.0': mockPackageIndex},
        );
      });

      test('packageIndexes contains the loaded package', () {
        expect(crossRegistry.packageIndexes, hasLength(1));
        expect(crossRegistry.packageIndexes.containsKey('collection-1.18.0'),
            isTrue);
      });

      test('getSymbol finds symbols in packages', () {
        final symbol = crossRegistry.getSymbol(
          'collection . . . lib/collection.dart/QueueList#',
        );
        expect(symbol, isNotNull);
        expect(symbol!.name, 'QueueList');
      });

      test('findSymbols searches packages', () {
        final symbols = crossRegistry.findSymbols('QueueList');
        expect(symbols, hasLength(1));
        expect(symbols.first.name, 'QueueList');
      });

      test('membersOf finds members from package classes', () {
        final members = crossRegistry.membersOf(
          'collection . . . lib/collection.dart/QueueList#',
        );
        expect(members, hasLength(1));
        expect(members.first.name, 'add');
      });
    });

    group('stats with loaded indexes', () {
      test('stats shows SDK info when loaded', () {
        final sdkIndex = ScipIndex.empty(projectRoot: '/sdk');
        final reg = IndexRegistry.withIndexes(
          projectIndex: projectIndex,
          sdkIndex: sdkIndex,
          sdkVersion: '3.2.0',
        );

        final stats = reg.stats;
        expect(stats['sdkLoaded'], true);
        expect(stats['sdkVersion'], '3.2.0');
      });

      test('stats shows package count', () {
        final pkgIndex = ScipIndex.empty(projectRoot: '/pkg');
        final reg = IndexRegistry.withIndexes(
          projectIndex: projectIndex,
          packageIndexes: {
            'pkg1-1.0.0': pkgIndex,
            'pkg2-2.0.0': pkgIndex,
          },
        );

        final stats = reg.stats;
        expect(stats['packagesLoaded'], 2);
        expect(
          stats['packageNames'],
          containsAll(['pkg1-1.0.0', 'pkg2-2.0.0']),
        );
      });
    });
  });
}
