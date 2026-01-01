import 'package:dart_context/dart_context.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('ScipQuery.parse', () {
    group('basic actions', () {
      test('parses def action', () {
        final query = ScipQuery.parse('def MyClass');
        expect(query.action, QueryAction.definition);
        expect(query.target, 'MyClass');
        expect(query.filters, isEmpty);
      });

      test('parses refs action', () {
        final query = ScipQuery.parse('refs login');
        expect(query.action, QueryAction.references);
        expect(query.target, 'login');
      });

      test('parses members action', () {
        final query = ScipQuery.parse('members AuthRepository');
        expect(query.action, QueryAction.members);
        expect(query.target, 'AuthRepository');
      });

      test('parses impls action', () {
        final query = ScipQuery.parse('impls BaseWidget');
        expect(query.action, QueryAction.implementations);
        expect(query.target, 'BaseWidget');
      });

      test('parses implementations as alias', () {
        final query = ScipQuery.parse('implementations BaseWidget');
        expect(query.action, QueryAction.implementations);
      });

      test('parses supertypes action', () {
        final query = ScipQuery.parse('supertypes MyClass');
        expect(query.action, QueryAction.supertypes);
        expect(query.target, 'MyClass');
      });

      test('parses super as alias', () {
        final query = ScipQuery.parse('super MyClass');
        expect(query.action, QueryAction.supertypes);
      });

      test('parses subtypes action', () {
        final query = ScipQuery.parse('subtypes BaseClass');
        expect(query.action, QueryAction.subtypes);
        expect(query.target, 'BaseClass');
      });

      test('parses hierarchy action', () {
        final query = ScipQuery.parse('hierarchy Widget');
        expect(query.action, QueryAction.hierarchy);
        expect(query.target, 'Widget');
      });

      test('parses source action', () {
        final query = ScipQuery.parse('source myFunction');
        expect(query.action, QueryAction.source);
        expect(query.target, 'myFunction');
      });

      test('parses src as alias for source', () {
        final query = ScipQuery.parse('src myFunction');
        expect(query.action, QueryAction.source);
      });

      test('parses find action', () {
        final query = ScipQuery.parse('find Auth*');
        expect(query.action, QueryAction.find);
        expect(query.target, 'Auth*');
      });

      test('parses search as alias for find', () {
        final query = ScipQuery.parse('search Auth*');
        expect(query.action, QueryAction.find);
      });

      test('parses files action without target', () {
        final query = ScipQuery.parse('files');
        expect(query.action, QueryAction.files);
        expect(query.target, '');
      });

      test('parses stats action without target', () {
        final query = ScipQuery.parse('stats');
        expect(query.action, QueryAction.stats);
        expect(query.target, '');
      });
    });

    group('filters', () {
      test('parses kind filter', () {
        final query = ScipQuery.parse('find * kind:class');
        expect(query.action, QueryAction.find);
        expect(query.target, '*');
        expect(query.filters['kind'], 'class');
        expect(query.kindFilter, scip.SymbolInformation_Kind.Class);
      });

      test('parses in filter', () {
        final query = ScipQuery.parse('find * in:lib/auth/');
        expect(query.filters['in'], 'lib/auth/');
        expect(query.pathFilter, 'lib/auth/');
      });

      test('parses multiple filters', () {
        final query = ScipQuery.parse('find * kind:method in:lib/');
        expect(query.filters['kind'], 'method');
        expect(query.filters['in'], 'lib/');
        expect(query.kindFilter, scip.SymbolInformation_Kind.Method);
      });

      test('parses various kind values', () {
        final kinds = {
          'class': scip.SymbolInformation_Kind.Class,
          'method': scip.SymbolInformation_Kind.Method,
          'function': scip.SymbolInformation_Kind.Function,
          'field': scip.SymbolInformation_Kind.Field,
          'constructor': scip.SymbolInformation_Kind.Constructor,
          'enum': scip.SymbolInformation_Kind.Enum,
          'mixin': scip.SymbolInformation_Kind.Mixin,
          'extension': scip.SymbolInformation_Kind.Extension,
          'getter': scip.SymbolInformation_Kind.Getter,
          'setter': scip.SymbolInformation_Kind.Setter,
        };

        for (final entry in kinds.entries) {
          final query = ScipQuery.parse('find * kind:${entry.key}');
          expect(query.kindFilter, entry.value, reason: 'kind:${entry.key}');
        }
      });

      test('returns null for unknown kind', () {
        final query = ScipQuery.parse('find * kind:unknown');
        expect(query.kindFilter, isNull);
      });
    });

    group('complex targets', () {
      test('handles dotted names', () {
        final query = ScipQuery.parse('def MyClass.myMethod');
        expect(query.target, 'MyClass.myMethod');
      });

      test('handles wildcards', () {
        final query = ScipQuery.parse('find Auth*Repository');
        expect(query.target, 'Auth*Repository');
      });

      test('handles quoted targets', () {
        final query = ScipQuery.parse('find "my symbol"');
        expect(query.target, 'my symbol');
      });

      test('handles single quoted targets', () {
        final query = ScipQuery.parse("find 'my symbol'");
        expect(query.target, 'my symbol');
      });
    });

    group('error handling', () {
      test('throws on empty query', () {
        expect(() => ScipQuery.parse(''), throwsFormatException);
      });

      test('throws on whitespace only', () {
        expect(() => ScipQuery.parse('   '), throwsFormatException);
      });

      test('throws on unknown action', () {
        expect(() => ScipQuery.parse('unknown foo'), throwsFormatException);
      });

      test('throws on missing target for def', () {
        expect(() => ScipQuery.parse('def'), throwsFormatException);
      });

      test('throws on missing target for refs', () {
        expect(() => ScipQuery.parse('refs'), throwsFormatException);
      });

      test('does not throw on missing target for files', () {
        expect(() => ScipQuery.parse('files'), returnsNormally);
      });

      test('does not throw on missing target for stats', () {
        expect(() => ScipQuery.parse('stats'), returnsNormally);
      });
    });

    group('case insensitivity', () {
      test('action is case insensitive', () {
        expect(ScipQuery.parse('DEF foo').action, QueryAction.definition);
        expect(ScipQuery.parse('Def foo').action, QueryAction.definition);
        expect(ScipQuery.parse('dEf foo').action, QueryAction.definition);
      });
    });

    group('toString', () {
      test('returns readable representation', () {
        final query = ScipQuery.parse('find Auth* kind:class');
        expect(query.toString(), contains('find'));
        expect(query.toString(), contains('Auth*'));
        expect(query.toString(), contains('kind:class'));
      });
    });
  });
}

