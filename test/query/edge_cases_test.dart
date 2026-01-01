import 'package:dart_context/dart_context.dart';
import 'package:dart_context/dart_context.dart';
import 'package:dart_context/dart_context.dart';
import 'package:dart_context/dart_context.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('Edge Cases', () {
    group('Invalid patterns', () {
      test('invalid regex pattern returns error', () async {
        final index = ScipIndex.empty(projectRoot: '/test');
        final executor = QueryExecutor(index);

        // Unbalanced brackets
        final result = await executor.execute('find /[invalid/');
        // Should handle gracefully (either error or no results)
        expect(result, anyOf(isA<ErrorResult>(), isA<SearchResult>()));
      });

      test('empty target throws FormatException', () {
        expect(
          () => ScipQuery.parse('find'),
          throwsA(isA<FormatException>()),
        );
      });

      test('unknown action throws FormatException', () {
        expect(
          () => ScipQuery.parse('unknown_action foo'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('Pattern edge cases', () {
      test('single character pattern', () {
        final pattern = ParsedPattern.parse('a');
        expect(pattern.type, PatternType.literal);
        expect(pattern.toRegExp().hasMatch('abc'), isTrue);
      });

      test('empty pattern after prefix', () {
        final fuzzy = ParsedPattern.parse('~');
        expect(fuzzy.type, PatternType.fuzzy);
        expect(fuzzy.pattern, '');
      });

      test('regex with only slashes', () {
        final regex = ParsedPattern.parse('//');
        // Should parse as empty regex
        expect(regex.type, PatternType.regex);
        expect(regex.pattern, '');
      });

      test('pattern with unicode characters', () {
        final pattern = ParsedPattern.parse('日本語*');
        expect(pattern.type, PatternType.glob);
        expect(pattern.toRegExp().hasMatch('日本語テスト'), isTrue);
      });

      test('pattern with special regex chars', () {
        final pattern = ParsedPattern.parse(r'foo$bar');
        expect(pattern.type, PatternType.literal);
        // Should escape $ for literal match
        expect(pattern.toRegExp().hasMatch(r'foo$bar'), isTrue);
      });

      test('glob with multiple wildcards', () {
        final pattern = ParsedPattern.parse('*Auth*Service*');
        expect(pattern.toRegExp().hasMatch('MyAuthUserService'), isTrue);
        expect(pattern.toRegExp().hasMatch('AuthService'), isTrue);
      });
    });

    group('Fuzzy matching edge cases', () {
      test('identical strings have distance 0', () {
        expect(ParsedPattern.levenshteinDistance('hello', 'hello'), 0);
      });

      test('completely different strings have high distance', () {
        expect(
          ParsedPattern.levenshteinDistance('abc', 'xyz'),
          greaterThan(2),
        );
      });

      test('fuzzy with very short pattern', () {
        final pattern = ParsedPattern.parse('~ab');
        expect(pattern.matches('abc'), isTrue);
        expect(pattern.matches('ab'), isTrue);
        expect(pattern.matches('xyz'), isFalse);
      });

      test('fuzzy with long pattern uses character ratio', () {
        // Patterns > 10 chars use character presence ratio
        final pattern = ParsedPattern.parse('~authentication');
        expect(pattern.matches('authentication'), isTrue);
        expect(pattern.matches('authenticator'), isTrue);
      });
    });

    group('Query filters edge cases', () {
      test('multiple filters', () {
        final query = ScipQuery.parse('find Auth* kind:class in:lib/');
        expect(query.kindFilter, scip.SymbolInformation_Kind.Class);
        expect(query.pathFilter, 'lib/');
      });

      test('filter with empty value', () {
        final query = ScipQuery.parse('find Auth* kind:');
        expect(query.filters['kind'], '');
      });

      test('multiple dash flags', () {
        final query = ScipQuery.parse('grep TODO -i -C:5');
        expect(query.caseInsensitive, isTrue);
        expect(query.contextLines, 5);
      });

      test('unknown kind filter returns null', () {
        final query = ScipQuery.parse('find * kind:unknown_kind');
        expect(query.kindFilter, isNull);
      });
    });

    group('Qualified names edge cases', () {
      test('deeply nested qualified name', () {
        // Not currently supported but should handle gracefully
        final query = ScipQuery.parse('refs A.B.C');
        // Currently joins all as qualified name
        expect(query.target, 'A.B.C');
      });

      test('qualified name with numbers', () {
        final query = ScipQuery.parse('refs Class1.method2');
        expect(query.isQualified, isTrue);
        expect(query.container, 'Class1');
        expect(query.memberName, 'method2');
      });

      test('regex pattern is not qualified', () {
        final query = ScipQuery.parse('find /Class.method/');
        expect(query.isQualified, isFalse);
      });
    });

    group('Actions without targets', () {
      test('files command needs no target', () {
        final query = ScipQuery.parse('files');
        expect(query.action, QueryAction.files);
        expect(query.target, '');
      });

      test('stats command needs no target', () {
        final query = ScipQuery.parse('stats');
        expect(query.action, QueryAction.stats);
        expect(query.target, '');
      });
    });

    group('Grep edge cases', () {
      test('context lines default', () {
        final query = ScipQuery.parse('grep TODO');
        expect(query.contextLines, 2);
      });

      test('context lines zero', () {
        final query = ScipQuery.parse('grep TODO -C:0');
        expect(query.contextLines, 0);
      });

      test('invalid context lines uses default', () {
        final query = ScipQuery.parse('grep TODO -C:abc');
        expect(query.contextLines, 2); // Default
      });
    });

    group('Result formatting edge cases', () {
      test('empty grep result', () {
        final result = GrepResult(pattern: 'test', matches: []);
        expect(result.isEmpty, isTrue);
        expect(result.toText(), contains('No matches found'));
        expect(result.toJson()['count'], 0);
      });

      test('not found result', () {
        final result = NotFoundResult('Symbol "test" not found');
        expect(result.isEmpty, isTrue);
        expect(result.toText(), contains('not found'));
        expect(result.toJson()['type'], 'not_found');
      });

      test('error result', () {
        final result = ErrorResult('Something went wrong');
        expect(result.isEmpty, isTrue);
        expect(result.toText(), contains('Error'));
        expect(result.toJson()['error'], 'Something went wrong');
      });
    });
  });
}

