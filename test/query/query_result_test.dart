// ignore_for_file: implementation_imports
import 'dart:convert';

import 'package:dart_context/dart_context.dart';
import 'package:dart_context/dart_context.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('QueryResult', () {
    final testSymbol = SymbolInfo(
      symbol: 'test lib/foo.dart/MyClass#',
      kind: scip.SymbolInformation_Kind.Class,
      documentation: ['A test class.'],
      relationships: [],
      displayName: 'MyClass',
      file: 'lib/foo.dart',
    );

    final testOccurrence = OccurrenceInfo(
      file: 'lib/foo.dart',
      symbol: 'test lib/foo.dart/MyClass#',
      line: 10,
      column: 6,
      endLine: 10,
      endColumn: 13,
      isDefinition: true,
    );

    group('DefinitionResult', () {
      test('isEmpty is true when no definitions', () {
        final result = DefinitionResult([]);
        expect(result.isEmpty, isTrue);
        expect(result.count, 0);
      });

      test('isEmpty is false when has definitions', () {
        final result = DefinitionResult([
          DefinitionMatch(
            symbol: testSymbol,
            location: testOccurrence,
            source: 'class MyClass {}',
          ),
        ]);
        expect(result.isEmpty, isFalse);
        expect(result.count, 1);
      });

      test('toText includes symbol name and kind', () {
        final result = DefinitionResult([
          DefinitionMatch(
            symbol: testSymbol,
            location: testOccurrence,
            source: 'class MyClass {}',
          ),
        ]);

        final text = result.toText();
        expect(text, contains('MyClass'));
        expect(text, contains('class'));
        expect(text, contains('lib/foo.dart'));
      });

      test('toText shows no definitions message when empty', () {
        final result = DefinitionResult([]);
        expect(result.toText(), contains('No definitions found'));
      });

      test('toJson returns correct structure', () {
        final result = DefinitionResult([
          DefinitionMatch(
            symbol: testSymbol,
            location: testOccurrence,
            source: 'class MyClass {}',
          ),
        ]);

        final json = result.toJson();
        expect(json['type'], 'definitions');
        expect(json['count'], 1);
        expect(json['results'], isList);
        expect(json['results'][0]['name'], 'MyClass');
        expect(json['results'][0]['kind'], 'class');
        expect(json['results'][0]['source'], 'class MyClass {}');
      });

      test('toJson can be encoded to JSON string', () {
        final result = DefinitionResult([
          DefinitionMatch(
            symbol: testSymbol,
            location: testOccurrence,
            source: null,
          ),
        ]);

        expect(() => jsonEncode(result.toJson()), returnsNormally);
      });
    });

    group('ReferencesResult', () {
      test('groups references by file in toText', () {
        final result = ReferencesResult(
          symbol: testSymbol,
          references: [
            ReferenceMatch(
              location: OccurrenceInfo(
                file: 'lib/a.dart',
                symbol: 'test',
                line: 10,
                column: 5,
                endLine: 10,
                endColumn: 12,
                isDefinition: false,
              ),
              context: 'final x = MyClass();',
            ),
            ReferenceMatch(
              location: OccurrenceInfo(
                file: 'lib/a.dart',
                symbol: 'test',
                line: 20,
                column: 5,
                endLine: 20,
                endColumn: 12,
                isDefinition: false,
              ),
              context: 'return MyClass();',
            ),
            ReferenceMatch(
              location: OccurrenceInfo(
                file: 'lib/b.dart',
                symbol: 'test',
                line: 5,
                column: 0,
                endLine: 5,
                endColumn: 7,
                isDefinition: false,
              ),
              context: null,
            ),
          ],
        );

        final text = result.toText();
        expect(text, contains('lib/a.dart'));
        expect(text, contains('lib/b.dart'));
        expect(text, contains('3')); // Total count
      });

      test('toJson includes all references', () {
        final result = ReferencesResult(
          symbol: testSymbol,
          references: [
            ReferenceMatch(
              location: OccurrenceInfo(
                file: 'lib/a.dart',
                symbol: 'test',
                line: 10,
                column: 5,
                endLine: 10,
                endColumn: 12,
                isDefinition: false,
              ),
              context: 'code context',
            ),
          ],
        );

        final json = result.toJson();
        expect(json['type'], 'references');
        expect(json['count'], 1);
        expect(json['results'][0]['file'], 'lib/a.dart');
        expect(json['results'][0]['line'], 11); // 1-based
        expect(json['results'][0]['context'], 'code context');
      });
    });

    group('MembersResult', () {
      test('groups members by kind', () {
        final result = MembersResult(
          symbol: testSymbol,
          members: [
            SymbolInfo(
              symbol: 'test/foo#',
              kind: scip.SymbolInformation_Kind.Method,
              documentation: [],
              relationships: [],
              displayName: 'doSomething',
              file: 'lib/foo.dart',
            ),
            SymbolInfo(
              symbol: 'test/bar#',
              kind: scip.SymbolInformation_Kind.Field,
              documentation: [],
              relationships: [],
              displayName: 'myField',
              file: 'lib/foo.dart',
            ),
          ],
        );

        final text = result.toText();
        expect(text, contains('Methods'));
        expect(text, contains('Fields'));
        expect(text, contains('doSomething'));
        expect(text, contains('myField'));
      });
    });

    group('SearchResult', () {
      test('shows external symbols differently', () {
        final result = SearchResult([
          SymbolInfo(
            symbol: 'internal',
            kind: scip.SymbolInformation_Kind.Class,
            documentation: [],
            relationships: [],
            displayName: 'InternalClass',
            file: 'lib/internal.dart',
          ),
          SymbolInfo(
            symbol: 'external',
            kind: scip.SymbolInformation_Kind.Class,
            documentation: [],
            relationships: [],
            displayName: 'ExternalClass',
            file: null, // External
          ),
        ]);

        final text = result.toText();
        expect(text, contains('lib/internal.dart'));
        expect(text, contains('external'));
      });
    });

    group('HierarchyResult', () {
      test('shows supertypes and subtypes', () {
        final result = HierarchyResult(
          symbol: testSymbol,
          supertypes: [
            SymbolInfo(
              symbol: 'parent',
              kind: scip.SymbolInformation_Kind.Class,
              documentation: [],
              relationships: [],
              displayName: 'Parent',
              file: null,
            ),
          ],
          subtypes: [
            SymbolInfo(
              symbol: 'child',
              kind: scip.SymbolInformation_Kind.Class,
              documentation: [],
              relationships: [],
              displayName: 'Child',
              file: null,
            ),
          ],
        );

        final text = result.toText();
        expect(text, contains('Supertypes'));
        expect(text, contains('Subtypes'));
        expect(text, contains('Parent'));
        expect(text, contains('Child'));
      });

      test('isEmpty when no hierarchy', () {
        final result = HierarchyResult(
          symbol: testSymbol,
          supertypes: [],
          subtypes: [],
        );

        expect(result.isEmpty, isTrue);
      });
    });

    group('StatsResult', () {
      test('formats statistics', () {
        final result = StatsResult({
          'files': 10,
          'symbols': 100,
          'references': 500,
        });

        final text = result.toText();
        expect(text, contains('10'));
        expect(text, contains('100'));
        expect(text, contains('500'));
      });
    });

    group('ErrorResult', () {
      test('formats error message', () {
        final result = ErrorResult('Something went wrong');
        expect(result.toText(), 'Error: Something went wrong');
        expect(result.isEmpty, isTrue);
        expect(result.toJson()['type'], 'error');
        expect(result.toJson()['error'], 'Something went wrong');
      });
    });

    group('NotFoundResult', () {
      test('returns message', () {
        final result = NotFoundResult('Symbol not found');
        expect(result.toText(), 'Symbol not found');
        expect(result.isEmpty, isTrue);
        expect(result.toJson()['type'], 'not_found');
      });
    });
  });
}

