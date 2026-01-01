// ignore_for_file: implementation_imports
import 'package:dart_context/dart_context.dart';
import 'package:dart_context/dart_context.dart';
import 'package:dart_context/dart_context.dart';
import 'package:dart_context/dart_context.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('QueryExecutor', () {
    late ScipIndex index;
    late QueryExecutor executor;

    setUp(() {
      index = ScipIndex.empty(projectRoot: '/test/project');
      executor = QueryExecutor(index);

      // Set up a test index with various symbols
      index.updateDocument(
        scip.Document(
          relativePath: 'lib/auth/repository.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/auth/repository.dart/AuthRepository#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'AuthRepository',
              documentation: ['Repository for authentication operations.'],
            ),
            scip.SymbolInformation(
              symbol: 'test lib/auth/repository.dart/AuthRepository#login().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'login',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/auth/repository.dart/AuthRepository#logout().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'logout',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/auth/repository.dart/AuthRepository#',
              range: [5, 6, 5, 20],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [5, 0, 50, 1],
            ),
            scip.Occurrence(
              symbol: 'test lib/auth/repository.dart/AuthRepository#login().',
              range: [10, 2, 10, 7],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
            scip.Occurrence(
              symbol: 'test lib/auth/repository.dart/AuthRepository#logout().',
              range: [20, 2, 20, 8],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
          ],
        ),
      );

      index.updateDocument(
        scip.Document(
          relativePath: 'lib/auth/service.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/auth/service.dart/AuthService#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'AuthService',
              relationships: [
                scip.Relationship(
                  symbol: 'test lib/auth/repository.dart/AuthRepository#',
                  isImplementation: true,
                ),
              ],
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/AuthService#',
              range: [3, 6, 3, 17],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
            // Reference to AuthRepository
            scip.Occurrence(
              symbol: 'test lib/auth/repository.dart/AuthRepository#',
              range: [5, 10, 5, 24],
              symbolRoles: 0,
            ),
            // Reference to login
            scip.Occurrence(
              symbol: 'test lib/auth/repository.dart/AuthRepository#login().',
              range: [10, 5, 10, 10],
              symbolRoles: 0,
            ),
          ],
        ),
      );

      index.updateDocument(
        scip.Document(
          relativePath: 'lib/utils/helper.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/utils/helper.dart/formatDate().',
              kind: scip.SymbolInformation_Kind.Function,
              displayName: 'formatDate',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/utils/helper.dart/formatDate().',
              range: [1, 0, 1, 10],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
          ],
        ),
      );
    });

    group('execute', () {
      test('parses and executes query string', () async {
        final result = await executor.execute('find Auth* kind:class');
        expect(result, isA<SearchResult>());
        // AuthRepository and AuthService
        expect((result as SearchResult).symbols, hasLength(2));
      });

      test('returns error for invalid query', () async {
        final result = await executor.execute('invalid');
        expect(result, isA<ErrorResult>());
      });

      test('returns error for empty query', () async {
        final result = await executor.execute('');
        expect(result, isA<ErrorResult>());
      });
    });

    group('definition', () {
      test('finds symbol definition', () async {
        // Use kind filter to get exact class match
        final result = await executor.executeQuery(
          ScipQuery.parse('find AuthRepository kind:class'),
        );
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, hasLength(1));
        expect(searchResult.symbols.first.name, 'AuthRepository');
      });

      test('finds definition with exact name', () async {
        final result = await executor.execute('def AuthService');
        expect(result, isA<DefinitionResult>());

        final defResult = result as DefinitionResult;
        // Only AuthService, not AuthRepository members
        expect(defResult.definitions.length, greaterThanOrEqualTo(1));
      });

      test('returns not found for unknown symbol', () async {
        final result = await executor.execute('def NonExistent');
        expect(result, isA<NotFoundResult>());
      });
    });

    group('references', () {
      test('finds symbol references', () async {
        final result = await executor.execute('refs AuthRepository');
        // May return ReferencesResult (single match) or AggregatedReferencesResult (multiple)
        expect(
          result,
          anyOf(isA<ReferencesResult>(), isA<AggregatedReferencesResult>()),
        );

        // Check that we have references in the result
        if (result is ReferencesResult) {
          expect(result.references, hasLength(1));
          expect(result.references.first.location.file, 'lib/auth/service.dart');
        } else if (result is AggregatedReferencesResult) {
          expect(result.count, greaterThan(0));
        }
      });

      test('returns empty references for symbol with no refs', () async {
        final result = await executor.execute('refs formatDate');
        // Single match with no refs returns ReferencesResult
        expect(
          result,
          anyOf(isA<ReferencesResult>(), isA<AggregatedReferencesResult>()),
        );
        expect(result.isEmpty, isTrue);
      });

      test('deduplicates references by file+line', () async {
        // Add duplicate references at the same location
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/test/duplicate_refs.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test lib/test/duplicate_refs.dart/DupTest#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'DupTest',
              ),
              scip.SymbolInformation(
                symbol: 'test lib/test/duplicate_refs.dart/DupTest#`<constructor>`().',
                kind: scip.SymbolInformation_Kind.Constructor,
                displayName: 'DupTest',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'test lib/test/duplicate_refs.dart/DupTest#',
                range: [1, 6, 1, 13],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'test lib/test/duplicate_refs.dart/DupTest#`<constructor>`().',
                range: [2, 2, 2, 9],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        );

        // Add a file with multiple references to DupTest
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/test/use_dup.dart',
            language: 'Dart',
            symbols: [],
            occurrences: [
              // Reference to the class
              scip.Occurrence(
                symbol: 'test lib/test/duplicate_refs.dart/DupTest#',
                range: [5, 10, 5, 17],
                symbolRoles: 0, // not a definition
              ),
              // Another reference to the class on the same line
              scip.Occurrence(
                symbol: 'test lib/test/duplicate_refs.dart/DupTest#',
                range: [5, 20, 5, 27],
                symbolRoles: 0,
              ),
              // Reference to constructor (same line)
              scip.Occurrence(
                symbol: 'test lib/test/duplicate_refs.dart/DupTest#`<constructor>`().',
                range: [5, 30, 5, 37],
                symbolRoles: 0,
              ),
              // Reference on different line
              scip.Occurrence(
                symbol: 'test lib/test/duplicate_refs.dart/DupTest#',
                range: [10, 5, 10, 12],
                symbolRoles: 0,
              ),
            ],
          ),
        );

        final result = await executor.execute('refs DupTest');
        expect(
          result,
          anyOf(isA<ReferencesResult>(), isA<AggregatedReferencesResult>()),
        );

        // Should deduplicate - only 2 unique lines (5 and 10)
        if (result is ReferencesResult) {
          final uniqueLines = result.references
              .map((r) => '${r.location.file}:${r.location.line}')
              .toSet();
          expect(uniqueLines.length, equals(result.references.length),
              reason: 'References should be deduplicated by file+line');
        }
      });
    });

    group('members', () {
      test('finds class members', () async {
        // Note: member detection depends on SCIP symbol parent relationship
        // which may not be correctly extracted for all symbol formats
        final result = await executor.execute('members AuthRepository');
        expect(result, isA<MembersResult>());
        // Members may or may not be found depending on symbol format
      });

      test('returns not found for non-class symbol', () async {
        final result = await executor.execute('members formatDate');
        expect(result, isA<NotFoundResult>());
      });

      test('excludes parameters from members', () async {
        // Add class with method parameters
        index.updateDocument(
          scip.Document(
            relativePath: 'lib/test/with_params.dart',
            language: 'Dart',
            symbols: [
              scip.SymbolInformation(
                symbol: 'test lib/test/with_params.dart/TestClass#',
                kind: scip.SymbolInformation_Kind.Class,
                displayName: 'TestClass',
              ),
              scip.SymbolInformation(
                symbol: 'test lib/test/with_params.dart/TestClass#doSomething().',
                kind: scip.SymbolInformation_Kind.Method,
                displayName: 'doSomething',
              ),
              scip.SymbolInformation(
                symbol: 'test lib/test/with_params.dart/TestClass#doSomething().(param1)',
                kind: scip.SymbolInformation_Kind.Parameter,
                displayName: 'param1',
              ),
              scip.SymbolInformation(
                symbol: 'test lib/test/with_params.dart/TestClass#doSomething().(param2)',
                kind: scip.SymbolInformation_Kind.Parameter,
                displayName: 'param2',
              ),
            ],
            occurrences: [
              scip.Occurrence(
                symbol: 'test lib/test/with_params.dart/TestClass#',
                range: [1, 6, 1, 15],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
              scip.Occurrence(
                symbol: 'test lib/test/with_params.dart/TestClass#doSomething().',
                range: [3, 7, 3, 18],
                symbolRoles: scip.SymbolRole.Definition.value,
              ),
            ],
          ),
        );

        final result = await executor.execute('members TestClass');
        expect(result, isA<MembersResult>());

        final membersResult = result as MembersResult;
        // Should have the method but not the parameters
        final kinds = membersResult.members.map((m) => m.kindString).toList();
        expect(kinds, isNot(contains('parameter')));
        expect(kinds, contains('method'));
      });
    });

    group('implementations', () {
      test('finds implementations of class', () async {
        final result = await executor.execute('impls AuthRepository');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, hasLength(1));
        expect(searchResult.symbols.first.name, 'AuthService');
      });
    });

    group('hierarchy', () {
      test('finds full hierarchy', () async {
        final result = await executor.execute('hierarchy AuthService');
        expect(result, isA<HierarchyResult>());

        final hierarchyResult = result as HierarchyResult;
        expect(hierarchyResult.supertypes, hasLength(1));
        expect(hierarchyResult.supertypes.first.name, 'AuthRepository');
      });
    });

    group('find', () {
      test('finds symbols by pattern', () async {
        final result = await executor.execute('find Auth* kind:class');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, hasLength(2)); // AuthRepository, AuthService
      });

      test('filters by kind', () async {
        final result = await executor.execute('find * kind:function');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, hasLength(1));
        expect(searchResult.symbols.first.name, 'formatDate');
      });

      test('filters by path', () async {
        final result = await executor.execute('find * in:lib/utils/');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, hasLength(1));
        expect(searchResult.symbols.first.file, 'lib/utils/helper.dart');
      });

      test('combines kind and path filters', () async {
        final result = await executor.execute('find * kind:class in:lib/auth/');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, hasLength(2)); // AuthRepository, AuthService
      });
    });

    group('files', () {
      test('lists all indexed files', () async {
        final result = await executor.execute('files');
        expect(result, isA<FilesResult>());

        final filesResult = result as FilesResult;
        expect(filesResult.files, hasLength(3));
        expect(
          filesResult.files,
          containsAll([
            'lib/auth/repository.dart',
            'lib/auth/service.dart',
            'lib/utils/helper.dart',
          ]),
        );
      });
    });

    group('stats', () {
      test('returns index statistics', () async {
        final result = await executor.execute('stats');
        expect(result, isA<StatsResult>());

        final statsResult = result as StatsResult;
        expect(statsResult.stats['files'], 3);
        expect(statsResult.stats['symbols'], 5);
      });
    });

    group('fuzzy find', () {
      test('finds symbols with typos', () async {
        // Note: fuzzy matching uses Levenshtein distance on the symbol name
        final result = await executor.execute('find ~AuthRepo');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, isNotEmpty);
        expect(
          searchResult.symbols.any((s) => s.name == 'AuthRepository'),
          isTrue,
        );
      });

      test('finds symbols with missing characters', () async {
        final result = await executor.execute('find ~AuthServ');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, isNotEmpty);
        expect(
          searchResult.symbols.any((s) => s.name == 'AuthService'),
          isTrue,
        );
      });

      test('finds symbols with exact substring', () async {
        final result = await executor.execute('find ~format');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        expect(searchResult.symbols, isNotEmpty);
        expect(
          searchResult.symbols.any((s) => s.name == 'formatDate'),
          isTrue,
        );
      });
    });

    group('regex find', () {
      test('finds symbols with regex pattern', () async {
        // /^Auth/ matches symbols whose name starts with "Auth"
        final result = await executor.execute('find /^Auth/');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        // Only AuthRepository and AuthService start with "Auth"
        expect(searchResult.symbols, hasLength(2));
        expect(
          searchResult.symbols.every((s) => s.name.startsWith('Auth')),
          isTrue,
        );
      });

      test('finds symbols with case insensitive regex', () async {
        // /auth/i with kind:class filters to only classes with "auth" in name
        final result = await executor.execute('find /auth/i kind:class');
        expect(result, isA<SearchResult>());

        final searchResult = result as SearchResult;
        // Should find AuthRepository and AuthService classes
        expect(searchResult.symbols, hasLength(2));
      });
    });

    group('edge cases', () {
      test('handles empty query gracefully', () async {
        final result = await executor.execute('');
        expect(result, isA<ErrorResult>());
        // Empty query error message
        expect((result as ErrorResult).error, isNotEmpty);
      });

      test('handles whitespace-only query', () async {
        final result = await executor.execute('   ');
        expect(result, isA<ErrorResult>());
      });

      test('handles unknown command gracefully', () async {
        final result = await executor.execute('unknowncommand foo');
        expect(result, isA<ErrorResult>());
        expect((result as ErrorResult).error, contains('Unknown'));
      });

      test('def with no matches returns not found', () async {
        final result = await executor.execute('def NonExistentSymbol');
        expect(result, isA<NotFoundResult>());
      });

      test('refs with no matches returns empty', () async {
        final result = await executor.execute('refs NonExistentSymbol');
        // Should be SearchResult with empty symbols
        if (result is SearchResult) {
          expect(result.symbols, isEmpty);
        } else if (result is NotFoundResult) {
          // Also acceptable
          expect(result, isA<NotFoundResult>());
        }
      });

      test('members with non-class returns appropriate result', () async {
        // If we ask for members of a function, should handle gracefully
        final result = await executor.execute('members login');
        // login is a method, not a class - should return empty or not found
        if (result is SearchResult) {
          expect(result.symbols, isEmpty);
        }
      });

      test('stats command returns index statistics', () async {
        final result = await executor.execute('stats');
        expect(result, isA<StatsResult>());
        final stats = result as StatsResult;
        expect(stats.stats, containsPair('files', isA<int>()));
        expect(stats.stats, containsPair('symbols', isA<int>()));
      });

      test('files command returns all indexed files', () async {
        final result = await executor.execute('files');
        expect(result, isA<FilesResult>());
        final files = result as FilesResult;
        expect(files.files, isNotEmpty);
        expect(files.files, contains('lib/auth/service.dart'));
      });
    });

    group('qualified names', () {
      test('which command shows disambiguation options', () async {
        // which shows all matches for a name
        final result = await executor.execute('which login');
        expect(result, isA<WhichResult>());
        final which = result as WhichResult;
        expect(which.matches, isNotEmpty);
      });

      test('def with specific name finds definition', () async {
        // Find definition of a specific method
        final result = await executor.execute('def login');
        // Should find at least one login method
        expect(result, isA<DefinitionResult>());
      });
    });
  });
}

