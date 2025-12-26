import 'dart:convert';
import 'dart:io';

import 'package:dart_context/src/utils/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('PackageConfig Parser', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pkg_config_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('parses empty package_config.json', () async {
      await _createPackageConfig(tempDir.path, []);

      final packages = await parsePackageConfig(tempDir.path);
      expect(packages, isEmpty);
    });

    test('parses hosted packages', () async {
      await _createPackageConfig(tempDir.path, [
        {
          'name': 'collection',
          'rootUri':
              'file:///Users/test/.pub-cache/hosted/pub.dev/collection-1.18.0',
          'packageUri': 'lib/',
        },
        {
          'name': 'meta',
          'rootUri': 'file:///Users/test/.pub-cache/hosted/pub.dev/meta-1.11.0',
          'packageUri': 'lib/',
        },
      ]);

      final packages = await parsePackageConfig(tempDir.path);

      expect(packages.length, 2);
      expect(packages[0].name, 'collection');
      expect(packages[0].source, DependencySource.hosted);
      expect(packages[0].version, '1.18.0');
      expect(packages[0].cacheKey, 'collection-1.18.0');

      expect(packages[1].name, 'meta');
      expect(packages[1].version, '1.11.0');
    });

    test('parses git packages', () async {
      await _createPackageConfig(tempDir.path, [
        {
          'name': 'fluxon',
          'rootUri':
              'file:///Users/test/.pub-cache/git/fluxon-bfef6c5e6909d853f20880bbc5272a826738fa58',
          'packageUri': 'lib/',
        },
      ]);

      final packages = await parsePackageConfig(tempDir.path);

      expect(packages.length, 1);
      expect(packages[0].name, 'fluxon');
      expect(packages[0].source, DependencySource.git);
      expect(packages[0].gitCommit, 'bfef6c5e6909d853f20880bbc5272a826738fa58');
      expect(packages[0].cacheKey, 'fluxon-bfef6c5e');
    });

    test('parses path dependencies', () async {
      await _createPackageConfig(tempDir.path, [
        {
          'name': 'shared_utils',
          'rootUri': '../packages/shared_utils',
          'packageUri': 'lib/',
        },
      ]);

      final packages = await parsePackageConfig(tempDir.path);

      expect(packages.length, 1);
      expect(packages[0].name, 'shared_utils');
      expect(packages[0].source, DependencySource.path);
      expect(packages[0].relativePath, '../packages/shared_utils');
      expect(packages[0].cacheKey, 'shared_utils');
    });

    test('parses mixed dependency sources', () async {
      await _createPackageConfig(tempDir.path, [
        {
          'name': 'hosted_pkg',
          'rootUri':
              'file:///Users/test/.pub-cache/hosted/pub.dev/hosted_pkg-2.0.0',
          'packageUri': 'lib/',
        },
        {
          'name': 'git_pkg',
          'rootUri':
              'file:///Users/test/.pub-cache/git/git_pkg-abc12345',
          'packageUri': 'lib/',
        },
        {
          'name': 'local_pkg',
          'rootUri': '../local_pkg',
          'packageUri': 'lib/',
        },
      ]);

      final packages = await parsePackageConfig(tempDir.path);

      expect(packages.hosted.length, 1);
      expect(packages.git.length, 1);
      expect(packages.path.length, 1);
    });

    test('handles Flutter SDK packages', () async {
      await _createPackageConfig(tempDir.path, [
        {
          'name': 'flutter',
          'rootUri':
              'file:///Users/test/Development/flutter/packages/flutter',
          'packageUri': 'lib/',
        },
      ]);

      final packages = await parsePackageConfig(tempDir.path);

      expect(packages.length, 1);
      expect(packages[0].name, 'flutter');
      expect(packages[0].source, DependencySource.sdk);
    });

    test('parsePackageConfigSync works', () async {
      await _createPackageConfig(tempDir.path, [
        {
          'name': 'sync_test',
          'rootUri':
              'file:///Users/test/.pub-cache/hosted/pub.dev/sync_test-1.0.0',
          'packageUri': 'lib/',
        },
      ]);

      final packages = parsePackageConfigSync(tempDir.path);

      expect(packages.length, 1);
      expect(packages[0].name, 'sync_test');
    });

    test('returns empty list for missing file', () async {
      final packages = await parsePackageConfig(tempDir.path);
      expect(packages, isEmpty);
    });

    test('ResolvedPackage extensions work', () async {
      await _createPackageConfig(tempDir.path, [
        {
          'name': 'h1',
          'rootUri': 'file:///test/.pub-cache/hosted/pub.dev/h1-1.0.0',
          'packageUri': 'lib/',
        },
        {
          'name': 'h2',
          'rootUri': 'file:///test/.pub-cache/hosted/pub.dev/h2-2.0.0',
          'packageUri': 'lib/',
        },
        {
          'name': 'g1',
          'rootUri': 'file:///test/.pub-cache/git/g1-abc123',
          'packageUri': 'lib/',
        },
        {
          'name': 'p1',
          'rootUri': '../p1',
          'packageUri': 'lib/',
        },
      ]);

      final packages = await parsePackageConfig(tempDir.path);

      expect(packages.hosted.length, 2);
      expect(packages.hosted.map((p) => p.name), containsAll(['h1', 'h2']));

      expect(packages.git.length, 1);
      expect(packages.git.first.name, 'g1');

      expect(packages.path.length, 1);
      expect(packages.path.first.name, 'p1');
    });
  });
}

Future<void> _createPackageConfig(
    String projectPath, List<Map<String, dynamic>> packages) async {
  final dartToolDir = Directory(p.join(projectPath, '.dart_tool'));
  await dartToolDir.create(recursive: true);

  final config = {
    'configVersion': 2,
    'packages': packages,
  };

  await File(p.join(dartToolDir.path, 'package_config.json'))
      .writeAsString(const JsonEncoder.withIndent('  ').convert(config));
}

