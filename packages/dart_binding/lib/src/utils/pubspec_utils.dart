/// Utilities for parsing pubspec files.
library;

/// Information about a package from pubspec.lock.
class PackageInfo {
  PackageInfo(this.name, this.version);

  final String name;
  final String version;

  @override
  String toString() => '$name-$version';
}

/// Parse pubspec.lock content to extract package versions.
///
/// Returns a list of [PackageInfo] with name and version for each package.
List<PackageInfo> parsePubspecLock(String content) {
  final packages = <PackageInfo>[];
  final lines = content.split('\n');

  String? currentPackage;

  for (final line in lines) {
    if (line.startsWith('  ') &&
        line.endsWith(':') &&
        !line.startsWith('    ')) {
      // Package name (indented with 2 spaces, ends with colon)
      currentPackage = line.trim().replaceAll(':', '');
    } else if (line.contains('version:') && currentPackage != null) {
      // Package version
      final version = line.split(':').last.trim().replaceAll('"', '');
      packages.add(PackageInfo(currentPackage, version));
      currentPackage = null;
    }
  }

  return packages;
}

