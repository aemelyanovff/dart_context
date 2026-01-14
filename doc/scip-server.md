# SCIP Protocol Server

code_context includes a JSON-RPC 2.0 server for programmatic access to code intelligence.

## Quick Start

```bash
# Run over stdio (for process communication)
dart run code_context:scip_server

# Run as TCP server
dart run code_context:scip_server --tcp --port 3333
```

## Protocol

The server communicates using JSON-RPC 2.0 over newline-delimited JSON.

### Methods

| Method | Description |
|--------|-------------|
| `initialize` | Initialize a project with language binding |
| `query` | Execute a DSL query |
| `status` | Get index status/statistics |
| `shutdown` | Graceful shutdown |
| `file/didChange` | Notify of file modification |
| `file/didDelete` | Notify of file deletion |

## Method Details

### initialize

Initialize a project for indexing.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "rootPath": "/path/to/project",
    "languageId": "dart",
    "useCache": true
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "success": true,
    "projectName": "my_project",
    "fileCount": 42,
    "symbolCount": 1234
  }
}
```

### query

Execute a DSL query against the indexed project.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "query",
  "params": {
    "query": "def AuthService",
    "format": "text"
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "success": true,
    "result": "AuthService [class] (lib/auth/service.dart:10)"
  }
}
```

Set `format: "json"` for structured output:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "query",
  "params": {
    "query": "members AuthService",
    "format": "json"
  }
}
```

### status

Get current index status.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "status"
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "initialized": true,
    "languageId": "dart",
    "projectName": "my_project",
    "fileCount": 42,
    "symbolCount": 1234,
    "referenceCount": 5678
  }
}
```

### shutdown

Gracefully shutdown the server.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "shutdown"
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "success": true
  }
}
```

### file/didChange

Notify the server of a file modification for incremental update. This is a notification (no response).

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "file/didChange",
  "params": {
    "path": "lib/auth/service.dart"
  }
}
```

### file/didDelete

Notify the server of a file deletion.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "file/didDelete",
  "params": {
    "path": "lib/old_file.dart"
  }
}
```

## Example Session

```bash
# Start the server
$ dart run code_context:scip_server

# In another terminal, or pipe to stdin:
$ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootPath":"/my/project","languageId":"dart"}}' | dart run code_context:scip_server
```

Full example:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootPath":"'$(pwd)'","languageId":"dart"}}
{"jsonrpc":"2.0","id":2,"method":"query","params":{"query":"find *Service kind:class"}}
{"jsonrpc":"2.0","id":3,"method":"status"}
{"jsonrpc":"2.0","id":4,"method":"shutdown"}' | dart run code_context:scip_server 2>/dev/null
```

## TCP Mode

For persistent connections, use TCP mode:

```bash
# Start server
dart run code_context:scip_server --tcp --port 3333

# Connect with netcat
nc localhost 3333
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootPath":"/my/project","languageId":"dart"}}
```

## Error Handling

Errors are returned as JSON-RPC error responses:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found: unknown_method"
  }
}
```

Standard error codes:
- `-32700`: Parse error
- `-32600`: Invalid request
- `-32601`: Method not found
- `-32602`: Invalid params
- `-32603`: Internal error

## Integration

### From Dart

```dart
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final process = await Process.start('dart', ['run', 'code_context:scip_server']);
  
  // Send request
  process.stdin.writeln(jsonEncode({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'initialize',
    'params': {
      'rootPath': Directory.current.path,
      'languageId': 'dart',
    },
  }));
  
  // Read response
  await for (final line in process.stdout.transform(utf8.decoder).transform(LineSplitter())) {
    final response = jsonDecode(line);
    print('Response: $response');
    break;
  }
  
  process.kill();
}
```

### From Python

```python
import subprocess
import json

process = subprocess.Popen(
    ['dart', 'run', 'code_context:scip_server'],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True
)

# Initialize
request = json.dumps({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'initialize',
    'params': {'rootPath': '/path/to/project', 'languageId': 'dart'}
})
process.stdin.write(request + '\n')
process.stdin.flush()

response = json.loads(process.stdout.readline())
print(f"Initialized: {response}")

# Query
request = json.dumps({
    'jsonrpc': '2.0',
    'id': 2,
    'method': 'query',
    'params': {'query': 'find *Service kind:class'}
})
process.stdin.write(request + '\n')
process.stdin.flush()

response = json.loads(process.stdout.readline())
print(f"Query result: {response}")
```

