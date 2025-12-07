import 'dart:io';

import 'package:dart_context/dart_context.dart';
import 'package:dart_context/src/query/query_result.dart';
import 'package:test/test.dart';

void main() {
  group('Signature query', () {
    late Directory tempDir;
    late DartContext context;

    setUp(() async {
      // Create temp directory with test files
      tempDir = await Directory.systemTemp.createTemp('dart_context_sig_');

      // Create pubspec.yaml
      await File('${tempDir.path}/pubspec.yaml').writeAsString('''
name: test_project
environment:
  sdk: ^3.0.0
''');

      // Run dart pub get
      final result = await Process.run(
        'dart',
        ['pub', 'get'],
        workingDirectory: tempDir.path,
      );
      if (result.exitCode != 0) {
        throw StateError('dart pub get failed: ${result.stderr}');
      }

      // Create lib directory
      final libDir = Directory('${tempDir.path}/lib');
      await libDir.create();

      // Create test file with various declarations
      await File('${libDir.path}/service.dart').writeAsString('''
/// A service for authentication.
class AuthService {
  final String _apiKey;
  
  AuthService(this._apiKey);
  
  /// Login with email and password.
  Future<User> login(String email, String password) async {
    // Implementation details here
    return User(email);
  }
  
  void logout() {
    // Clear session
  }
  
  String get apiKey => _apiKey;
}

class User {
  final String email;
  User(this.email);
}

/// Top-level function.
void initialize() {
  print('Initializing...');
}
''');

      // Open the project
      context = await DartContext.open(tempDir.path, watch: false);
    });

    tearDown(() async {
      await context.dispose();
      await tempDir.delete(recursive: true);
    });

    test('sig returns class signature with method stubs', () async {
      final result = await context.query('sig AuthService');

      expect(result, isA<SignatureResult>());
      final sigResult = result as SignatureResult;

      expect(sigResult.symbol.name, 'AuthService');
      expect(sigResult.signature, contains('class AuthService'));
      // Method bodies should be replaced with {}
      expect(sigResult.signature, contains('{}'));
      // Should not contain implementation details
      expect(sigResult.signature, isNot(contains('Implementation details')));
    });

    test('sig returns method signature', () async {
      final result = await context.query('sig login');

      expect(result, isA<SignatureResult>());
      final sigResult = result as SignatureResult;

      expect(sigResult.symbol.name, 'login');
      expect(sigResult.signature, contains('login'));
      // Should contain return type and parameters
      expect(sigResult.signature, contains('Future'));
    });

    test('sig returns function signature', () async {
      final result = await context.query('sig initialize');

      expect(result, isA<SignatureResult>());
      final sigResult = result as SignatureResult;

      expect(sigResult.symbol.name, 'initialize');
      expect(sigResult.signature, contains('void'));
      expect(sigResult.signature, contains('initialize'));
    });

    test('sig returns NotFoundResult for unknown symbol', () async {
      final result = await context.query('sig NonExistent');

      expect(result, isA<NotFoundResult>());
    });

    test('sig toText formats correctly', () async {
      final result = await context.query('sig AuthService');

      expect(result, isA<SignatureResult>());
      final text = result.toText();

      expect(text, contains('## AuthService'));
      expect(text, contains('(class)'));
      expect(text, contains('File:'));
      expect(text, contains('```dart'));
    });

    test('sig toJson has correct structure', () async {
      final result = await context.query('sig AuthService');

      expect(result, isA<SignatureResult>());
      final json = result.toJson();

      expect(json['type'], 'signature');
      expect(json['name'], 'AuthService');
      expect(json['kind'], 'class');
      expect(json['signature'], isA<String>());
      expect(json['file'], isA<String>());
      expect(json['line'], isA<int>());
    });

    test('sig class signature has proper newlines and indentation', () async {
      final result = await context.query('sig AuthService');

      expect(result, isA<SignatureResult>());
      final sigResult = result as SignatureResult;
      final sig = sigResult.signature;

      // Should have newlines between members
      expect(sig, contains('\n'));

      // Each member should be on its own line (indented)
      final lines = sig.split('\n');
      expect(lines.length, greaterThan(3)); // class + members + closing brace

      // Should have class declaration on first line
      expect(lines.first, contains('class AuthService'));

      // Members should be indented
      final memberLines = lines.where((l) => l.trim().isNotEmpty && !l.startsWith('class') && l != '}');
      for (final line in memberLines) {
        expect(line, startsWith('  ')); // 2-space indent
      }
    });
  });
}

