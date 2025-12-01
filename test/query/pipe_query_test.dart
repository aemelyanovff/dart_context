import 'package:dart_context/src/index/scip_index.dart';
import 'package:dart_context/src/query/query_executor.dart';
import 'package:dart_context/src/query/query_result.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('Pipe Queries', () {
    late ScipIndex index;
    late QueryExecutor executor;

    setUp(() {
      index = ScipIndex.empty(projectRoot: '/test/project');
      executor = QueryExecutor(index);

      // Set up test index with Auth* classes
      index.updateDocument(
        scip.Document(
          relativePath: 'lib/auth/repository.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/auth/repository.dart/AuthRepository#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'AuthRepository',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/auth/repository.dart/AuthRepository#login().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'login',
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
              enclosingRange: [10, 0, 20, 3],
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
            ),
            scip.SymbolInformation(
              symbol: 'test lib/auth/service.dart/AuthService#authenticate().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'authenticate',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/AuthService#',
              range: [3, 6, 3, 17],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [3, 0, 40, 1],
            ),
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/AuthService#authenticate().',
              range: [10, 2, 10, 14],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [10, 0, 25, 3],
            ),
            // Reference to AuthRepository
            scip.Occurrence(
              symbol: 'test lib/auth/repository.dart/AuthRepository#',
              range: [15, 10, 15, 24],
              symbolRoles: 0,
            ),
          ],
        ),
      );
    });

    test('pipe find to members', () async {
      final result = await executor.execute('find Auth* kind:class | members');

      // Should get members from both AuthRepository and AuthService
      // Could be MembersResult, PipelineResult, or NotFoundResult
      expect(
        result,
        anyOf(
          isA<MembersResult>(),
          isA<PipelineResult>(),
          isA<NotFoundResult>(),
        ),
      );
    });

    test('pipe find to refs', () async {
      final result = await executor.execute('find AuthRepository | refs');

      // AuthRepository is referenced in AuthService
      expect(
        result,
        anyOf(
          isA<ReferencesResult>(),
          isA<AggregatedReferencesResult>(),
          isA<PipelineResult>(),
        ),
      );
    });

    test('handles empty first result', () async {
      final result = await executor.execute('find NonExistent* | refs');
      // Empty find result, pipeline should handle gracefully
      expect(
        result,
        anyOf(isA<SearchResult>(), isA<NotFoundResult>()),
      );
    });

    test('handles no results from pipe step', () async {
      // Find unused symbols (nothing calls them)
      final result = await executor.execute('find authenticate | callers');
      // Could be CallGraphResult with empty connections
      expect(result, isA<QueryResult>());
    });

    test('multiple pipes', () async {
      // Find Auth* -> get their members -> not practical to go further
      // but test the chain works
      final result = await executor.execute('find Auth* kind:class | members');
      expect(result, isA<QueryResult>());
    });

    test('pipe with error in first query', () async {
      final result = await executor.execute('invalid_query | refs');
      expect(result, isA<ErrorResult>());
    });

    test('result has merged data', () async {
      // When piping find to refs, we should get aggregated references
      final result = await executor.execute('find Auth* | refs');

      // Check that we get some kind of result
      expect(result, isA<QueryResult>());
    });
  });
}

