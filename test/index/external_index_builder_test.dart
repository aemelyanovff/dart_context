import 'dart:io';

import 'package:dart_context/dart_context.dart';
import 'package:dart_context/dart_context.dart';
import 'package:test/test.dart';

void main() {
  group('ExternalIndexBuilder', () {
    late Directory tempDir;
    late Directory cacheDir;
    late PackageRegistry registry;
    late ExternalIndexBuilder builder;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ext_builder_test_');
      cacheDir = Directory('${tempDir.path}/cache');
      await cacheDir.create();
      
      // Create a mock project with package_config.json
      await Directory('${tempDir.path}/.dart_tool').create();
      await File('${tempDir.path}/.dart_tool/package_config.json').writeAsString('''
{
  "configVersion": 2,
  "packages": []
}
''');
      await File('${tempDir.path}/pubspec.yaml').writeAsString('''
name: test_project
environment:
  sdk: ^3.0.0
''');

      registry = PackageRegistry(
        rootPath: tempDir.path,
        globalCachePath: cacheDir.path,
      );
      builder = ExternalIndexBuilder(registry: registry);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    group('indexSdk', () {
      test('returns error for non-existent SDK path', () async {
        final result = await builder.indexSdk('/nonexistent/sdk/path');

        expect(result.success, isFalse);
        expect(result.error, isNotNull);
      });

      test('returns error for invalid SDK (no version file)', () async {
        // Create fake SDK dir without version file
        final fakeSdk = Directory('${tempDir.path}/fake_sdk');
        await fakeSdk.create();
        await Directory('${fakeSdk.path}/lib').create();

        final result = await builder.indexSdk(fakeSdk.path);

        expect(result.success, isFalse);
        expect(result.error, contains('version'));
      });

      test('accepts explicit version parameter', () async {
        // Create minimal fake SDK
        final fakeSdk = Directory('${tempDir.path}/fake_sdk');
        await fakeSdk.create();
        await Directory('${fakeSdk.path}/lib').create();
        await File('${fakeSdk.path}/version').writeAsString('3.2.0');

        // Will still fail due to missing libs, but version should be accepted
        final result = await builder.indexSdk(fakeSdk.path, version: '3.2.0');

        // May fail for other reasons but not version detection
        expect(result.error, isNot(contains('version file')));
      });
    });

    group('indexPackage', () {
      test('returns error for non-existent package path', () async {
        final result = await builder.indexPackage(
          'nonexistent',
          '1.0.0',
          '/nonexistent/package/path',
        );

        expect(result.success, isFalse);
        expect(result.error, isNotNull);
      });

      test('returns error for package without pubspec', () async {
        // Create package dir without pubspec
        final pkgDir = Directory('${tempDir.path}/fake_pkg');
        await pkgDir.create();
        await Directory('${pkgDir.path}/lib').create();

        final result = await builder.indexPackage('fake_pkg', '1.0.0', pkgDir.path);

        expect(result.success, isFalse);
        expect(result.error, isNotNull);
      });

      test('indexes valid package structure', () async {
        // Create a minimal valid package
        final pkgDir = Directory('${tempDir.path}/my_pkg');
        await pkgDir.create();
        await Directory('${pkgDir.path}/lib').create();
        await File('${pkgDir.path}/pubspec.yaml').writeAsString('''
name: my_pkg
version: 1.0.0
environment:
  sdk: ^3.0.0
''');
        await File('${pkgDir.path}/lib/my_pkg.dart').writeAsString('''
/// My package library
library my_pkg;

class MyClass {}
''');

        // Create package_config for the package
        await Directory('${pkgDir.path}/.dart_tool').create();
        await File('${pkgDir.path}/.dart_tool/package_config.json').writeAsString('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "my_pkg",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    }
  ]
}
''');

        final result = await builder.indexPackage('my_pkg', '1.0.0', pkgDir.path);

        expect(result.success, isTrue);
        expect(result.stats?['symbols'], greaterThan(0));
      });
    });

    group('indexDependencies', () {
      test('returns error for missing pubspec.lock', () async {
        final result = await builder.indexDependencies(tempDir.path);

        expect(result.success, isFalse);
        expect(result.error, contains('pubspec.lock'));
      });

      test('skips already indexed packages', () async {
        // Create pubspec.lock with a package
        await File('${tempDir.path}/pubspec.lock').writeAsString('''
packages:
  collection:
    dependency: "direct main"
    description:
      name: collection
      sha256: "123"
      url: "https://pub.dev"
    source: hosted
    version: "1.18.0"
sdks:
  dart: ">=3.0.0 <4.0.0"
''');

        // Mark collection as already indexed (using new 'hosted/' path)
        final indexDir = Directory('${registry.globalCachePath}/hosted/collection-1.18.0');
        await indexDir.create(recursive: true);
        await File('${indexDir.path}/manifest.json').writeAsString('{}');
        await File('${indexDir.path}/index.scip').writeAsBytes([]);

        final result = await builder.indexDependencies(tempDir.path);

        expect(result.success, isTrue);
        expect(result.skipped, equals(1));
        expect(result.results.first.skipped, isTrue);
        expect(result.results.first.reason, contains('already indexed'));
      });

      test('reports progress via callback', () async {
        await File('${tempDir.path}/pubspec.lock').writeAsString('''
packages:
  fake_pkg:
    dependency: "direct main"
    description:
      name: fake_pkg
      sha256: "123"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
sdks:
  dart: ">=3.0.0 <4.0.0"
''');

        final messages = <String>[];
        await builder.indexDependencies(
          tempDir.path,
          onProgress: messages.add,
        );

        expect(messages, isNotEmpty);
        expect(messages.first, contains('Found'));
      });

      test('uses concurrency parameter', () async {
        await File('${tempDir.path}/pubspec.lock').writeAsString('''
packages:
sdks:
  dart: ">=3.0.0 <4.0.0"
''');

        // Should not throw with different concurrency values
        await builder.indexDependencies(tempDir.path, concurrency: 1);
        await builder.indexDependencies(tempDir.path, concurrency: 8);
      });
    });

    group('indexFlutterPackages', () {
      test('returns error for invalid Flutter structure', () async {
        // Create a directory that exists but isn't a valid Flutter SDK
        final badFlutter = Directory('${tempDir.path}/bad_flutter');
        await badFlutter.create();
        
        final result = await builder.indexFlutterPackages(
          flutterPath: badFlutter.path,
        );

        expect(result.success, isFalse);
        expect(result.error, isNotNull);
      });

      test('returns error for Flutter without packages dir', () async {
        // Create fake Flutter dir without packages
        final fakeFlutter = Directory('${tempDir.path}/flutter');
        await fakeFlutter.create();
        await File('${fakeFlutter.path}/version').writeAsString('3.16.0');

        final result = await builder.indexFlutterPackages(
          flutterPath: fakeFlutter.path,
        );

        expect(result.success, isFalse);
        expect(result.error, contains('packages'));
      });

      test('reports progress via callback when valid Flutter found', () async {
        // This test requires a valid Flutter SDK structure
        // Skip if we don't have one - just verify callback mechanism works
        final fakeFlutter = Directory('${tempDir.path}/flutter');
        await fakeFlutter.create();
        await File('${fakeFlutter.path}/version').writeAsString('3.16.0');
        await Directory('${fakeFlutter.path}/packages').create();

        final messages = <String>[];
        final result = await builder.indexFlutterPackages(
          flutterPath: fakeFlutter.path,
          onProgress: messages.add,
        );

        // Will fail because no actual packages, but that's expected
        // Just verify result is returned properly
        expect(result.success, isFalse);
      });
    });

    group('listSdkIndexes', () {
      test('returns empty list when no indexes exist', () async {
        final versions = await builder.listSdkIndexes();
        expect(versions, isEmpty);
      });

      test('returns available SDK versions', () async {
        // Create fake SDK index dirs
        final sdkDir = Directory('${registry.globalCachePath}/sdk/3.2.0');
        await sdkDir.create(recursive: true);
        await File('${sdkDir.path}/manifest.json').writeAsString('{}');

        final sdkDir2 = Directory('${registry.globalCachePath}/sdk/3.1.0');
        await sdkDir2.create(recursive: true);
        await File('${sdkDir2.path}/manifest.json').writeAsString('{}');

        final versions = await builder.listSdkIndexes();

        expect(versions, containsAll(['3.2.0', '3.1.0']));
      });
    });

    group('listPackageIndexes', () {
      test('returns empty list when no indexes exist', () async {
        final packages = await builder.listPackageIndexes();
        expect(packages, isEmpty);
      });

      test('returns available package indexes', () async {
        // Create fake package index dirs
        final pkgDir = Directory('${registry.globalCachePath}/hosted/analyzer-6.3.0');
        await pkgDir.create(recursive: true);
        await File('${pkgDir.path}/manifest.json').writeAsString('{}');

        final pkgDir2 = Directory('${registry.globalCachePath}/hosted/collection-1.18.0');
        await pkgDir2.create(recursive: true);
        await File('${pkgDir2.path}/manifest.json').writeAsString('{}');

        final packages = await builder.listPackageIndexes();

        expect(packages.length, equals(2));
        expect(packages.map((p) => p.name), containsAll(['analyzer', 'collection']));
        expect(packages.map((p) => p.version), containsAll(['6.3.0', '1.18.0']));
      });
    });
  });
}

