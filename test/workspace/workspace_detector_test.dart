import 'dart:io';

import 'package:dart_context/src/workspace/workspace_detector.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorkspaceDetector', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('workspace_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    group('detectWorkspace', () {
      test('returns null for empty directory', () async {
        final result = await detectWorkspace(tempDir.path);
        expect(result, isNull);
      });

      test('detects single package', () async {
        await File(p.join(tempDir.path, 'pubspec.yaml')).writeAsString('''
name: my_app
environment:
  sdk: ^3.0.0
''');

        final result = await detectWorkspace(tempDir.path);

        expect(result, isNotNull);
        expect(result!.type, WorkspaceType.single);
        expect(result.packages.length, 1);
        expect(result.packages.first.name, 'my_app');
      });

      test('detects melos workspace', () async {
        // Create melos.yaml
        await File(p.join(tempDir.path, 'melos.yaml')).writeAsString('''
name: my_workspace
packages:
  - packages/**
''');

        // Create root pubspec
        await File(p.join(tempDir.path, 'pubspec.yaml')).writeAsString('''
name: my_workspace
''');

        // Create a package
        final pkgDir = Directory(p.join(tempDir.path, 'packages', 'my_pkg'));
        await pkgDir.create(recursive: true);
        await File(p.join(pkgDir.path, 'pubspec.yaml')).writeAsString('''
name: my_pkg
environment:
  sdk: ^3.0.0
''');

        final result = await detectWorkspace(tempDir.path);

        expect(result, isNotNull);
        expect(result!.type, WorkspaceType.melos);
        expect(result.melosConfig, isNotNull);
        expect(result.melosConfig!.name, 'my_workspace');
        expect(result.packages.length, 1);
        expect(result.packages.first.name, 'my_pkg');
      });

      test('detects pub workspace', () async {
        // Create pubspec with workspace field
        await File(p.join(tempDir.path, 'pubspec.yaml')).writeAsString('''
name: my_workspace
workspace:
  - packages/pkg_a
  - packages/pkg_b
''');

        // Create packages
        final pkgA = Directory(p.join(tempDir.path, 'packages', 'pkg_a'));
        final pkgB = Directory(p.join(tempDir.path, 'packages', 'pkg_b'));
        await pkgA.create(recursive: true);
        await pkgB.create(recursive: true);

        await File(p.join(pkgA.path, 'pubspec.yaml')).writeAsString('''
name: pkg_a
''');
        await File(p.join(pkgB.path, 'pubspec.yaml')).writeAsString('''
name: pkg_b
''');

        final result = await detectWorkspace(tempDir.path);

        expect(result, isNotNull);
        expect(result!.type, WorkspaceType.pubWorkspace);
        // Root + 2 packages
        expect(result.packages.length, 3);
        expect(result.packages.map((p) => p.name), contains('my_workspace'));
        expect(result.packages.map((p) => p.name), contains('pkg_a'));
        expect(result.packages.map((p) => p.name), contains('pkg_b'));
      });

      test('melos respects ignore patterns', () async {
        await File(p.join(tempDir.path, 'melos.yaml')).writeAsString('''
name: workspace
packages:
  - packages/**
ignore:
  - packages/ignored/**
''');

        await File(p.join(tempDir.path, 'pubspec.yaml')).writeAsString('''
name: workspace
''');

        // Create included package
        final includedDir =
            Directory(p.join(tempDir.path, 'packages', 'included'));
        await includedDir.create(recursive: true);
        await File(p.join(includedDir.path, 'pubspec.yaml')).writeAsString('''
name: included
''');

        // Create ignored package
        final ignoredDir =
            Directory(p.join(tempDir.path, 'packages', 'ignored', 'sub'));
        await ignoredDir.create(recursive: true);
        await File(p.join(ignoredDir.path, 'pubspec.yaml')).writeAsString('''
name: ignored
''');

        final result = await detectWorkspace(tempDir.path);

        expect(result, isNotNull);
        expect(result!.packages.map((p) => p.name), contains('included'));
        expect(result.packages.map((p) => p.name), isNot(contains('ignored')));
      });

      test('findPackageForPath returns correct package', () async {
        await File(p.join(tempDir.path, 'pubspec.yaml')).writeAsString('''
name: workspace
workspace:
  - packages/pkg_a
''');

        final pkgA = Directory(p.join(tempDir.path, 'packages', 'pkg_a'));
        await pkgA.create(recursive: true);
        await File(p.join(pkgA.path, 'pubspec.yaml')).writeAsString('''
name: pkg_a
''');
        // Create lib directory
        await Directory(p.join(pkgA.path, 'lib')).create(recursive: true);

        final result = await detectWorkspace(tempDir.path);
        expect(result, isNotNull);

        // Find by file path within the package
        final pkg = result!.findPackageForPath(p.join(pkgA.path, 'lib', 'foo.dart'));
        expect(pkg, isNotNull);
        // The result could be the package itself or the root (if root path is prefix of package)
        // Find the most specific match
        expect(pkg!.absolutePath, pkgA.absolute.path);
        expect(pkg.name, 'pkg_a');

        // Non-existent path should return null
        final unknown = result.findPackageForPath('/some/other/path');
        expect(unknown, isNull);
      });

      test('walks up directories to find workspace', () async {
        // Create workspace root with melos.yaml
        await File(p.join(tempDir.path, 'melos.yaml')).writeAsString('''
name: workspace
packages:
  - packages/**
''');

        await File(p.join(tempDir.path, 'pubspec.yaml')).writeAsString('''
name: workspace
''');

        // Create nested package
        final pkgDir = Directory(p.join(tempDir.path, 'packages', 'my_pkg'));
        await pkgDir.create(recursive: true);
        await File(p.join(pkgDir.path, 'pubspec.yaml')).writeAsString('''
name: my_pkg
''');

        // Detect from package path (should walk up)
        final result = await detectWorkspace(pkgDir.path);

        expect(result, isNotNull);
        expect(result!.type, WorkspaceType.melos);
        expect(result.rootPath, tempDir.path);
      });
    });

    group('detectWorkspaceSync', () {
      test('detects single package synchronously', () async {
        await File(p.join(tempDir.path, 'pubspec.yaml')).writeAsString('''
name: sync_test
''');

        final result = detectWorkspaceSync(tempDir.path);

        expect(result, isNotNull);
        expect(result!.type, WorkspaceType.single);
        expect(result.packages.first.name, 'sync_test');
      });
    });

    group('workspaceToJson', () {
      test('serializes workspace info', () async {
        await File(p.join(tempDir.path, 'pubspec.yaml')).writeAsString('''
name: test_pkg
''');

        final workspace = await detectWorkspace(tempDir.path);
        expect(workspace, isNotNull);

        final json = workspaceToJson(workspace!);

        expect(json['type'], 'single');
        expect(json['rootPath'], tempDir.path);
        expect(json['packages'], isA<List>());
        expect((json['packages'] as List).first['name'], 'test_pkg');
      });
    });
  });
}

