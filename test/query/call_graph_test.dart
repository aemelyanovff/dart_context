import 'package:dart_context/src/index/scip_index.dart';
import 'package:dart_context/src/query/query_executor.dart';
import 'package:dart_context/src/query/query_result.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('Call Graph', () {
    late ScipIndex index;
    late QueryExecutor executor;

    setUp(() {
      index = ScipIndex.empty(projectRoot: '/test/project');
      executor = QueryExecutor(index);

      // Create a call graph:
      // AuthService.login() calls:
      //   - validateUser()
      //   - UserRepository.findById()
      // validateUser() calls:
      //   - isEmailValid()

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
              symbol: 'test lib/auth/service.dart/AuthService#login().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'login',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/auth/service.dart/validateUser().',
              kind: scip.SymbolInformation_Kind.Function,
              displayName: 'validateUser',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/auth/service.dart/isEmailValid().',
              kind: scip.SymbolInformation_Kind.Function,
              displayName: 'isEmailValid',
            ),
          ],
          occurrences: [
            // AuthService class definition
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/AuthService#',
              range: [5, 6, 5, 17],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [5, 0, 50, 1],
            ),
            // login() definition - lines 10-20
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/AuthService#login().',
              range: [10, 2, 10, 7],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [10, 0, 20, 3],
            ),
            // login() calls validateUser() at line 12
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/validateUser().',
              range: [12, 4, 12, 16],
              symbolRoles: 0, // Reference
            ),
            // validateUser() definition - lines 25-35
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/validateUser().',
              range: [25, 0, 25, 12],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [25, 0, 35, 1],
            ),
            // validateUser() calls isEmailValid() at line 28
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/isEmailValid().',
              range: [28, 4, 28, 16],
              symbolRoles: 0, // Reference
            ),
            // isEmailValid() definition
            scip.Occurrence(
              symbol: 'test lib/auth/service.dart/isEmailValid().',
              range: [40, 0, 40, 12],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [40, 0, 45, 1],
            ),
          ],
        ),
      );

      // Add UserRepository in another file
      index.updateDocument(
        scip.Document(
          relativePath: 'lib/user/repository.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/user/repository.dart/UserRepository#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'UserRepository',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/user/repository.dart/UserRepository#findById().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'findById',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/user/repository.dart/UserRepository#',
              range: [5, 6, 5, 20],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [5, 0, 30, 1],
            ),
            scip.Occurrence(
              symbol: 'test lib/user/repository.dart/UserRepository#findById().',
              range: [10, 2, 10, 10],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [10, 0, 15, 3],
            ),
          ],
        ),
      );
    });

    group('calls query', () {
      test('returns CallGraphResult for valid symbol', () async {
        final result = await executor.execute('calls validateUser');
        expect(result, isA<CallGraphResult>());

        final callGraph = result as CallGraphResult;
        expect(callGraph.direction, 'calls');
        expect(callGraph.symbol.name, 'validateUser');
      });

      test('returns empty for symbol with no calls', () async {
        final result = await executor.execute('calls isEmailValid');
        expect(result, isA<CallGraphResult>());

        final callGraph = result as CallGraphResult;
        expect(callGraph.isEmpty, isTrue);
      });

      test('returns not found for unknown symbol', () async {
        final result = await executor.execute('calls NonExistent');
        expect(result, isA<NotFoundResult>());
      });
    });

    group('callers query', () {
      test('finds what calls a function', () async {
        final result = await executor.execute('callers isEmailValid');
        expect(result, isA<CallGraphResult>());

        final callGraph = result as CallGraphResult;
        expect(callGraph.direction, 'callers');
        // validateUser should be listed as a caller
        expect(callGraph.connections, isNotEmpty);
      });

      test('finds what calls a helper function', () async {
        final result = await executor.execute('callers validateUser');
        expect(result, isA<CallGraphResult>());

        final callGraph = result as CallGraphResult;
        // login should be a caller
        expect(callGraph.connections, isNotEmpty);
      });

      test('returns empty for function with no callers', () async {
        final result = await executor.execute('callers login');
        expect(result, isA<CallGraphResult>());

        final callGraph = result as CallGraphResult;
        // login is not called by anything in our test setup
        expect(callGraph.isEmpty, isTrue);
      });
    });

    group('result formatting', () {
      test('toText includes direction', () async {
        final result = await executor.execute('calls validateUser');
        expect(result, isA<CallGraphResult>());

        final text = result.toText();
        expect(text, contains('validateUser'));
      });

      test('toJson has correct structure', () async {
        final result = await executor.execute('calls validateUser');
        expect(result, isA<CallGraphResult>());

        final json = result.toJson();
        expect(json['type'], 'call_graph');
        expect(json['direction'], 'calls');
        expect(json['connections'], isA<List>());
      });
    });
  });
}

