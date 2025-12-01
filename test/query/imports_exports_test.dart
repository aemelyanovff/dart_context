import 'dart:io';

import 'package:dart_context/src/index/scip_index.dart';
import 'package:dart_context/src/query/query_executor.dart';
import 'package:dart_context/src/query/query_result.dart';
import 'package:scip_dart/src/gen/scip.pb.dart' as scip;
import 'package:test/test.dart';

void main() {
  group('Imports/Exports queries', () {
    late Directory tempDir;
    late ScipIndex index;
    late QueryExecutor executor;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dart_context_imports_');

      final libDir = Directory('${tempDir.path}/lib');
      await libDir.create(recursive: true);

      // Create utils.dart that gets imported
      final utilsPath = '${tempDir.path}/lib/utils.dart';
      await File(utilsPath).writeAsString('''
// Utility functions
String formatMessage(String msg) => '[\${msg}]';
''');

      // Create service.dart that imports utils.dart
      final servicePath = '${tempDir.path}/lib/service.dart';
      await File(servicePath).writeAsString('''
import 'utils.dart';

class Service {
  void log(String msg) {
    formatMessage(msg);
  }
}
''');

      // Build index with documents for both files
      index = ScipIndex.empty(projectRoot: tempDir.path);

      index.updateDocument(
        scip.Document(
          relativePath: 'lib/utils.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/utils.dart/formatMessage().',
              kind: scip.SymbolInformation_Kind.Function,
              displayName: 'formatMessage',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/utils.dart/formatMessage().',
              range: [1, 0, 1, 12],
              symbolRoles: scip.SymbolRole.Definition.value,
            ),
          ],
        ),
      );

      index.updateDocument(
        scip.Document(
          relativePath: 'lib/service.dart',
          language: 'Dart',
          symbols: [
            scip.SymbolInformation(
              symbol: 'test lib/service.dart/Service#',
              kind: scip.SymbolInformation_Kind.Class,
              displayName: 'Service',
            ),
            scip.SymbolInformation(
              symbol: 'test lib/service.dart/Service#log().',
              kind: scip.SymbolInformation_Kind.Method,
              displayName: 'log',
            ),
          ],
          occurrences: [
            scip.Occurrence(
              symbol: 'test lib/service.dart/Service#',
              range: [3, 6, 3, 13],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [3, 0, 10, 1],
            ),
            scip.Occurrence(
              symbol: 'test lib/service.dart/Service#log().',
              range: [4, 7, 4, 10],
              symbolRoles: scip.SymbolRole.Definition.value,
              enclosingRange: [4, 2, 8, 3],
            ),
            scip.Occurrence(
              symbol: 'test lib/utils.dart/formatMessage().',
              range: [6, 4, 6, 16],
              symbolRoles: 0,
            ),
          ],
        ),
      );

      executor = QueryExecutor(index);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('imports returns symbols from imported files', () async {
      final result = await executor.execute('imports lib/service.dart');
      expect(result, isA<ImportsResult>());

      final importsResult = result as ImportsResult;
      expect(importsResult.importedSymbols, isNotEmpty);
      expect(
        importsResult.importedSymbols.any((s) => s.name == 'formatMessage'),
        isTrue,
      );
    });

    test('exports returns exported symbols from file', () async {
      final result = await executor.execute('exports lib/service.dart');
      expect(result, isA<ImportsResult>());

      final exportsResult = result as ImportsResult;
      expect(
        exportsResult.exportedSymbols.any((s) => s.name == 'Service'),
        isTrue,
      );
    });

    test('imports piping to refs', () async {
      final result = await executor.execute('imports lib/service.dart | refs');
      expect(result, isA<QueryResult>());
    });

    test('exports piping to members', () async {
      final result = await executor.execute('exports lib/service.dart | members');
      expect(result, isA<QueryResult>());
    });
  });
}

