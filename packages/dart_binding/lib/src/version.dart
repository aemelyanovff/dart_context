/// Version of the dart_context package.
///
/// This is used for cache invalidation - when the version changes,
/// cached indexes may need to be regenerated if the format changed.
const dartContextVersion = '0.2.0';

/// Version of the manifest format.
///
/// Bump this when the manifest.json structure changes in a way that
/// would make old manifests incompatible.
const manifestVersion = 1;

/// Check if a cached version is compatible with the current version.
///
/// Currently uses simple equality check, but could be extended to
/// support semantic versioning compatibility rules.
bool isVersionCompatible(String? cachedVersion) {
  if (cachedVersion == null) return false;

  // For now, require exact match on major.minor
  // This means patch versions are compatible (0.2.0 compatible with 0.2.1)
  final currentParts = dartContextVersion.split('.');
  final cachedParts = cachedVersion.split('.');

  if (currentParts.length < 2 || cachedParts.length < 2) {
    return cachedVersion == dartContextVersion;
  }

  // Major and minor must match
  return currentParts[0] == cachedParts[0] && currentParts[1] == cachedParts[1];
}
