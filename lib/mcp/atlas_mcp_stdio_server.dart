import 'dart:convert';

import 'atlas_mcp_server.dart';

class AtlasMcpJsonRpcServer {
  final AtlasMcpAdapter adapter;

  const AtlasMcpJsonRpcServer(this.adapter);

  Future<Map<String, Object?>?> handleJson(String line) async {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (error) {
      return _error(null, -32700, 'Parse error', '$error');
    }
    if (decoded is! Map) {
      return _error(null, -32600, 'Invalid Request', 'Request must be a map.');
    }
    return handle(decoded.map((key, value) => MapEntry('$key', value)));
  }

  Future<Map<String, Object?>?> handle(Map<String, Object?> request) async {
    final id = request['id'];
    final method = request['method'];
    if (method is! String || method.trim().isEmpty) {
      return _error(id, -32600, 'Invalid Request', 'Missing method.');
    }
    try {
      switch (method) {
        case 'initialize':
          return _result(id, {
            'protocolVersion': '2025-06-18',
            'serverInfo': {'name': 'project-atlas', 'version': '0.1.0'},
            'capabilities': {
              'tools': {'listChanged': false},
            },
          });
        case 'tools/list':
          return _result(id, {
            'tools': adapter.listTools().map((tool) => tool.toJson()).toList(),
          });
        case 'notifications/initialized':
          return null;
        case 'tools/call':
          final params = _params(request['params']);
          final name = _string(params['name']);
          if (name == null) {
            return _error(id, -32602, 'Invalid params', 'Tool name required.');
          }
          final arguments = _params(params['arguments']);
          final result = await adapter.callTool(name, arguments);
          return _result(id, result.toJson());
        default:
          return _error(id, -32601, 'Method not found', method);
      }
    } catch (error) {
      return _error(id, -32603, 'Internal error', '$error');
    }
  }

  Map<String, Object?> _result(Object? id, Object? result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  Map<String, Object?> _error(
    Object? id,
    int code,
    String message,
    String data,
  ) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message, 'data': data},
  };

  Map<String, Object?> _params(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, value) => MapEntry('$key', value));
  }

  String? _string(Object? value) {
    if (value == null) return null;
    final trimmed = '$value'.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
