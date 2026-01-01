#!/usr/bin/env dart

import 'dart:io';

import 'package:scip_server/scip_server.dart';

/// Standalone SCIP Protocol Server.
///
/// Usage:
///   dart run scip_server:server [options]
///
/// Options:
///   --tcp           Run as TCP server (default: stdio)
///   --port <port>   TCP port to listen on (default: 3333)
///   --host <host>   Host to bind to (default: localhost)
///
/// The server requires a language binding to be registered before use.
/// In standalone mode, language bindings must be loaded dynamically
/// or pre-registered via configuration.
void main(List<String> args) async {
  final isTcp = args.contains('--tcp');
  final portIndex = args.indexOf('--port');
  final hostIndex = args.indexOf('--host');

  final port = portIndex != -1 && portIndex + 1 < args.length
      ? int.tryParse(args[portIndex + 1]) ?? 3333
      : 3333;
  final host = hostIndex != -1 && hostIndex + 1 < args.length
      ? args[hostIndex + 1]
      : 'localhost';

  final server = ScipServer();

  // Note: In standalone mode, you need to register bindings.
  // For Dart: server.registerBinding(DartBinding());
  // The dart_context package handles this automatically.

  if (isTcp) {
    final socket = await server.serveTcp(port: port, host: host);
    stderr.writeln('SCIP Server listening on ${socket.address.host}:${socket.port}');
    stderr.writeln('Available languages: ${server.availableLanguages.join(", ")}');
    stderr.writeln('Press Ctrl+C to stop.');

    // Wait for shutdown signal
    ProcessSignal.sigint.watch().listen((_) async {
      stderr.writeln('Shutting down...');
      await socket.close();
      exit(0);
    });
  } else {
    stderr.writeln('SCIP Server running over stdio');
    stderr.writeln('Available languages: ${server.availableLanguages.join(", ")}');
    await server.serveStdio();
  }
}

