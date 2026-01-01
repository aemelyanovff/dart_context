/// Dart language binding for scip_server.
///
/// This library provides:
/// - [DartBinding] - Implementation of [LanguageBinding] for Dart
/// - [IncrementalScipIndexer] - Incremental SCIP indexer for Dart projects
/// - [PackageRegistry] - Registry for managing local and external packages
/// - [PackageDiscovery] - Discover Dart packages in a directory
library dart_binding;

// Main binding implementation
export 'src/dart_binding.dart';

// Indexing
export 'src/incremental_indexer.dart';
export 'src/index_cache.dart';
export 'src/external_index_builder.dart';

// Package management
export 'src/package_registry.dart';
export 'src/package_discovery.dart';

// Cache utilities
export 'src/cache/cache_paths.dart';

// Analyzer adapters
export 'src/adapters/analyzer_adapter.dart';
export 'src/adapters/hologram_adapter.dart';

// Utilities
export 'src/utils/package_config.dart';
export 'src/utils/pubspec_utils.dart';
export 'src/version.dart';

