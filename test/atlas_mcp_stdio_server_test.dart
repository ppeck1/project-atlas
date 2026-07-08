import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/mcp/atlas_mcp_server.dart';
import 'package:project_atlas/mcp/atlas_mcp_stdio_server.dart';
import 'package:project_atlas/services/atlas_agent_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  group('AtlasMcpJsonRpcServer', () {
    late AppDb db;
    late AppState state;
    late AtlasMcpJsonRpcServer server;

    setUp(() {
      db = AppDb.withExecutor(NativeDatabase.memory());
      state = AppState(db, enableBackgroundSummaryRefresh: false);
      server = AtlasMcpJsonRpcServer(AtlasMcpAdapter(AtlasAgentService(state)));
    });

    tearDown(() async {
      state.dispose();
      await db.close();
    });

    test('handles initialize and tools/list', () async {
      final initialize = await server.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': const {},
      });
      final tools = await server.handle({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
        'params': const {},
      });
      final initialized = await server.handle({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
        'params': const {},
      });

      expect((initialize!['result'] as Map)['protocolVersion'], '2025-06-18');
      expect((initialize['result'] as Map)['serverInfo'], isA<Map>());
      expect(initialized, isNull);
      final toolRows = (tools!['result'] as Map)['tools'] as List;
      expect(
        toolRows.map((tool) => (tool as Map)['name']),
        contains('list_projects'),
      );
      expect(
        toolRows.map((tool) => (tool as Map)['name']),
        contains('get_llm_task_bootstrap'),
      );
      expect(
        toolRows.map((tool) => (tool as Map)['name']),
        contains('atlas.project_planning_context'),
      );
    });

    test('dispatches tools/call requests', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

      final response = await server.handleJson(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'call-1',
          'method': 'tools/call',
          'params': {
            'name': 'list_projects',
            'arguments': {'includeArchived': true},
          },
        }),
      );

      expect(response!['id'], 'call-1');
      final result = response['result'] as Map;
      expect(result['isError'], isFalse);
      final content = result['content'] as List;
      final text = (content.single as Map)['text'] as String;
      expect(text, contains('Atlas'));
    });

    test(
      'returns JSON-RPC method errors separately from tool errors',
      () async {
        final missingMethod = await server.handle({
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'missing/method',
        });
        final missingTool = await server.handle({
          'jsonrpc': '2.0',
          'id': 4,
          'method': 'tools/call',
          'params': {'name': 'missing_tool'},
        });

        expect(((missingMethod!['error'] as Map)['code']), -32601);
        final result = missingTool!['result'] as Map;
        expect(result['isError'], isTrue);
        expect(result['content'].toString(), contains('missing_tool'));
      },
    );
  });
}
