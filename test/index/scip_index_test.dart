// ignore_for_file: implementation_imports
import 'package:dart_context/dart_context.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('ScipIndex', () {
    late ScipIndex index;

    setUp(() {
      index = ScipIndex.empty(projectRoot: '/test/project');
    });

    group('fromScipIndex', () {
      test('creates index from SCIP data', () {
        final raw = scip.Index(
          metadata: scip.Metadata(projectRoot: 'file:///test'),
          documents: [
            scip.Document(
              relativePath: 'lib/main.dart',
              language: 'Dart',
              symbols: [
                scip.SymbolInformation(
                  symbol: 'test . . . lib/main.dart/MyClass#',
                  kind: scip.SymbolInformation_Kind.Class,
                  displayName: 'MyClass',
                ),
              ],
              occurrences: [
                scip.Occurrence(
                  symbol: 'test . . . lib/main.dart/MyClass#',
                  range: [10, 0, 10, 7],
                  symbolRoles: scip.SymbolRole.Definition.value,
                ),
              ],
            ),
          ],
        );

        final idx = ScipIndex.fromScipIndex(raw, projectRoot: '/test');

        expect(idx.stats['files'], 1);
        expect(idx.stats['symbols'], 1);
      });
    });

    group('updateDocument', () {
      test('adds new document', () {
        final doc = scip.Document(
          relativePath: 'lib/foo.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test . . . lib/foo.dart/Foo#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'Foo',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test . . . lib/foo.dart/Foo#',
              range: [5, 0, 5, 3],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
          ],
        );

        index.updateDocument(doc);

        expect(index.stats['files'], 1);
        expect(index.stats['symbols'], 1);
      });

      test('replaces existing document', () {
        // Add initial document
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/foo.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test . . . lib/foo.dart/OldClass#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
          ),
        );

        // Replace with new document
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/foo.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test . . . lib/foo.dart/NewClass#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
          ),
        );

        expect(index.stats['files'], 1);
        expect(index.stats['symbols'], 1);

        // Old symbol should be gone
        expect(index.findSymbols('OldClass'), isEmpty);
        // New symbol should exist
        expect(index.findSymbols('NewClass'), isNotEmpty);
      });
    });

    group('removeDocument', () {
      test('removes document and its symbols', () {
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/foo.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test . . . lib/foo.dart/Foo#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
          ),
        );

        expect(index.stats['files'], 1);

        index.removeDocument('lib/foo.dart');

        expect(index.stats['files'], 0);
        expect(index.stats['symbols'], 0);
      });

      test('does nothing for non-existent document', () {
        index.removeDocument('nonexistent.dart');
        expect(index.stats['files'], 0);
      });
    });

    group('findSymbols', () {
      setUp(() {
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/auth.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test . . . lib/auth.dart/AuthRepository#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'AuthRepository',
              ),
              scip.SymbolInformation(
                symbol: 'test . . . lib/auth.dart/AuthService#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'AuthService',
              ),
              scip.SymbolInformation(
                symbol: 'test . . . lib/auth.dart/login#',
                kind: scip.SymbolInformation_Kind.Function,
                displayName: 'login',
              ),
            ],
          ),
        );
      });

      test('finds symbol by exact name', () {
        final results = index.findSymbols('AuthRepository').toList();
        expect(results, hasLength(1));
        expect(results.first.name, 'AuthRepository');
      });

      test('finds symbols by pattern with wildcard', () {
        // Note: Auth* matches any symbol containing "Auth" in name or symbol ID
        final results = index.findSymbols('Auth*').toList();
        expect(results.where((s) => s.name.startsWith('Auth')), hasLength(2));
      });

      test('finds symbols case insensitively', () {
        final results = index.findSymbols('authrepository').toList();
        expect(results, hasLength(1));
      });

      test('returns empty for no matches', () {
        final results = index.findSymbols('NonExistent').toList();
        expect(results, isEmpty);
      });

      test('returns empty for empty pattern', () {
        final results = index.findSymbols('').toList();
        expect(results, isEmpty);
      });
    });

    group('findDefinition', () {
      test('finds definition occurrence', () {
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/foo.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test . . . lib/foo.dart/Foo#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'test . . . lib/foo.dart/Foo#',
                range: [10, 6, 10, 9],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        );

        final def = index.findDefinition('test . . . lib/foo.dart/Foo#');
        expect(def, isNotNull);
        expect(def!.isDefinition, isTrue);
        expect(def.line, 10);
        expect(def.file, 'lib/foo.dart');
      });

      test('returns null for symbol with no definition', () {
        final def = index.findDefinition('nonexistent');
        expect(def, isNull);
      });
    });

    group('findReferences', () {
      test('finds reference occurrences', () {
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/foo.dart',
            language: 'Dart',
            occurrences: [
              scip.Occurrence(
                symbol: 'test . . . lib/foo.dart/Foo#',
                range: [10, 6, 10, 9],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'test . . . lib/foo.dart/Foo#',
                range: [20, 0, 20, 3],
                symbolRoles: 0, // Reference
              ),
              scip.Occurrence(
                symbol: 'test . . . lib/foo.dart/Foo#',
                range: [30, 0, 30, 3],
                symbolRoles: 0, // Reference
              ),
            ],
          ),
        );

        final refs = index.findReferences('test . . . lib/foo.dart/Foo#');
        expect(refs, hasLength(2)); // Excludes definition
        expect(refs.every((r) => !r.isDefinition), isTrue);
      });
    });

    group('findImplementations', () {
      test('finds classes implementing interface', () {
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/impl.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test . . . lib/impl.dart/MyImpl#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'MyImpl',
                relationships: [
                  scip.Relationship(
                    symbol: 'test . . . lib/base.dart/Base#',
                    isImplementation: true,
                  ),
                ],
              ),
            ],
          ),
        );

        final impls = index
            .findImplementations('test . . . lib/base.dart/Base#')
            .toList();
        expect(impls, hasLength(1));
        expect(impls.first.name, 'MyImpl');
      });
    });

    group('symbolsInFile', () {
      test('returns symbols in specific file', () {
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/a.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test . . . lib/a.dart/A#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
          ),
        );
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/b.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test . . . lib/b.dart/B#',
                kind: scip.SymbolInformation_Kind.Class,
              ),
            ],
          ),
        );

        final symbolsA = index.symbolsInFile('lib/a.dart').toList();
        expect(symbolsA, hasLength(1));

        final symbolsB = index.symbolsInFile('lib/b.dart').toList();
        expect(symbolsB, hasLength(1));
      });
    });

    group('files', () {
      test('returns all indexed file paths', () {
        index.updateDocument(
          scip.Document(relativePath: 'lib/a.dart', language: 'Dart'),
        );
        index.updateDocument(
          scip.Document(relativePath: 'lib/b.dart', language: 'Dart'),
        );

        final files = index.files.toList();
        expect(files, containsAll(['lib/a.dart', 'lib/b.dart']));
      });
    });
  });

  group('SymbolInfo', () {
    test('extracts name from displayName', () {
      final sym = SymbolInfo(
        symbol: 'test . . . lib/foo.dart/MyClass#',
        kind: scip.SymbolInformation_Kind.Class,
        documentation: [],
        relationships: [],
        displayName: 'MyClass',
        file: 'lib/foo.dart',
      );

      expect(sym.name, 'MyClass');
    });

    test('extracts name from symbol when no displayName', () {
      final sym = SymbolInfo(
        symbol: 'test . . . lib/foo.dart/MyClass#',
        kind: scip.SymbolInformation_Kind.Class,
        documentation: [],
        relationships: [],
        displayName: null,
        file: 'lib/foo.dart',
      );

      expect(sym.name, 'MyClass');
    });

    test('kindString returns human-readable kind', () {
      expect(
        SymbolInfo(
          symbol: '',
          kind: scip.SymbolInformation_Kind.Class,
          documentation: [],
          relationships: [],
          displayName: null,
          file: null,
        ).kindString,
        'class',
      );

      expect(
        SymbolInfo(
          symbol: '',
          kind: scip.SymbolInformation_Kind.Method,
          documentation: [],
          relationships: [],
          displayName: null,
          file: null,
        ).kindString,
        'method',
      );
    });

    test('isExternal is true when file is null', () {
      final sym = SymbolInfo(
        symbol: '',
        kind: scip.SymbolInformation_Kind.Class,
        documentation: [],
        relationships: [],
        displayName: null,
        file: null,
      );

      expect(sym.isExternal, isTrue);
    });
  });

  group('OccurrenceInfo', () {
    test('parses 4-element range', () {
      final occ = OccurrenceInfo.fromScip(
        scip.Occurrence(
          symbol: 'test',
          range: [10, 5, 12, 3],
          symbolRoles: 0,
        ),
        file: 'lib/foo.dart',
      );

      expect(occ.line, 10);
      expect(occ.column, 5);
      expect(occ.endLine, 12);
      expect(occ.endColumn, 3);
    });

    test('parses 3-element range (same line)', () {
      final occ = OccurrenceInfo.fromScip(
        scip.Occurrence(
          symbol: 'test',
          range: [10, 5, 15],
          symbolRoles: 0,
        ),
        file: 'lib/foo.dart',
      );

      expect(occ.line, 10);
      expect(occ.column, 5);
      expect(occ.endLine, 10);
      expect(occ.endColumn, 15);
    });

    test('location format is correct', () {
      final occ = OccurrenceInfo(
        file: 'lib/foo.dart',
        symbol: 'test',
        line: 10,
        column: 5,
        endLine: 10,
        endColumn: 15,
        isDefinition: false,
      );

      expect(occ.location, 'lib/foo.dart:11:6'); // 1-based for display
    });
  });

  group('ScipIndex Edge Cases', () {
    group('empty index', () {
      test('returns empty results for all queries', () {
        final index = ScipIndex.empty(projectRoot: '/test');

        expect(index.findSymbols('*'), isEmpty);
        expect(index.getSymbol('any'), isNull);
        expect(index.findReferences('any'), isEmpty);
        expect(index.getDocument('any.dart'), isNull);
        expect(index.files, isEmpty);
      });

      test('stats show zero values', () {
        final index = ScipIndex.empty(projectRoot: '/test');

        expect(index.stats['files'], 0);
        expect(index.stats['symbols'], 0);
        expect(index.stats['references'], 0);
      });

      test('accepts custom sourceRoot', () {
        final index = ScipIndex.empty(
          projectRoot: '/cache/pkg',
          sourceRoot: '/actual/source',
        );

        expect(index.projectRoot, '/cache/pkg');
        expect(index.sourceRoot, '/actual/source');
      });
    });

    group('sourceRoot', () {
      test('defaults to projectRoot when not specified', () {
        final index = ScipIndex.empty(projectRoot: '/my/project');
        expect(index.sourceRoot, '/my/project');
      });

      test('uses separate sourceRoot for external packages', () {
        final raw = scip.Index(
          metadata: scip.Metadata(projectRoot: 'file:///cache/pkg'),
          documents: [
            scip.Document(
              relativePath: 'lib/src.dart',
              language: 'Dart',
              symbols: [],
              occurrences: [],
            ),
          ],
        );

        final index = ScipIndex.fromScipIndex(
          raw,
          projectRoot: '/cache/pkg',
          sourceRoot: '/pub-cache/hosted/pub.dev/pkg-1.0.0',
        );

        expect(index.projectRoot, '/cache/pkg');
        expect(index.sourceRoot, '/pub-cache/hosted/pub.dev/pkg-1.0.0');
      });
    });

    group('pattern matching', () {
      late ScipIndex index;

      setUp(() {
        final raw = scip.Index(
          metadata: scip.Metadata(projectRoot: 'file:///test'),
          documents: [
            scip.Document(
              relativePath: 'lib/main.dart',
              language: 'Dart',
              symbols: [
                scip.SymbolInformation(
                  symbol: 'test . . . lib/main.dart/AuthService#',
                  kind: scip.SymbolInformation_Kind.Class,
                  displayName: 'AuthService',
                ),
                scip.SymbolInformation(
                  symbol: 'test . . . lib/main.dart/UserService#',
                  kind: scip.SymbolInformation_Kind.Class,
                  displayName: 'UserService',
                ),
                scip.SymbolInformation(
                  symbol: 'test . . . lib/main.dart/login#',
                  kind: scip.SymbolInformation_Kind.Method,
                  displayName: 'login',
                ),
              ],
              occurrences: [],
            ),
          ],
        );
        index = ScipIndex.fromScipIndex(raw, projectRoot: '/test');
      });

      test('glob pattern matches multiple symbols', () {
        final results = index.findSymbols('*Service');
        expect(results.length, 2);
        expect(results.map((s) => s.name), containsAll(['AuthService', 'UserService']));
      });

      test('literal match finds exact names', () {
        expect(index.findSymbols('login'), hasLength(1));
        expect(index.findSymbols('AuthService'), hasLength(1));
      });

      test('? matches single character', () {
        final results = index.findSymbols('logi?');
        expect(results.length, 1);
        expect(results.first.name, 'login');
      });
    });

    group('getSource', () {
      test('returns null for non-existent file', () async {
        final index = ScipIndex.empty(projectRoot: '/nonexistent');
        final source = await index.getSource('any.symbol');
        expect(source, isNull);
      });
    });

    group('grep', () {
      test('returns empty for non-existent files', () async {
        final index = ScipIndex.empty(projectRoot: '/nonexistent');
        final results = await index.grep(RegExp('pattern'));
        expect(results, isEmpty);
      });
    });

    group('qualified names', () {
      late ScipIndex index;

      setUp(() {
        final raw = scip.Index(
          metadata: scip.Metadata(projectRoot: 'file:///test'),
          documents: [
            scip.Document(
              relativePath: 'lib/main.dart',
              language: 'Dart',
              symbols: [
                scip.SymbolInformation(
                  symbol: 'test . . . lib/main.dart/MyClass#',
                  kind: scip.SymbolInformation_Kind.Class,
                  displayName: 'MyClass',
                ),
                scip.SymbolInformation(
                  symbol: 'test . . . lib/main.dart/MyClass#doWork().',
                  kind: scip.SymbolInformation_Kind.Method,
                  displayName: 'doWork',
                ),
                scip.SymbolInformation(
                  symbol: 'test . . . lib/main.dart/OtherClass#doWork().',
                  kind: scip.SymbolInformation_Kind.Method,
                  displayName: 'doWork',
                ),
              ],
              occurrences: [],
            ),
          ],
        );
        index = ScipIndex.fromScipIndex(raw, projectRoot: '/test');
      });

      test('findQualified resolves Class.member', () {
        final results = index.findQualified('MyClass', 'doWork');
        expect(results, isNotEmpty);
        expect(results.first.name, 'doWork');
        expect(results.first.symbol, contains('MyClass'));
      });

      test('findQualified returns empty for non-matching pair', () {
        final results = index.findQualified('NonExistent', 'doWork');
        expect(results, isEmpty);
      });
    });
  });
}

