import 'package:dart_context/dart_context.dart';
import 'package:test/test.dart';

void main() {
  group('ParsedPattern', () {
    group('pattern type detection', () {
      test('detects glob patterns', () {
        expect(ParsedPattern.parse('Auth*').type, PatternType.glob);
        expect(ParsedPattern.parse('*Service').type, PatternType.glob);
        expect(ParsedPattern.parse('get?Data').type, PatternType.glob);
        expect(ParsedPattern.parse('*').type, PatternType.glob);
      });

      test('detects regex patterns', () {
        expect(ParsedPattern.parse('/foo/').type, PatternType.regex);
        expect(ParsedPattern.parse('/TODO|FIXME/').type, PatternType.regex);
        expect(ParsedPattern.parse('/error/i').type, PatternType.regex);
        expect(ParsedPattern.parse('/^class/').type, PatternType.regex);
      });

      test('detects fuzzy patterns', () {
        expect(ParsedPattern.parse('~authenticate').type, PatternType.fuzzy);
        expect(ParsedPattern.parse('~respnse').type, PatternType.fuzzy);
      });

      test('defaults to literal for simple strings', () {
        expect(ParsedPattern.parse('AuthService').type, PatternType.literal);
        expect(ParsedPattern.parse('login').type, PatternType.literal);
      });
    });

    group('case sensitivity', () {
      test('regex with i flag is case insensitive', () {
        final pattern = ParsedPattern.parse('/error/i');
        expect(pattern.caseSensitive, isFalse);
      });

      test('regex without i flag is case sensitive', () {
        final pattern = ParsedPattern.parse('/Error/');
        expect(pattern.caseSensitive, isTrue);
      });

      test('fuzzy is always case insensitive', () {
        final pattern = ParsedPattern.parse('~Error');
        expect(pattern.caseSensitive, isFalse);
      });

      test('respects defaultCaseSensitive for glob and literal', () {
        final caseSensitive = ParsedPattern.parse('Auth*');
        expect(caseSensitive.caseSensitive, isTrue);

        final caseInsensitive = ParsedPattern.parse(
          'Auth*',
          defaultCaseSensitive: false,
        );
        expect(caseInsensitive.caseSensitive, isFalse);
      });
    });

    group('glob matching', () {
      test('matches wildcard at end', () {
        final pattern = ParsedPattern.parse('Auth*');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('AuthService'), isTrue);
        expect(regex.hasMatch('AuthRepository'), isTrue);
        expect(regex.hasMatch('Authentication'), isTrue);
        expect(regex.hasMatch('Service'), isFalse);
      });

      test('matches wildcard at start', () {
        final pattern = ParsedPattern.parse('*Service');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('AuthService'), isTrue);
        expect(regex.hasMatch('UserService'), isTrue);
        expect(regex.hasMatch('AuthRepository'), isFalse);
      });

      test('matches wildcard in middle', () {
        final pattern = ParsedPattern.parse('get*Data');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('getUserData'), isTrue);
        expect(regex.hasMatch('getData'), isTrue);
        expect(regex.hasMatch('getUser'), isFalse);
      });

      test('matches single character wildcard', () {
        final pattern = ParsedPattern.parse('get?');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('getX'), isTrue);
        expect(regex.hasMatch('get1'), isTrue);
        expect(regex.hasMatch('get'), isFalse);
        // Note: hasMatch finds partial matches, so 'getAB' matches 'get.' (getA)
        // For exact matching, use matchesFull or anchor the pattern
        expect(regex.hasMatch('getAB'), isTrue); // Partial match on 'getA'
      });

      test('matches single character wildcard with regex for exact match', () {
        // To match exactly 4 chars, use regex with anchors
        final pattern = ParsedPattern.parse('/^get.\$/');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('getX'), isTrue);
        expect(regex.hasMatch('getAB'), isFalse);
      });

      test('escapes special regex characters', () {
        final pattern = ParsedPattern.parse('file.dart*');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('file.dart'), isTrue);
        expect(regex.hasMatch('file_dart'), isFalse);
      });
    });

    group('regex matching', () {
      test('matches regex pattern', () {
        final pattern = ParsedPattern.parse('/TODO|FIXME/');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('// TODO: fix this'), isTrue);
        expect(regex.hasMatch('// FIXME: broken'), isTrue);
        expect(regex.hasMatch('// regular comment'), isFalse);
      });

      test('case insensitive regex', () {
        final pattern = ParsedPattern.parse('/error/i');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('Error'), isTrue);
        expect(regex.hasMatch('ERROR'), isTrue);
        expect(regex.hasMatch('error'), isTrue);
      });

      test('case sensitive regex', () {
        final pattern = ParsedPattern.parse('/Error/');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('Error'), isTrue);
        expect(regex.hasMatch('ERROR'), isFalse);
        expect(regex.hasMatch('error'), isFalse);
      });

      test('complex regex patterns', () {
        final pattern = ParsedPattern.parse(r'/throw\s+\w+Exception/');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('throw AuthException'), isTrue);
        expect(regex.hasMatch('throw  CustomException'), isTrue);
        expect(regex.hasMatch('return error'), isFalse);
      });
    });

    group('literal matching', () {
      test('matches exact string', () {
        final pattern = ParsedPattern.parse('AuthService');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('AuthService'), isTrue);
        expect(regex.hasMatch('class AuthService {'), isTrue);
        expect(regex.hasMatch('Auth'), isFalse);
      });

      test('escapes special characters', () {
        final pattern = ParsedPattern.parse('Class.method');
        final regex = pattern.toRegExp();

        expect(regex.hasMatch('Class.method'), isTrue);
        expect(regex.hasMatch('ClassXmethod'), isFalse);
      });
    });

    group('fuzzy matching', () {
      test('matches exact substring', () {
        final pattern = ParsedPattern.parse('~auth');
        expect(pattern.matches('authenticate'), isTrue);
        expect(pattern.matches('AuthService'), isTrue);
      });

      test('tolerates single character typos', () {
        final pattern = ParsedPattern.parse('~authentcate');
        expect(pattern.matches('authenticate'), isTrue);
      });

      test('tolerates missing characters', () {
        final pattern = ParsedPattern.parse('~autheicate');
        expect(pattern.matches('authenticate'), isTrue);
      });

      test('tolerates extra characters', () {
        final pattern = ParsedPattern.parse('~authenticatte');
        expect(pattern.matches('authenticate'), isTrue);
      });

      test('rejects completely different strings', () {
        final pattern = ParsedPattern.parse('~xyz');
        expect(pattern.matches('authenticate'), isFalse);
      });
    });

    group('Levenshtein distance', () {
      test('distance of identical strings is 0', () {
        expect(ParsedPattern.levenshteinDistance('hello', 'hello'), 0);
      });

      test('distance with one insertion', () {
        expect(ParsedPattern.levenshteinDistance('hello', 'helloo'), 1);
      });

      test('distance with one deletion', () {
        expect(ParsedPattern.levenshteinDistance('hello', 'hell'), 1);
      });

      test('distance with one substitution', () {
        expect(ParsedPattern.levenshteinDistance('hello', 'hallo'), 1);
      });

      test('distance with multiple edits', () {
        expect(ParsedPattern.levenshteinDistance('kitten', 'sitting'), 3);
      });

      test('distance with empty string', () {
        expect(ParsedPattern.levenshteinDistance('', 'hello'), 5);
        expect(ParsedPattern.levenshteinDistance('hello', ''), 5);
      });
    });
  });

  group('ScipQuery pattern integration', () {
    test('parsedPattern returns correct type', () {
      expect(
        ScipQuery.parse('find Auth*').parsedPattern.type,
        PatternType.glob,
      );
      expect(
        ScipQuery.parse('grep /TODO/').parsedPattern.type,
        PatternType.regex,
      );
      expect(
        ScipQuery.parse('find ~respnse').parsedPattern.type,
        PatternType.fuzzy,
      );
    });

    test('caseInsensitive flag affects pattern', () {
      final query = ScipQuery.parse('grep pattern -i');
      expect(query.caseInsensitive, isTrue);
      expect(query.parsedPattern.caseSensitive, isFalse);
    });

    test('contextLines parses correctly', () {
      expect(ScipQuery.parse('grep pattern').contextLines, 2); // Default
      expect(ScipQuery.parse('grep pattern -C:5').contextLines, 5);
      expect(ScipQuery.parse('grep pattern context:3').contextLines, 3);
    });

    test('isQualified returns false for regex patterns', () {
      expect(ScipQuery.parse('refs /Class.method/').isQualified, isFalse);
      expect(ScipQuery.parse('refs Class.method').isQualified, isTrue);
    });
  });
}

