import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../language_binding.dart';
import '../query/query_executor.dart';
import 'protocol.dart';

/// SCIP Protocol Server.
///
/// A JSON-RPC 2.0 server that provides semantic code intelligence services.
/// Can communicate over stdio or TCP.
///
/// ## Usage
///
/// ```dart
/// // Create server with a language binding
/// final server = ScipServer();
/// server.registerBinding(DartBinding());
///
/// // Run over stdio
/// await server.serveStdio();
///
/// // Or run on a TCP port
/// await server.serveTcp(port: 3333);
/// ```
///
/// ## Protocol
///
/// The server implements a simple JSON-RPC 2.0 protocol:
///
/// - `initialize` - Initialize project with language binding
/// - `query` - Execute a DSL query
/// - `status` - Get index status
/// - `file/didChange` - Notify of file changes
/// - `shutdown` - Graceful shutdown
class ScipServer {
  ScipServer();

  /// Registered language bindings by languageId.
  final Map<String, LanguageBinding> _bindings = {};

  /// Current active binding (set after initialize).
  LanguageBinding? _activeBinding;

  /// Current package indexer.
  PackageIndexer? _indexer;

  /// Current query executor.
  QueryExecutor? _executor;

  /// Project root path.
  String? _rootPath;

  /// Whether the server is initialized.
  bool get isInitialized => _indexer != null;

  /// Register a language binding.
  void registerBinding(LanguageBinding binding) {
    _bindings[binding.languageId] = binding;
  }

  /// Get available language IDs.
  List<String> get availableLanguages => _bindings.keys.toList();

  /// Handle a JSON-RPC request.
  Future<JsonRpcResponse?> handleRequest(JsonRpcRequest request) async {
    try {
      final result = await _dispatch(request.method, request.params);

      // Notifications don't get responses
      if (request.isNotification) return null;

      return JsonRpcResponse(id: request.id, result: result);
    } catch (e) {
      if (request.isNotification) return null;

      return JsonRpcResponse(
        id: request.id,
        error: JsonRpcError(
          code: JsonRpcError.internalError,
          message: e.toString(),
        ),
      );
    }
  }

  /// Dispatch a method call.
  Future<dynamic> _dispatch(String method, dynamic params) async {
    switch (method) {
      case ScipMethod.initialize:
        return _handleInitialize(params as Map<String, dynamic>);

      case ScipMethod.shutdown:
        return _handleShutdown();

      case ScipMethod.query:
        return _handleQuery(params as Map<String, dynamic>);

      case ScipMethod.status:
        return _handleStatus();

      case ScipMethod.didChangeFile:
        return _handleFileChange(params as Map<String, dynamic>);

      case ScipMethod.didDeleteFile:
        return _handleFileDelete(params as Map<String, dynamic>);

      case ScipMethod.listPackages:
        return _handleListPackages();

      default:
        throw JsonRpcError(
          code: JsonRpcError.methodNotFound,
          message: 'Method not found: $method',
        );
    }
  }

  /// Handle initialize request.
  Future<Map<String, dynamic>> _handleInitialize(
    Map<String, dynamic> params,
  ) async {
    final initParams = InitializeParams.fromJson(params);

    final binding = _bindings[initParams.languageId];
    if (binding == null) {
      return InitializeResult(
        success: false,
        projectName: '',
        fileCount: 0,
        symbolCount: 0,
        message:
            'Unknown language: ${initParams.languageId}. Available: ${_bindings.keys.join(", ")}',
      ).toJson();
    }

    try {
      _activeBinding = binding;
      _rootPath = initParams.rootPath;

      // Create indexer
      _indexer = await binding.createIndexer(
        initParams.rootPath,
        useCache: initParams.useCache,
      );

      // Create query executor
      _executor = QueryExecutor(_indexer!.index);

      final stats = _indexer!.index.stats;

      return InitializeResult(
        success: true,
        projectName: _rootPath!.split('/').last,
        fileCount: stats['files'] ?? 0,
        symbolCount: stats['symbols'] ?? 0,
      ).toJson();
    } catch (e) {
      return InitializeResult(
        success: false,
        projectName: '',
        fileCount: 0,
        symbolCount: 0,
        message: 'Failed to initialize: $e',
      ).toJson();
    }
  }

  /// Handle shutdown request.
  Future<Map<String, dynamic>> _handleShutdown() async {
    await _indexer?.dispose();
    _indexer = null;
    _executor = null;
    _activeBinding = null;
    _rootPath = null;

    return {'success': true};
  }

  /// Handle query request.
  Future<Map<String, dynamic>> _handleQuery(
    Map<String, dynamic> params,
  ) async {
    if (!isInitialized) {
      return QueryResponse(
        success: false,
        error: 'Server not initialized. Call initialize first.',
      ).toJson();
    }

    final queryParams = QueryParams.fromJson(params);

    try {
      final result = await _executor!.execute(queryParams.query);

      if (queryParams.format == 'json') {
        return QueryResponse(success: true, result: result.toJson()).toJson();
      } else {
        return QueryResponse(success: true, result: result.toText()).toJson();
      }
    } on FormatException catch (e) {
      return QueryResponse(success: false, error: 'Invalid query: ${e.message}')
          .toJson();
    } catch (e) {
      return QueryResponse(success: false, error: 'Query failed: $e').toJson();
    }
  }

  /// Handle status request.
  Future<Map<String, dynamic>> _handleStatus() async {
    if (!isInitialized) {
      return StatusResult(initialized: false).toJson();
    }

    final stats = _indexer!.index.stats;

    return StatusResult(
      initialized: true,
      languageId: _activeBinding?.languageId,
      projectName: _rootPath?.split('/').last,
      fileCount: stats['files'],
      symbolCount: stats['symbols'],
      referenceCount: stats['references'],
    ).toJson();
  }

  /// Handle file change notification.
  Future<Map<String, dynamic>> _handleFileChange(
    Map<String, dynamic> params,
  ) async {
    if (!isInitialized) {
      return {'success': false, 'error': 'Not initialized'};
    }

    final fileParams = FileChangeParams.fromJson(params);

    try {
      await _indexer!.updateFile(fileParams.path);
      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Handle file delete notification.
  Future<Map<String, dynamic>> _handleFileDelete(
    Map<String, dynamic> params,
  ) async {
    if (!isInitialized) {
      return {'success': false, 'error': 'Not initialized'};
    }

    final fileParams = FileChangeParams.fromJson(params);

    try {
      await _indexer!.removeFile(fileParams.path);
      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Handle list packages request.
  Future<Map<String, dynamic>> _handleListPackages() async {
    return {
      'languages': _bindings.keys.toList(),
      'initialized': isInitialized,
      if (isInitialized) 'files': _indexer!.index.files.length,
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Transport: stdio
  // ─────────────────────────────────────────────────────────────────────────

  /// Serve over stdio.
  ///
  /// Reads JSON-RPC requests from stdin, writes responses to stdout.
  /// Each message is a JSON object on a single line.
  Future<void> serveStdio() async {
    await for (final line in stdin.transform(utf8.decoder).transform(
          const LineSplitter(),
        )) {
      if (line.trim().isEmpty) continue;

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final request = JsonRpcRequest.fromJson(json);
        final response = await handleRequest(request);

        if (response != null) {
          stdout.writeln(jsonEncode(response.toJson()));
        }

        // Exit after shutdown
        if (request.method == ScipMethod.shutdown) {
          break;
        }
      } catch (e) {
        final error = JsonRpcResponse(
          id: null,
          error: JsonRpcError(
            code: JsonRpcError.parseError,
            message: 'Failed to parse request: $e',
          ),
        );
        stdout.writeln(jsonEncode(error.toJson()));
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Transport: TCP
  // ─────────────────────────────────────────────────────────────────────────

  /// Serve on a TCP port.
  ///
  /// Each client connection is handled independently.
  Future<ServerSocket> serveTcp({
    int port = 3333,
    String host = 'localhost',
  }) async {
    final server = await ServerSocket.bind(host, port);

    server.listen((socket) async {
      final lines = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final data in lines) {
        if (data.trim().isEmpty) continue;

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final request = JsonRpcRequest.fromJson(json);
          final response = await handleRequest(request);

          if (response != null) {
            socket.writeln(jsonEncode(response.toJson()));
          }

          if (request.method == ScipMethod.shutdown) {
            await socket.close();
          }
        } catch (e) {
          final error = JsonRpcResponse(
            id: null,
            error: JsonRpcError(
              code: JsonRpcError.parseError,
              message: 'Failed to parse request: $e',
            ),
          );
          socket.writeln(jsonEncode(error.toJson()));
        }
      }
    });

    return server;
  }
}

