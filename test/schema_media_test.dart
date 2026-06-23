import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';

void main() {
  late AppDb db;

  setUp(() {
    db = AppDb.withExecutor(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('schema v10 creates project tag and media tables', () async {
    expect(db.schemaVersion, 10);

    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
        )
        .get();
    final tableNames = tables.map((row) => row.data['name']).toSet();

    expect(tableNames, contains('tags'));
    expect(tableNames, contains('project_tags'));
    expect(tableNames, contains('project_media'));
  });

  test('tags can be assigned and used to filter projects', () async {
    await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));
    await db.createProject('project-b', 'Beta', DateTime(2026, 1, 2));

    final urgentId = await db.saveTag(name: 'Urgent', color: '#d33');
    final clientId = await db.saveTag(name: 'Client');
    await db.assignTagToProject('project-a', urgentId);
    await db.assignTagToProject('project-a', clientId);
    await db.assignTagToProject('project-b', clientId);

    final alphaTags = await db.getTagsForProject('project-a');
    expect(alphaTags.map((tag) => tag.name), ['Client', 'Urgent']);

    final urgentProjects = await db.getProjectsForTag(urgentId);
    expect(urgentProjects.map((project) => project.id), ['project-a']);

    final matchingAll = await db.getProjectsMatchingTags([
      urgentId,
      clientId,
    ], matchAll: true);
    expect(matchingAll.map((project) => project.id), ['project-a']);
  });

  test(
    'project media import records file metadata without file picker',
    () async {
      await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));

      final tempDir = await Directory.systemTemp.createTemp(
        'atlas_media_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final image = File('${tempDir.path}${Platform.pathSeparator}sample.png');
      await image.writeAsBytes([0, 1, 2, 3, 4]);

      final mediaId = await db.importProjectMediaFromPath(
        'project-a',
        image.path,
        caption: 'Before photo',
        metadataJson: '{"kind":"test"}',
      );

      final media = await db.getProjectMediaItem(mediaId);
      expect(media, isNotNull);
      expect(media!.projectId, 'project-a');
      expect(media.originalFilename, 'sample.png');
      expect(media.extension, 'png');
      expect(media.mediaType, 'image');
      expect(media.mimeType, 'image/png');
      expect(media.byteSize, 5);
      expect(media.caption, 'Before photo');
      expect(media.metadataJson, '{"kind":"test"}');
    },
  );
}
