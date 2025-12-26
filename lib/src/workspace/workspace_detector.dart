import 'dart:convert';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:yaml/yaml.dart';

/// Type of workspace detected.
enum WorkspaceType {
  /// Melos mono repo (has melos.yaml).
  melos,

  /// Dart 3.0+ pub workspace (pubspec.yaml with workspace field).
  pubWorkspace,

  /// Single standalone package.
  single,
}

/// Information about a detected workspace.
class WorkspaceInfo {
  const WorkspaceInfo({
    required this.rootPath,
    required this.type,
    required this.packages,
    this.melosConfig,
  });

  /// Absolute path to the workspace root.
  final String rootPath;

  /// Type of workspace.
  final WorkspaceType type;

  /// List of packages in the workspace.
  final List<WorkspacePackage> packages;

  /// Melos configuration (if type is melos).
  final MelosConfig? melosConfig;

  /// Check if a file path belongs to any package in this workspace.
  ///
  /// Returns the most specific (deepest) package that contains the path.
  WorkspacePackage? findPackageForPath(String filePath) {
    // Normalize paths for comparison
    final normalizedPath = Directory(filePath).absolute.path;

    WorkspacePackage? bestMatch;
    var bestMatchLength = 0;

    for (final pkg in packages) {
      if (normalizedPath.startsWith(pkg.absolutePath)) {
        // Keep the most specific (longest path) match
        if (pkg.absolutePath.length > bestMatchLength) {
          bestMatch = pkg;
          bestMatchLength = pkg.absolutePath.length;
        }
      }
    }
    return bestMatch;
  }

  @override
  String toString() =>
      'WorkspaceInfo($type, root: $rootPath, packages: ${packages.length})';
}

/// A package within a workspace.
class WorkspacePackage {
  const WorkspacePackage({
    required this.name,
    required this.relativePath,
    required this.absolutePath,
  });

  /// Package name from pubspec.yaml.
  final String name;

  /// Path relative to workspace root.
  final String relativePath;

  /// Absolute path to package root.
  final String absolutePath;

  @override
  String toString() => 'WorkspacePackage($name, $relativePath)';
}

/// Melos configuration.
class MelosConfig {
  const MelosConfig({
    required this.name,
    required this.packageGlobs,
    required this.ignoreGlobs,
  });

  /// Workspace name.
  final String name;

  /// Package glob patterns.
  final List<String> packageGlobs;

  /// Ignore glob patterns.
  final List<String> ignoreGlobs;
}

/// Detect workspace from a starting path.
///
/// Walks up the directory tree looking for:
/// 1. melos.yaml (Melos mono repo)
/// 2. pubspec.yaml with workspace field (Dart 3.0+ pub workspace)
/// 3. Falls back to single package if pubspec.yaml found
///
/// Returns null if no Dart project is found.
Future<WorkspaceInfo?> detectWorkspace(String startPath) async {
  var current = Directory(startPath).absolute.path;

  // Walk up looking for workspace markers
  while (true) {
    // Check for Melos workspace
    final melosFile = File('$current/melos.yaml');
    if (await melosFile.exists()) {
      return _parseMelosWorkspace(current, melosFile);
    }

    // Check for Dart 3.0+ pub workspace
    final pubspecFile = File('$current/pubspec.yaml');
    if (await pubspecFile.exists()) {
      final content = await pubspecFile.readAsString();
      final yaml = loadYaml(content) as YamlMap?;

      if (yaml != null && yaml['workspace'] != null) {
        return _parsePubWorkspace(current, yaml);
      }

      // If we're at the startPath and it has a pubspec, check parent for workspace
      // before falling back to single package
      if (current != startPath) {
        // We've walked up and found a pubspec without workspace
        // This might be a package in a workspace, keep looking
      }
    }

    // Move up one directory
    final parent = Directory(current).parent.path;
    if (parent == current) {
      // Reached filesystem root
      break;
    }
    current = parent;
  }

  // No workspace found, check if startPath is a single package
  final pubspecFile = File('$startPath/pubspec.yaml');
  if (await pubspecFile.exists()) {
    return _parseSinglePackage(startPath, pubspecFile);
  }

  return null;
}

/// Detect workspace synchronously.
WorkspaceInfo? detectWorkspaceSync(String startPath) {
  var current = Directory(startPath).absolute.path;

  while (true) {
    final melosFile = File('$current/melos.yaml');
    if (melosFile.existsSync()) {
      return _parseMelosWorkspaceSync(current, melosFile);
    }

    final pubspecFile = File('$current/pubspec.yaml');
    if (pubspecFile.existsSync()) {
      final content = pubspecFile.readAsStringSync();
      final yaml = loadYaml(content) as YamlMap?;

      if (yaml != null && yaml['workspace'] != null) {
        return _parsePubWorkspaceSync(current, yaml);
      }
    }

    final parent = Directory(current).parent.path;
    if (parent == current) break;
    current = parent;
  }

  final pubspecFile = File('$startPath/pubspec.yaml');
  if (pubspecFile.existsSync()) {
    return _parseSinglePackageSync(startPath, pubspecFile);
  }

  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Melos parsing
// ─────────────────────────────────────────────────────────────────────────────

Future<WorkspaceInfo> _parseMelosWorkspace(
    String rootPath, File melosFile) async {
  final content = await melosFile.readAsString();
  final yaml = loadYaml(content) as YamlMap;

  final config = _parseMelosConfig(yaml);
  final packages = await _discoverMelosPackages(rootPath, config);

  return WorkspaceInfo(
    rootPath: rootPath,
    type: WorkspaceType.melos,
    packages: packages,
    melosConfig: config,
  );
}

WorkspaceInfo _parseMelosWorkspaceSync(String rootPath, File melosFile) {
  final content = melosFile.readAsStringSync();
  final yaml = loadYaml(content) as YamlMap;

  final config = _parseMelosConfig(yaml);
  final packages = _discoverMelosPackagesSync(rootPath, config);

  return WorkspaceInfo(
    rootPath: rootPath,
    type: WorkspaceType.melos,
    packages: packages,
    melosConfig: config,
  );
}

MelosConfig _parseMelosConfig(YamlMap yaml) {
  final name = yaml['name'] as String? ?? 'workspace';

  // Parse package globs
  final packagesNode = yaml['packages'];
  final packageGlobs = <String>[];
  if (packagesNode is YamlList) {
    for (final item in packagesNode) {
      packageGlobs.add(item.toString());
    }
  }

  // Parse ignore globs
  final ignoreNode = yaml['ignore'];
  final ignoreGlobs = <String>[];
  if (ignoreNode is YamlList) {
    for (final item in ignoreNode) {
      ignoreGlobs.add(item.toString());
    }
  }

  return MelosConfig(
    name: name,
    packageGlobs: packageGlobs,
    ignoreGlobs: ignoreGlobs,
  );
}

Future<List<WorkspacePackage>> _discoverMelosPackages(
    String rootPath, MelosConfig config) async {
  final packages = <WorkspacePackage>[];
  final seenPaths = <String>{};

  for (final pattern in config.packageGlobs) {
    // Melos uses glob patterns like "packages/**"
    final glob = Glob(pattern);

    await for (final entity in glob.list(root: rootPath)) {
      if (entity is! Directory) continue;

      final pubspecFile = File('${entity.path}/pubspec.yaml');
      if (!await pubspecFile.exists()) continue;

      // Skip ignored paths
      final relativePath =
          entity.path.substring(rootPath.length + 1); // +1 for /
      if (_isIgnored(relativePath, config.ignoreGlobs)) continue;

      // Skip duplicates
      if (seenPaths.contains(entity.path)) continue;
      seenPaths.add(entity.path);

      // Parse package name
      final name = await _getPackageName(pubspecFile);
      if (name == null) continue;

      packages.add(WorkspacePackage(
        name: name,
        relativePath: relativePath,
        absolutePath: entity.path,
      ));
    }
  }

  // Sort by path for consistent ordering
  packages.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return packages;
}

List<WorkspacePackage> _discoverMelosPackagesSync(
    String rootPath, MelosConfig config) {
  final packages = <WorkspacePackage>[];
  final seenPaths = <String>{};

  for (final pattern in config.packageGlobs) {
    final glob = Glob(pattern);

    for (final entity in glob.listSync(root: rootPath)) {
      if (entity is! Directory) continue;

      final pubspecFile = File('${entity.path}/pubspec.yaml');
      if (!pubspecFile.existsSync()) continue;

      final relativePath = entity.path.substring(rootPath.length + 1);
      if (_isIgnored(relativePath, config.ignoreGlobs)) continue;

      if (seenPaths.contains(entity.path)) continue;
      seenPaths.add(entity.path);

      final name = _getPackageNameSync(pubspecFile);
      if (name == null) continue;

      packages.add(WorkspacePackage(
        name: name,
        relativePath: relativePath,
        absolutePath: entity.path,
      ));
    }
  }

  packages.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return packages;
}

bool _isIgnored(String path, List<String> ignoreGlobs) {
  for (final pattern in ignoreGlobs) {
    final glob = Glob(pattern);
    if (glob.matches(path)) return true;
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Pub workspace parsing
// ─────────────────────────────────────────────────────────────────────────────

Future<WorkspaceInfo> _parsePubWorkspace(String rootPath, YamlMap yaml) async {
  final workspaceNode = yaml['workspace'];
  final packages = <WorkspacePackage>[];

  if (workspaceNode is YamlList) {
    for (final item in workspaceNode) {
      final pattern = item.toString();
      final discovered = await _discoverPubWorkspacePackages(rootPath, pattern);
      packages.addAll(discovered);
    }
  }

  // Also add the root package itself if it has a name
  final name = yaml['name'] as String?;
  if (name != null) {
    packages.insert(
        0,
        WorkspacePackage(
          name: name,
          relativePath: '.',
          absolutePath: rootPath,
        ));
  }

  return WorkspaceInfo(
    rootPath: rootPath,
    type: WorkspaceType.pubWorkspace,
    packages: packages,
  );
}

WorkspaceInfo _parsePubWorkspaceSync(String rootPath, YamlMap yaml) {
  final workspaceNode = yaml['workspace'];
  final packages = <WorkspacePackage>[];

  if (workspaceNode is YamlList) {
    for (final item in workspaceNode) {
      final pattern = item.toString();
      final discovered = _discoverPubWorkspacePackagesSync(rootPath, pattern);
      packages.addAll(discovered);
    }
  }

  final name = yaml['name'] as String?;
  if (name != null) {
    packages.insert(
        0,
        WorkspacePackage(
          name: name,
          relativePath: '.',
          absolutePath: rootPath,
        ));
  }

  return WorkspaceInfo(
    rootPath: rootPath,
    type: WorkspaceType.pubWorkspace,
    packages: packages,
  );
}

Future<List<WorkspacePackage>> _discoverPubWorkspacePackages(
    String rootPath, String pattern) async {
  final packages = <WorkspacePackage>[];

  // Simple path (not a glob)
  if (!pattern.contains('*')) {
    final pkgPath = '$rootPath/$pattern';
    final pubspecFile = File('$pkgPath/pubspec.yaml');
    if (await pubspecFile.exists()) {
      final name = await _getPackageName(pubspecFile);
      if (name != null) {
        packages.add(WorkspacePackage(
          name: name,
          relativePath: pattern,
          absolutePath: pkgPath,
        ));
      }
    }
    return packages;
  }

  // Glob pattern
  final glob = Glob(pattern);
  await for (final entity in glob.list(root: rootPath)) {
    if (entity is! Directory) continue;

    final pubspecFile = File('${entity.path}/pubspec.yaml');
    if (!await pubspecFile.exists()) continue;

    final name = await _getPackageName(pubspecFile);
    if (name == null) continue;

    final relativePath = entity.path.substring(rootPath.length + 1);
    packages.add(WorkspacePackage(
      name: name,
      relativePath: relativePath,
      absolutePath: entity.path,
    ));
  }

  return packages;
}

List<WorkspacePackage> _discoverPubWorkspacePackagesSync(
    String rootPath, String pattern) {
  final packages = <WorkspacePackage>[];

  if (!pattern.contains('*')) {
    final pkgPath = '$rootPath/$pattern';
    final pubspecFile = File('$pkgPath/pubspec.yaml');
    if (pubspecFile.existsSync()) {
      final name = _getPackageNameSync(pubspecFile);
      if (name != null) {
        packages.add(WorkspacePackage(
          name: name,
          relativePath: pattern,
          absolutePath: pkgPath,
        ));
      }
    }
    return packages;
  }

  final glob = Glob(pattern);
  for (final entity in glob.listSync(root: rootPath)) {
    if (entity is! Directory) continue;

    final pubspecFile = File('${entity.path}/pubspec.yaml');
    if (!pubspecFile.existsSync()) continue;

    final name = _getPackageNameSync(pubspecFile);
    if (name == null) continue;

    final relativePath = entity.path.substring(rootPath.length + 1);
    packages.add(WorkspacePackage(
      name: name,
      relativePath: relativePath,
      absolutePath: entity.path,
    ));
  }

  return packages;
}

// ─────────────────────────────────────────────────────────────────────────────
// Single package parsing
// ─────────────────────────────────────────────────────────────────────────────

Future<WorkspaceInfo> _parseSinglePackage(
    String rootPath, File pubspecFile) async {
  final name = await _getPackageName(pubspecFile) ?? 'unknown';

  return WorkspaceInfo(
    rootPath: rootPath,
    type: WorkspaceType.single,
    packages: [
      WorkspacePackage(
        name: name,
        relativePath: '.',
        absolutePath: rootPath,
      ),
    ],
  );
}

WorkspaceInfo _parseSinglePackageSync(String rootPath, File pubspecFile) {
  final name = _getPackageNameSync(pubspecFile) ?? 'unknown';

  return WorkspaceInfo(
    rootPath: rootPath,
    type: WorkspaceType.single,
    packages: [
      WorkspacePackage(
        name: name,
        relativePath: '.',
        absolutePath: rootPath,
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

Future<String?> _getPackageName(File pubspecFile) async {
  try {
    final content = await pubspecFile.readAsString();
    final yaml = loadYaml(content) as YamlMap?;
    return yaml?['name'] as String?;
  } catch (_) {
    return null;
  }
}

String? _getPackageNameSync(File pubspecFile) {
  try {
    final content = pubspecFile.readAsStringSync();
    final yaml = loadYaml(content) as YamlMap?;
    return yaml?['name'] as String?;
  } catch (_) {
    return null;
  }
}

/// Serialize workspace info to JSON.
Map<String, dynamic> workspaceToJson(WorkspaceInfo workspace) {
  return {
    'rootPath': workspace.rootPath,
    'type': workspace.type.name,
    'packages': workspace.packages
        .map((p) => {
              'name': p.name,
              'relativePath': p.relativePath,
              'absolutePath': p.absolutePath,
            })
        .toList(),
    if (workspace.melosConfig != null)
      'melos': {
        'name': workspace.melosConfig!.name,
        'packageGlobs': workspace.melosConfig!.packageGlobs,
        'ignoreGlobs': workspace.melosConfig!.ignoreGlobs,
      },
  };
}

/// Serialize workspace info to JSON string.
String workspaceToJsonString(WorkspaceInfo workspace) {
  return const JsonEncoder.withIndent('  ').convert(workspaceToJson(workspace));
}

