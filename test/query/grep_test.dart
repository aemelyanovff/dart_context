import 'dart:io';

import 'package:dart_context/src/index/scip_index.dart';
import 'package:dart_context/src/query/query_executor.dart';
import 'package:dart_context/src/query/query_result.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('Grep', () {
    late Directory tempDir;
    late ScipIndex index;
    late QueryExecutor executor;

    setUp(() async {
      // Create temp directory with test files
      tempDir = await Directory.systemTemp.createTemp('dart_context_grep_');

      // Create test file with searchable content
      final libDir = Directory('${tempDir.path}/lib');
      await libDir.create(recursive: true);

      await File('${tempDir.path}/lib/service.dart').writeAsString('''
// TODO: Add caching here
class AuthService {
  // FIXME: Handle errors properly
  Future<void> login() async {
    throw AuthException('Not implemented');
  }

  void logout() {
    // TODO: Clear tokens
    print('Logged out');
  }
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
}
''');

      await File('${tempDir.path}/lib/utils.dart').writeAsString('''
// Helper utilities
String formatError(Exception e) {
  return 'Error: \${e.toString()}';
}

// TODO: Add more formatters
void logError(String msg) {
  print('[ERROR] \$msg');
}
''');

      // Create index with the test files
      index = ScipIndex.empty(projectRoot: tempDir.path);

      index.updateDocument(
        scip.Document(
          relativePath: 'lib/service.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/service.dart/AuthService#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'AuthService',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/service.dart/AuthService#',
              range: [2, 6, 2, 17],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
          ],
        ),
      );

      index.updateDocument(
        scip.Document(
          relativePath: 'lib/utils.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/utils.dart/formatError().',
              kind: scip.SymbolInformation_Kind.Function,
              displayName: 'formatError',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/utils.dart/formatError().',
              range: [2, 7, 2, 18],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
          ],
        ),
      );

      executor = QueryExecutor(index);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('grep finds TODO comments', () async {
      final result = await executor.execute('grep TODO');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      expect(grepResult.matches, hasLength(3)); // 3 TODOs across files
    });

    test('grep finds FIXME comments', () async {
      final result = await executor.execute('grep FIXME');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      expect(grepResult.matches, hasLength(1));
      expect(grepResult.matches.first.file, 'lib/service.dart');
    });

    test('grep with regex pattern', () async {
      final result = await executor.execute('grep /TODO|FIXME/');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      expect(grepResult.matches, hasLength(4)); // 3 TODOs + 1 FIXME
    });

    test('grep with path filter', () async {
      final result = await executor.execute('grep TODO in:lib/utils');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      expect(grepResult.matches, hasLength(1));
      expect(grepResult.matches.first.file, 'lib/utils.dart');
    });

    test('grep case insensitive', () async {
      final result = await executor.execute('grep /error/i');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      // Should find: formatError, Error, ERROR, error
      expect(grepResult.matches.length, greaterThan(2));
    });

    test('grep includes context lines', () async {
      final result = await executor.execute('grep FIXME -C:2');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      expect(grepResult.matches, hasLength(1));

      final match = grepResult.matches.first;
      // Context should include lines around FIXME
      expect(match.contextLines.length, greaterThan(1));
    });

    test('grep returns empty for no matches', () async {
      final result = await executor.execute('grep NONEXISTENT_STRING');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      expect(grepResult.isEmpty, isTrue);
    });

    test('grep with exception pattern', () async {
      final result = await executor.execute('grep /throw.*Exception/');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      expect(grepResult.matches, hasLength(1));
      expect(grepResult.matches.first.matchText, contains('AuthException'));
    });

    test('grep extracts symbols containing matches', () async {
      final result = await executor.execute('grep TODO');
      expect(result, isA<GrepResult>());

      final grepResult = result as GrepResult;
      expect(grepResult.symbols, isNotEmpty);
      expect(
        grepResult.symbols.any((s) => s.name == 'AuthService'),
        isTrue,
      );
    });

    test('grep results can be piped to refs', () async {
      final result = await executor.execute('grep TODO | refs');
      expect(
        result,
        anyOf(
          isA<ReferencesResult>(),
          isA<AggregatedReferencesResult>(),
          isA<PipelineResult>(),
          isA<NotFoundResult>(),
        ),
      );
    });

    test('grep result toText includes file grouping', () async {
      final result = await executor.execute('grep TODO');
      expect(result, isA<GrepResult>());

      final text = result.toText();
      expect(text, contains('lib/service.dart'));
      expect(text, contains('lib/utils.dart'));
      expect(text, contains('matches'));
    });

    test('grep result toJson has correct structure', () async {
      final result = await executor.execute('grep TODO');
      expect(result, isA<GrepResult>());

      final json = result.toJson();
      expect(json['type'], 'grep');
      expect(json['pattern'], 'TODO');
      expect(json['matches'], isA<List>());
      expect(json['count'], greaterThan(0));
    });
  });
}

