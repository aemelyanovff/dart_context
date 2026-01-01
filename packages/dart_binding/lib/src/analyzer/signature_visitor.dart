// Copyright (c) 2025, dart_context contributors.
// Based on dart_mcp_server's SignatureVisitor.

// ignore_for_file: implementation_imports

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/src/dart/ast/ast.dart' as impl;
import 'package:analyzer/src/dart/ast/to_source_visitor.dart';

/// AST visitor that generates signatures with method bodies replaced by `{}`.
///
/// This produces clean API signatures suitable for documentation and
/// quick code exploration.
///
/// Example output for a class:
/// ```dart
/// class AuthService extends BaseService {
///   AuthService(this._client);
///   Future<User> login(String email, String password) {}
///   void logout() {}
/// }
/// ```
class SignatureVisitor extends ToSourceVisitor {
  SignatureVisitor(super.sink, {this.indent = '  '});

  /// Indentation string for members (default: 2 spaces).
  final String indent;

  @override
  void visitClassDeclaration(covariant impl.ClassDeclarationImpl node) {
    _visitNodeList(node.metadata, separator: ' ', suffix: ' ');
    _visitToken(node.abstractKeyword, suffix: ' ');
    _visitToken(node.sealedKeyword, suffix: ' ');
    _visitToken(node.baseKeyword, suffix: ' ');
    _visitToken(node.interfaceKeyword, suffix: ' ');
    _visitToken(node.finalKeyword, suffix: ' ');
    _visitToken(node.mixinKeyword, suffix: ' ');
    sink.write('class ');
    _visitToken(node.name);
    _visitNode(node.typeParameters);
    _visitNode(node.extendsClause, prefix: ' ');
    _visitNode(node.withClause, prefix: ' ');
    _visitNode(node.implementsClause, prefix: ' ');
    sink.write(' {\n');
    _visitMemberList(node.members);
    sink.write('}');
  }

  @override
  void visitMixinDeclaration(covariant impl.MixinDeclarationImpl node) {
    _visitNodeList(node.metadata, separator: ' ', suffix: ' ');
    _visitToken(node.baseKeyword, suffix: ' ');
    sink.write('mixin ');
    _visitToken(node.name);
    _visitNode(node.typeParameters);
    _visitNode(node.onClause, prefix: ' ');
    _visitNode(node.implementsClause, prefix: ' ');
    sink.write(' {\n');
    _visitMemberList(node.members);
    sink.write('}');
  }

  @override
  void visitEnumDeclaration(covariant impl.EnumDeclarationImpl node) {
    _visitNodeList(node.metadata, separator: ' ', suffix: ' ');
    sink.write('enum ');
    _visitToken(node.name);
    _visitNode(node.typeParameters);
    _visitNode(node.withClause, prefix: ' ');
    _visitNode(node.implementsClause, prefix: ' ');
    sink.write(' {\n');
    for (var i = 0; i < node.constants.length; i++) {
      sink.write(indent);
      node.constants[i].accept(this);
      sink.write(i < node.constants.length - 1 ? ',\n' : '');
    }
    if (node.members.isNotEmpty) {
      sink.write(';\n');
      _visitMemberList(node.members);
    } else {
      sink.write('\n');
    }
    sink.write('}');
  }

  @override
  void visitExtensionDeclaration(covariant impl.ExtensionDeclarationImpl node) {
    _visitNodeList(node.metadata, separator: ' ', suffix: ' ');
    sink.write('extension ');
    _visitToken(node.name);
    _visitNode(node.typeParameters);
    sink.write(' on ');
    node.extendedType.accept(this);
    sink.write(' {\n');
    _visitMemberList(node.members);
    sink.write('}');
  }

  /// Visit a list of class members with proper indentation and newlines.
  void _visitMemberList(List<ClassMember> members) {
    for (final member in members) {
      sink.write(indent);
      member.accept(this);
      sink.write('\n');
    }
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _visitNodeList(node.metadata, separator: ' ', suffix: ' ');
    _visitToken(node.externalKeyword, suffix: ' ');
    _visitToken(node.constKeyword, suffix: ' ');
    _visitToken(node.factoryKeyword, suffix: ' ');
    _visitNode(node.returnType);
    _visitToken(node.name, prefix: '.');
    _visitNode(node.parameters);
    _visitNodeList(node.initializers, prefix: ' : ', separator: ', ');
    _visitNode(node.redirectedConstructor, prefix: ' = ');
    sink.write(' {}');
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    _visitNode(node.typeParameters);
    _visitNode(node.parameters);
    sink.write(' {}');
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _visitNodeList(node.metadata, separator: ' ', suffix: ' ');
    _visitToken(node.externalKeyword, suffix: ' ');
    _visitToken(node.modifierKeyword, suffix: ' ');
    _visitNode(node.returnType, suffix: ' ');
    _visitToken(node.propertyKeyword, suffix: ' ');
    _visitToken(node.operatorKeyword, suffix: ' ');
    _visitToken(node.name);
    if (!node.isGetter) {
      _visitNode(node.typeParameters);
      _visitNode(node.parameters);
    }
    sink.write(' {}');
  }

  /// Print the given [node], printing the [prefix] before the node,
  /// and [suffix] after the node, if it is non-`null`.
  void _visitNode(AstNode? node, {String prefix = '', String suffix = ''}) {
    if (node != null) {
      sink.write(prefix);
      node.accept(this);
      sink.write(suffix);
    }
  }

  /// Print a list of [nodes], separated by the given [separator]; if the list
  /// is not empty print [prefix] before the first node, and [suffix] after
  /// the last node.
  void _visitNodeList(
    List<AstNode> nodes, {
    String prefix = '',
    String separator = '',
    String suffix = '',
  }) {
    final length = nodes.length;
    if (length > 0) {
      sink.write(prefix);
      for (int i = 0; i < length; i++) {
        if (i > 0) {
          sink.write(separator);
        }
        nodes[i].accept(this);
      }
      sink.write(suffix);
    }
  }

  /// Print the given [token].
  void _visitToken(Token? token, {String prefix = '', String suffix = ''}) {
    if (token != null) {
      sink.write(prefix);
      sink.write(token.lexeme);
      sink.write(suffix);
    }
  }
}

/// Generate a signature string from an AST node.
///
/// The signature shows the declaration structure without implementation:
/// - Classes show all members with bodies replaced by `{}`
/// - Methods show signature only
/// - Fields show full declaration
String generateSignature(AstNode node) {
  final buffer = StringBuffer();
  final visitor = SignatureVisitor(buffer);
  node.accept(visitor);
  return buffer.toString();
}
