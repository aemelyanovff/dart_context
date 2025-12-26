import 'dart:io';

import 'package:dart_context/src/index/external_index_builder.dart';
import 'package:dart_context/src/index/index_registry.dart';
import 'package:dart_context/src/index/scip_index.dart';
import 'package:test/test.dart';

void main() {
  group('ExternalIndexBuilder', () {
    late Directory tempDir;
    late IndexRegistry registry;
    late ExternalIndexBuilder builder;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mcp_tools_test_');
      final tempIndex = ScipIndex.empty(projectRoot: tempDir.path);
      registry = IndexRegistry(
        projectIndex: tempIndex,
        globalCachePath: '${tempDir.path}/.dart_context',
      );
      builder = ExternalIndexBuilder(registry: registry);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    group('indexFlutterPackages', () {
      test('returns error when packages dir does not exist', () async {
        // Create a fake flutter dir without packages
        final fakeFlutter = Directory('${tempDir.path}/fake_flutter');
        await fakeFlutter.create();
        await File('${fakeFlutter.path}/version').writeAsString('3.0.0');

        final result = await builder.indexFlutterPackages(
          flutterPath: fakeFlutter.path,
        );

        expect(result.success, isFalse);
        expect(result.error, contains('Flutter packages not found'));
      });

      test('calls onProgress callback when packages exist', () async {
        // Create a fake flutter dir with packages folder
        final fakeFlutter = Directory('${tempDir.path}/fake_flutter2');
        await fakeFlutter.create();
        await File('${fakeFlutter.path}/version').writeAsString('3.0.0');
        await Directory('${fakeFlutter.path}/packages').create();

        final messages = <String>[];

        await builder.indexFlutterPackages(
          flutterPath: fakeFlutter.path,
          onProgress: (msg) => messages.add(msg),
        );

        // Should have progress message about indexing
        expect(messages, isNotEmpty);
        expect(messages.first, contains('Indexing Flutter 3.0.0'));
      });
    });

    group('listPackageIndexes', () {
      test('returns empty list when no indexes exist', () async {
        final packages = await builder.listPackageIndexes();
        expect(packages, isEmpty);
      });

      test('returns indexed packages after indexing', () async {
        // Create a fake package index directory
        final pkgDir =
            Directory('${tempDir.path}/.dart_context/hosted/test_pkg-1.0.0');
        await pkgDir.create(recursive: true);
        await File('${pkgDir.path}/index.scip').writeAsString('');
        await File('${pkgDir.path}/manifest.json').writeAsString('{}');

        final packages = await builder.listPackageIndexes();
        expect(packages, hasLength(1));
        expect(packages.first.name, equals('test_pkg'));
        expect(packages.first.version, equals('1.0.0'));
      });
    });

    group('listSdkIndexes', () {
      test('returns empty list when no SDK indexes exist', () async {
        final versions = await builder.listSdkIndexes();
        expect(versions, isEmpty);
      });

      test('returns SDK versions after indexing', () async {
        // Create a fake SDK index directory
        final sdkDir = Directory('${tempDir.path}/.dart_context/sdk/3.2.0');
        await sdkDir.create(recursive: true);
        await File('${sdkDir.path}/index.scip').writeAsString('');
        await File('${sdkDir.path}/manifest.json').writeAsString('{}');

        final versions = await builder.listSdkIndexes();
        expect(versions, contains('3.2.0'));
      });
    });
  });

  group('FlutterIndexResult', () {
    test('calculates indexed count correctly', () {
      final result = FlutterIndexResult(
        success: true,
        version: '3.0.0',
        results: [
          PackageIndexResult(name: 'flutter', version: '3.0.0', success: true, symbolCount: 100),
          PackageIndexResult(name: 'flutter_test', version: '3.0.0', success: true, symbolCount: 50),
          PackageIndexResult(name: 'flutter_driver', version: '3.0.0', skipped: true, reason: 'not found'),
        ],
      );

      expect(result.indexed, equals(2));
      expect(result.skipped, equals(1));
      expect(result.failed, equals(0));
      expect(result.totalSymbols, equals(150));
    });

    test('calculates failed count correctly', () {
      final result = FlutterIndexResult(
        success: false,
        version: '3.0.0',
        results: [
          PackageIndexResult(name: 'flutter', version: '3.0.0', error: 'failed'),
          PackageIndexResult(name: 'flutter_test', version: '3.0.0', success: true, symbolCount: 50),
        ],
      );

      expect(result.indexed, equals(1));
      expect(result.failed, equals(1));
      expect(result.totalSymbols, equals(50));
    });
  });
}

