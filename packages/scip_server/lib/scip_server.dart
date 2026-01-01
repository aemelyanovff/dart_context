/// Language-agnostic SCIP query engine and protocol server.
///
/// This library provides:
/// - [ScipIndex] - In-memory representation of a SCIP index
/// - [QueryExecutor] - Execute DSL queries against the index
/// - [LanguageBinding] - Interface for language-specific implementations
/// - [IndexProvider] - Interface for cross-package queries
/// - [ScipServer] - JSON-RPC protocol server
library scip_server;

// Core index types
export 'src/index/scip_index.dart';
export 'src/index/index_provider.dart';

// Query engine
export 'src/query/query_parser.dart';
export 'src/query/query_executor.dart';
export 'src/query/query_result.dart';

// Language binding interface
export 'src/language_binding.dart';

// Protocol server
export 'src/protocol/protocol.dart';
export 'src/protocol/json_rpc_server.dart';

