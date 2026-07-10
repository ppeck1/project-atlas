import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';

void main() {
  test('seeds the isolated CI database for the remote MCP smoke', () async {
    final databasePath = Platform.environment['ATLAS_MCP_SMOKE_DB'];
    expect(
      databasePath,
      isNotNull,
      reason: 'ATLAS_MCP_SMOKE_DB must identify the CI-owned database.',
    );

    final databaseFile = File(databasePath!);
    expect(
      databaseFile.existsSync(),
      isTrue,
      reason: 'The release executable must initialize the database first.',
    );

    final db = AppDb.withExecutor(NativeDatabase(databaseFile));
    addTearDown(db.close);

    const projectId = 'atlas-mcp-ci-smoke';
    if (await db.getProjectFull(projectId) == null) {
      await db.createProject(
        projectId,
        'Atlas MCP CI Smoke',
        DateTime.utc(2026, 1, 1),
      );
    }

    final project = await db.getProjectFull(projectId);
    expect(project, isNotNull);
    expect(project!.status, 'active');
    expect(project.deletedAt, isNull);
  });
}
