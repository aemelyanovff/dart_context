/// SCIP Protocol definitions.
///
/// This file defines the JSON-RPC protocol for communicating with a SCIP server.
/// The protocol is designed to be simple and inspired by LSP.
library;

// ─────────────────────────────────────────────────────────────────────────────
// Protocol Methods
// ─────────────────────────────────────────────────────────────────────────────

/// Protocol method names.
abstract class ScipMethod {
  /// Initialize a project with a language binding.
  static const initialize = 'initialize';

  /// Shutdown the server.
  static const shutdown = 'shutdown';

  /// Execute a DSL query.
  static const query = 'query';

  /// Get index status/statistics.
  static const status = 'status';

  /// Notify of file change (request incremental update).
  static const didChangeFile = 'file/didChange';

  /// Notify of file deletion.
  static const didDeleteFile = 'file/didDelete';

  /// List available packages.
  static const listPackages = 'packages/list';
}

// ─────────────────────────────────────────────────────────────────────────────
// Request/Response Types
// ─────────────────────────────────────────────────────────────────────────────

/// Initialize request parameters.
class InitializeParams {
  const InitializeParams({
    required this.rootPath,
    required this.languageId,
    this.useCache = true,
  });

  factory InitializeParams.fromJson(Map<String, dynamic> json) {
    return InitializeParams(
      rootPath: json['rootPath'] as String,
      languageId: json['languageId'] as String,
      useCache: json['useCache'] as bool? ?? true,
    );
  }

  final String rootPath;
  final String languageId;
  final bool useCache;

  Map<String, dynamic> toJson() => {
        'rootPath': rootPath,
        'languageId': languageId,
        'useCache': useCache,
      };
}

/// Initialize response.
class InitializeResult {
  const InitializeResult({
    required this.success,
    required this.projectName,
    required this.fileCount,
    required this.symbolCount,
    this.message,
  });

  final bool success;
  final String projectName;
  final int fileCount;
  final int symbolCount;
  final String? message;

  Map<String, dynamic> toJson() => {
        'success': success,
        'projectName': projectName,
        'fileCount': fileCount,
        'symbolCount': symbolCount,
        if (message != null) 'message': message,
      };
}

/// Query request parameters.
class QueryParams {
  const QueryParams({
    required this.query,
    this.format = 'text',
  });

  factory QueryParams.fromJson(Map<String, dynamic> json) {
    return QueryParams(
      query: json['query'] as String,
      format: json['format'] as String? ?? 'text',
    );
  }

  final String query;

  /// Output format: 'text' (human-readable) or 'json' (structured).
  final String format;

  Map<String, dynamic> toJson() => {
        'query': query,
        'format': format,
      };
}

/// Query response.
class QueryResponse {
  const QueryResponse({
    required this.success,
    this.result,
    this.error,
  });

  final bool success;
  final dynamic result;
  final String? error;

  Map<String, dynamic> toJson() => {
        'success': success,
        if (result != null) 'result': result,
        if (error != null) 'error': error,
      };
}

/// Status response.
class StatusResult {
  const StatusResult({
    required this.initialized,
    this.languageId,
    this.projectName,
    this.fileCount,
    this.symbolCount,
    this.referenceCount,
    this.packages,
  });

  final bool initialized;
  final String? languageId;
  final String? projectName;
  final int? fileCount;
  final int? symbolCount;
  final int? referenceCount;
  final List<String>? packages;

  Map<String, dynamic> toJson() => {
        'initialized': initialized,
        if (languageId != null) 'languageId': languageId,
        if (projectName != null) 'projectName': projectName,
        if (fileCount != null) 'fileCount': fileCount,
        if (symbolCount != null) 'symbolCount': symbolCount,
        if (referenceCount != null) 'referenceCount': referenceCount,
        if (packages != null) 'packages': packages,
      };
}

/// File change notification parameters.
class FileChangeParams {
  const FileChangeParams({
    required this.path,
    this.type = 'modify',
  });

  factory FileChangeParams.fromJson(Map<String, dynamic> json) {
    return FileChangeParams(
      path: json['path'] as String,
      type: json['type'] as String? ?? 'modify',
    );
  }

  final String path;

  /// Change type: 'create', 'modify', 'delete'.
  final String type;

  Map<String, dynamic> toJson() => {
        'path': path,
        'type': type,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON-RPC Types
// ─────────────────────────────────────────────────────────────────────────────

/// JSON-RPC 2.0 request.
class JsonRpcRequest {
  const JsonRpcRequest({
    required this.method,
    this.params,
    this.id,
  });

  factory JsonRpcRequest.fromJson(Map<String, dynamic> json) {
    return JsonRpcRequest(
      method: json['method'] as String,
      params: json['params'],
      id: json['id'],
    );
  }

  final String method;
  final dynamic params;
  final dynamic id;

  /// Whether this is a notification (no response expected).
  bool get isNotification => id == null;

  Map<String, dynamic> toJson() => {
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
        if (id != null) 'id': id,
      };
}

/// JSON-RPC 2.0 response.
class JsonRpcResponse {
  const JsonRpcResponse({
    required this.id,
    this.result,
    this.error,
  });

  final dynamic id;
  final dynamic result;
  final JsonRpcError? error;

  Map<String, dynamic> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        if (error != null) 'error': error!.toJson() else 'result': result,
      };
}

/// JSON-RPC 2.0 error.
class JsonRpcError {
  const JsonRpcError({
    required this.code,
    required this.message,
    this.data,
  });

  final int code;
  final String message;
  final dynamic data;

  /// Standard error codes.
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;

  /// Custom error codes (server-defined, -32000 to -32099).
  static const notInitialized = -32002;
  static const queryFailed = -32001;

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };
}

