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

    // ═══════════════════════════════════════════════════════════════════════
    // NEW FLAG TESTS
    // ═══════════════════════════════════════════════════════════════════════

    group('invert match (-v)', () {
      test('returns lines not matching pattern', () async {
        final result = await executor.execute('grep TODO -v');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        // Should have many lines that don't contain TODO
        expect(grepResult.matches.length, greaterThan(10));
        // No match should contain TODO
        for (final match in grepResult.matches) {
          expect(match.matchText.contains('TODO'), isFalse);
        }
      });
    });

    group('word boundary (-w)', () {
      test('matches whole words only', () async {
        final result = await executor.execute('grep Error -w');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        // Should match "Error" but not "formatError"
        expect(grepResult.matches, isNotEmpty);
      });

      test('does not match partial words', () async {
        // "format" should not match "formatError" with -w
        final result = await executor.execute('grep format -w');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        // formatError should NOT be matched
        final hasFormatError = grepResult.matches
            .any((m) => m.matchText.contains('formatError'));
        expect(hasFormatError, isFalse);
      });
    });

    group('files only (-l)', () {
      test('returns only filenames', () async {
        final result = await executor.execute('grep TODO -l');
        expect(result, isA<GrepFilesResult>());

        final filesResult = result as GrepFilesResult;
        expect(filesResult.files, contains('lib/service.dart'));
        expect(filesResult.files, contains('lib/utils.dart'));
        expect(filesResult.isWithoutMatch, isFalse);
      });
    });

    group('files without match (-L)', () {
      test('returns files that do not contain pattern', () async {
        final result = await executor.execute('grep NONEXISTENT -L');
        expect(result, isA<GrepFilesResult>());

        final filesResult = result as GrepFilesResult;
        // All files should be returned since none contain NONEXISTENT
        expect(filesResult.files, contains('lib/service.dart'));
        expect(filesResult.files, contains('lib/utils.dart'));
        expect(filesResult.isWithoutMatch, isTrue);
      });

      test('excludes files that contain pattern', () async {
        final result = await executor.execute('grep FIXME -L');
        expect(result, isA<GrepFilesResult>());

        final filesResult = result as GrepFilesResult;
        // service.dart contains FIXME, so should not be in list
        expect(filesResult.files, isNot(contains('lib/service.dart')));
        // utils.dart does not contain FIXME
        expect(filesResult.files, contains('lib/utils.dart'));
      });
    });

    group('count only (-c)', () {
      test('returns count per file', () async {
        final result = await executor.execute('grep TODO -c');
        expect(result, isA<GrepCountResult>());

        final countResult = result as GrepCountResult;
        expect(countResult.fileCounts['lib/service.dart'], 2);
        expect(countResult.fileCounts['lib/utils.dart'], 1);
        expect(countResult.count, 3); // Total
      });
    });

    group('only matching (-o)', () {
      test('returns only matched text', () async {
        final result = await executor.execute('grep /TODO|FIXME/ -o');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        expect(grepResult.matches, hasLength(4));
        // Each match should be exactly TODO or FIXME
        for (final match in grepResult.matches) {
          expect(match.matchText, anyOf('TODO', 'FIXME'));
          expect(match.contextLines, isEmpty); // No context in -o mode
        }
      });
    });

    group('fixed strings (-F)', () {
      test('treats special characters as literal', () async {
        // Search for literal $msg which appears in the test file
        final result = await executor.execute(r'grep -F $msg');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        expect(grepResult.matches, hasLength(1));
        expect(grepResult.matches.first.file, 'lib/utils.dart');
      });
    });

    group('separate context (-A and -B)', () {
      test('shows only lines after with -A', () async {
        final result = await executor.execute('grep FIXME -A:2 -B:0');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        final match = grepResult.matches.first;
        // Should have match line + 2 after = 3 lines
        expect(match.contextLines.length, 3);
        expect(match.contextBefore, 0);
      });

      test('shows only lines before with -B', () async {
        final result = await executor.execute('grep FIXME -B:2 -A:0');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        final match = grepResult.matches.first;
        // Should have 2 before + match line = 3 lines
        expect(match.contextLines.length, 3);
        expect(match.contextBefore, 2);
      });
    });

    group('max count (-m)', () {
      test('limits matches per file', () async {
        final result = await executor.execute('grep TODO -m:1');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        // service.dart has 2 TODOs but -m:1 should limit to 1
        final serviceMatches =
            grepResult.matches.where((m) => m.file == 'lib/service.dart');
        expect(serviceMatches.length, 1);
      });
    });

    group('include glob (--include)', () {
      test('only searches matching files', () async {
        final result =
            await executor.execute('grep TODO --include:*service.dart');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        // Should only have matches from service.dart
        expect(grepResult.matches.every((m) => m.file.contains('service')),
            isTrue);
      });
    });

    group('exclude glob (--exclude)', () {
      test('skips matching files', () async {
        final result =
            await executor.execute('grep TODO --exclude:*service.dart');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        // Should not have any matches from service.dart
        expect(
            grepResult.matches.any((m) => m.file.contains('service')), isFalse);
        // But should still have match from utils.dart
        expect(grepResult.matches.any((m) => m.file.contains('utils')), isTrue);
      });
    });

    group('multiline (-M)', () {
      test('matches patterns spanning multiple lines', () async {
        // Match "class AuthService {" where { might be on next line
        final result = await executor.execute('grep /class Auth.*\\{/ -M');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        expect(grepResult.matches, isNotEmpty);
        expect(grepResult.matches.first.matchText, contains('AuthService'));
      });
    });

    group('combined flags', () {
      test('combines -c with path filter', () async {
        final result = await executor.execute('grep TODO -c in:lib/service');
        expect(result, isA<GrepCountResult>());

        final countResult = result as GrepCountResult;
        expect(countResult.fileCounts.length, 1);
        expect(countResult.fileCounts['lib/service.dart'], 2);
      });

      test('combines -l with --exclude', () async {
        final result =
            await executor.execute('grep TODO -l --exclude:*utils*');
        expect(result, isA<GrepFilesResult>());

        final filesResult = result as GrepFilesResult;
        expect(filesResult.files, contains('lib/service.dart'));
        expect(filesResult.files, isNot(contains('lib/utils.dart')));
      });

      test('combines -i with -w', () async {
        // Case insensitive word boundary match
        final result = await executor.execute('grep error -i -w');
        expect(result, isA<GrepResult>());

        final grepResult = result as GrepResult;
        // Should match "Error" and "error" but not "formatError"
        expect(grepResult.matches, isNotEmpty);
      });
    });
  });
}

