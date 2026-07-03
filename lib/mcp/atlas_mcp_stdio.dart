import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../db/app_db.dart';
import '../services/atlas_agent_service.dart';
import '../shared/models/app_state.dart';
import 'atlas_mcp_server.dart';
import 'atlas_mcp_stdio_server.dart';

Future<void> runAtlasMcpStdio(List<String> args) async {
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.trim().isNotEmpty) {
      stderr.writeln(message);
    }
  };

  final db = AppDb();
  final state = AppState(db, enableBackgroundSummaryRefresh: false);
  final server = AtlasMcpJsonRpcServer(
    AtlasMcpAdapter(AtlasAgentService(state)),
  );

  var code = 0;
  try {
    final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final response = await server.handleJson(line);
      if (response != null) {
        stdout.writeln(jsonEncode(response));
      }
    }
  } catch (error, stackTrace) {
    code = 1;
    stderr.writeln('Atlas MCP stdio failed: $error');
    stderr.writeln(stackTrace);
  } finally {
    state.dispose();
    await db.close();
  }
  exit(code);
}
