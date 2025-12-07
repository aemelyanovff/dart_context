// Tests for output improvements:
// - Symbol name extraction from SCIP IDs
// - Pluralization of kind names
// - Members filtering (no parameters)
// - sig formatting with newlines

// ignore_for_file: implementation_imports
import 'package:dart_context/src/index/scip_index.dart';
import 'package:dart_context/src/query/query_result.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('SymbolInfo name extraction', () {
    test('extracts simple name from symbol ID', () {
      final sym = SymbolInfo(
        symbol: 'scip-dart pub test 1.0.0 lib/foo.dart/MyClass#',
        kind: scip.SymbolInformation_Kind.Class,
        documentation: [],
        relationships: [],
        displayName: null,
      );
      expect(sym.name, 'MyClass');
    });

    test('extracts method name from symbol ID', () {
      final sym = SymbolInfo(
        symbol: 'scip-dart pub test 1.0.0 lib/foo.dart/MyClass#myMethod().',
        kind: scip.SymbolInformation_Kind.Method,
        documentation: [],
        relationships: [],
        displayName: null,
      );
      expect(sym.name, 'myMethod');
    });

    test('extracts getter name from backtick format', () {
      final sym = SymbolInfo(
        symbol:
            'scip-dart pub test 1.0.0 lib/foo.dart/MyClass#`<get>myProperty`.',
        kind: scip.SymbolInformation_Kind.Getter,
        documentation: [],
        relationships: [],
        displayName: null,
      );
      expect(sym.name, 'myProperty');
    });

    test('extracts setter name from backtick format', () {
      final sym = SymbolInfo(
        symbol:
            'scip-dart pub test 1.0.0 lib/foo.dart/MyClass#`<set>myProperty`.',
        kind: scip.SymbolInformation_Kind.Setter,
        documentation: [],
        relationships: [],
        displayName: null,
      );
      expect(sym.name, 'myProperty');
    });

    test('extracts class name for constructor', () {
      final sym = SymbolInfo(
        symbol:
            'scip-dart pub test 1.0.0 lib/foo.dart/MyClass#`<constructor>`().',
        kind: scip.SymbolInformation_Kind.Constructor,
        documentation: [],
        relationships: [],
        displayName: null,
      );
      expect(sym.name, 'MyClass');
    });

    test('extracts backtick-escaped file name', () {
      final sym = SymbolInfo(
        symbol: 'scip-dart pub test 1.0.0 lib/`my_file.dart`/MyClass#',
        kind: scip.SymbolInformation_Kind.Class,
        documentation: [],
        relationships: [],
        displayName: null,
      );
      // Should still extract MyClass, not the file name
      expect(sym.name, 'MyClass');
    });

    test('prefers displayName when available', () {
      final sym = SymbolInfo(
        symbol: 'scip-dart pub test 1.0.0 lib/foo.dart/MyClass#',
        kind: scip.SymbolInformation_Kind.Class,
        documentation: [],
        relationships: [],
        displayName: 'CustomName',
      );
      expect(sym.name, 'CustomName');
    });
  });

  group('MembersResult formatting', () {
    test('uses proper plural for classes', () {
      final result = MembersResult(
        symbol: SymbolInfo(
          symbol: 'test/Container#',
          kind: scip.SymbolInformation_Kind.Class,
          documentation: [],
          relationships: [],
          displayName: 'Container',
        ),
        members: [
          SymbolInfo(
            symbol: 'test/Container#Inner#',
            kind: scip.SymbolInformation_Kind.Class,
            documentation: [],
            relationships: [],
            displayName: 'Inner',
          ),
        ],
      );

      final text = result.toText();
      expect(text, contains('Classes'));
      expect(text, isNot(contains('classs')));
    });

    test('uses proper plural for properties', () {
      final result = MembersResult(
        symbol: SymbolInfo(
          symbol: 'test/MyClass#',
          kind: scip.SymbolInformation_Kind.Class,
          documentation: [],
          relationships: [],
          displayName: 'MyClass',
        ),
        members: [
          SymbolInfo(
            symbol: 'test/MyClass#`<get>name`.',
            kind: scip.SymbolInformation_Kind.Property,
            documentation: [],
            relationships: [],
            displayName: null,
          ),
        ],
      );

      final text = result.toText();
      expect(text, contains('Properties'));
      expect(text, isNot(contains('propertys')));
    });
  });

  group('CallGraphResult formatting', () {
    test('uses proper plural for functions', () {
      final result = CallGraphResult(
        symbol: SymbolInfo(
          symbol: 'test/myFunc().',
          kind: scip.SymbolInformation_Kind.Function,
          documentation: [],
          relationships: [],
          displayName: 'myFunc',
        ),
        connections: [
          SymbolInfo(
            symbol: 'test/otherFunc().',
            kind: scip.SymbolInformation_Kind.Function,
            documentation: [],
            relationships: [],
            displayName: 'otherFunc',
          ),
        ],
        direction: 'callers',
      );

      final text = result.toText();
      expect(text, contains('Functions'));
      expect(text, isNot(contains('functions')));
    });

    test('uses proper plural for classes', () {
      final result = CallGraphResult(
        symbol: SymbolInfo(
          symbol: 'test/myFunc().',
          kind: scip.SymbolInformation_Kind.Function,
          documentation: [],
          relationships: [],
          displayName: 'myFunc',
        ),
        connections: [
          SymbolInfo(
            symbol: 'test/MyClass#method().',
            kind: scip.SymbolInformation_Kind.Class,
            documentation: [],
            relationships: [],
            displayName: 'MyClass',
          ),
        ],
        direction: 'callers',
      );

      final text = result.toText();
      expect(text, contains('Classes'));
      expect(text, isNot(contains('classs')));
    });
  });

  group('DependenciesResult formatting', () {
    test('uses proper plural for type aliases', () {
      final result = DependenciesResult(
        symbol: SymbolInfo(
          symbol: 'test/MyClass#',
          kind: scip.SymbolInformation_Kind.Class,
          documentation: [],
          relationships: [],
          displayName: 'MyClass',
        ),
        dependencies: [
          SymbolInfo(
            symbol: 'test/MyCallback.',
            kind: scip.SymbolInformation_Kind.TypeAlias,
            documentation: [],
            relationships: [],
            displayName: 'MyCallback',
          ),
        ],
      );

      final text = result.toText();
      expect(text, contains('Type Aliases'));
      expect(text, isNot(contains('typealiass')));
    });
  });

  group('ScipIndex members filtering', () {
    late ScipIndex index;

    setUp(() {
      index = ScipIndex.empty(projectRoot: '/test');

      // Add a class with methods and parameters
      index.updateDocument(
        scip.Document(
          relativePath: 'lib/test.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/test.dart/MyClass#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'MyClass',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/test.dart/MyClass#myMethod().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'myMethod',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/test.dart/MyClass#myMethod().(param)',
              kind: scip.SymbolInformation_Kind.Parameter,
              displayName: 'param',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/test.dart/MyClass#`<get>prop`.',
              kind: scip.SymbolInformation_Kind.Property,
              displayName: null, // Test name extraction
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/test.dart/MyClass#',
              range: [5, 6, 5, 13],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
            scip.Occurrence(
              symbol: 'test lib/test.dart/MyClass#myMethod().',
              range: [10, 2, 10, 10],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
            scip.Occurrence(
              symbol: 'test lib/test.dart/MyClass#myMethod().(param)',
              range: [10, 20, 10, 25],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
            scip.Occurrence(
              symbol: 'test lib/test.dart/MyClass#`<get>prop`.',
              range: [15, 2, 15, 6],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
          ],
        ),
      );
    });

    test('membersOf includes methods and properties', () {
      final members = index.membersOf('test lib/test.dart/MyClass#').toList();

      final names = members.map((m) => m.name).toList();
      expect(names, contains('myMethod'));
      expect(names, contains('prop')); // Extracted from getter format
    });

    test('membersOf includes parameters (filtering is in QueryExecutor)', () {
      // Note: ScipIndex.membersOf doesn't filter - QueryExecutor does
      final members = index.membersOf('test lib/test.dart/MyClass#').toList();

      // Parameters are included at the index level
      final kinds = members.map((m) => m.kindString).toList();
      expect(kinds, contains('parameter'));
    });

    test('property name extracted correctly from getter format', () {
      final members = index.membersOf('test lib/test.dart/MyClass#').toList();
      final prop = members.firstWhere((m) => m.kindString == 'property');

      // Name should be 'prop', not the full SCIP ID
      expect(prop.name, 'prop');
    });
  });
}

