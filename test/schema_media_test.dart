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

  test(
    'schema v20 creates project, media-link, runtime, queue, and operations tables',
    () async {
      expect(db.schemaVersion, 20);

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
          )
          .get();
      final tableNames = tables.map((row) => row.data['name']).toSet();

      expect(tableNames, contains('tags'));
      expect(tableNames, contains('project_tags'));
      expect(tableNames, contains('work_item_tags'));
      expect(tableNames, contains('project_media'));
      expect(tableNames, contains('media_links'));
      expect(tableNames, contains('local_project_refresh_items'));
      expect(tableNames, contains('project_git_remotes'));
      expect(tableNames, contains('project_enrichment_runs'));
      expect(tableNames, contains('project_enrichment_findings'));
      expect(tableNames, contains('project_enrichment_steps'));
      expect(tableNames, contains('project_enrichment_proposals'));
      expect(tableNames, contains('llm_task_queue'));
      expect(tableNames, contains('project_runtime_profiles'));
      expect(tableNames, contains('project_runtime_runs'));
    },
  );

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

  test('project category persists as editable free-text metadata', () async {
    await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));

    await db.updateProjectMeta('project-a', {'category': 'Work'});

    final project = await db.getProjectFull('project-a');
    expect(project!.category, 'Work');

    await db.updateProjectMeta('project-a', {'category': null});
    final cleared = await db.getProjectFull('project-a');
    expect(cleared!.category, isNull);
  });

  test('summary eligible projects include attention statuses', () async {
    final statuses = {
      'active-project': 'active',
      'stale-project': 'stale',
      'deleted-stale-project': 'stale',
      'needs-update-project': 'needs_update',
      'needs-review-project': 'needs_review',
      'local-only-project': 'local_only',
      'public-mismatch-project': 'public_mismatch',
      'blocked-project': 'blocked',
      'completed-project': 'completed',
      'archived-project': 'archived',
    };
    var day = 1;
    for (final entry in statuses.entries) {
      await db.createProject(entry.key, entry.key, DateTime(2026, 1, day++));
      await db.updateProjectMeta(entry.key, {'status': entry.value});
    }
    await db.softDeleteProject('deleted-stale-project', 'deleted test project');

    final eligible = await db.getSummaryEligibleProjects();
    final ids = eligible.map((project) => project.id).toSet();

    expect(ids, {
      'active-project',
      'stale-project',
      'needs-update-project',
      'needs-review-project',
      'local-only-project',
      'public-mismatch-project',
      'blocked-project',
    });
    expect(ids, isNot(contains('deleted-stale-project')));
    expect(ids, isNot(contains('completed-project')));
    expect(ids, isNot(contains('archived-project')));
  });

  test(
    'project status aliases persist canonically for summary selection',
    () async {
      await db.createProject('review-project', 'Review', DateTime(2026, 1, 1));
      await db.updateProjectMeta('review-project', {'status': 'Needs Review'});

      final stored = await db.getProjectFull('review-project');
      expect(stored!.status, 'needs_review');

      final eligible = await db.getSummaryEligibleProjects();
      expect(eligible.map((project) => project.id), contains('review-project'));
    },
  );

  test(
    'tags can be assigned to work items independently of project tags',
    () async {
      await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));
      final stage = (await db.getStagesForProject('project-a')).single;
      final workItemId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Tagged task',
      );
      final reviewId = await db.saveTag(name: 'Review', color: '#00aabb');
      final nextId = await db.saveTag(name: 'Next');
      await db.assignTagToWorkItem(workItemId, reviewId);
      await db.assignTagToWorkItem(workItemId, nextId);

      final tags = await db.getTagsForWorkItem(workItemId);
      expect(tags.map((tag) => tag.name), ['Next', 'Review']);

      await db.setWorkItemTags(workItemId, [reviewId]);
      final updated = await db.getTagsForWorkItems([workItemId]);
      expect(updated[workItemId]?.map((tag) => tag.name), ['Review']);

      await db.deleteTag(reviewId);
      expect(await db.getTagsForWorkItem(workItemId), isEmpty);
    },
  );

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

  test('project media can link to work items and queued LLM tasks', () async {
    await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));
    final stage = (await db.getStagesForProject('project-a')).single;
    final workItemId = await db.addWorkItem(
      stageId: stage.id,
      title: 'Explain image',
    );
    final taskId = await db.enqueueLlmTask(
      projectId: 'project-a',
      title: 'Review image context',
      objective: 'Use attached image as supporting context.',
      contextJson: '{}',
    );
    final mediaId = await db.saveProjectMedia(
      projectId: 'project-a',
      title: 'Sketch',
      originalFilename: 'sketch.png',
      storedPath: r'B:\tmp\sketch.png',
      mediaType: 'image',
    );

    await db.linkProjectMediaToEntity(
      mediaId: mediaId,
      entityType: 'work_item',
      entityId: workItemId,
    );
    await db.linkProjectMediaToEntity(
      mediaId: mediaId,
      entityType: 'llm_task',
      entityId: taskId,
    );

    final workMedia = await db.getProjectMediaForEntity(
      entityType: 'work_item',
      entityId: workItemId,
    );
    final taskMedia = await db.getProjectMediaForEntity(
      entityType: 'llm_task',
      entityId: taskId,
    );

    expect(workMedia.map((item) => item.id), [mediaId]);
    expect(taskMedia.map((item) => item.id), [mediaId]);

    await db.unlinkProjectMediaFromEntity(
      mediaId: mediaId,
      entityType: 'llm_task',
      entityId: taskId,
    );
    expect(
      await db.getProjectMediaForEntity(
        entityType: 'llm_task',
        entityId: taskId,
      ),
      isEmpty,
    );
  });

  test('mergeProjects moves source project records to target', () async {
    await db.createProject('source-project', 'Source', DateTime(2026, 1, 1));
    await db.createProject('target-project', 'Target', DateTime(2026, 1, 2));
    final sourceStage = (await db.getStagesForProject('source-project')).single;
    await db.addWorkItem(
      stageId: sourceStage.id,
      title: 'Source task',
      description: 'Move me',
    );
    await db.addProjectRisk('source-project', 'Risk', 'Risk desc', 'medium');
    await db.addProjectDecision(
      'source-project',
      'Decision',
      'Decision context',
      'Owner',
    );
    final tagId = await db.saveTag(name: 'Merged');
    await db.assignTagToProject('source-project', tagId);
    await db.saveProjectMedia(
      projectId: 'source-project',
      title: 'Photo',
      originalFilename: 'photo.png',
      storedPath: r'B:\tmp\photo.png',
      mediaType: 'image',
      source: 'test',
    );
    await db.saveDraft(
      kind: 'project_summary',
      title: 'Source summary',
      body: 'Summary',
      projectId: 'source-project',
    );

    final result = await db.mergeProjects(
      sourceProjectId: 'source-project',
      targetProjectId: 'target-project',
    );

    final source = await db.getProjectFull('source-project');
    final targetStages = await db.getStagesForProject('target-project');
    final targetWork = await db.getWorkItemsForProject('target-project');
    final targetMedia = await db.getProjectMedia('target-project');
    final targetTags = await db.getTagsForProject('target-project');
    final targetRisks = await db.getProjectRisks('target-project');
    final targetDecisions = await db.getProjectDecisions('target-project');
    final targetDraft = await db.getLatestProjectSummaryDraft('target-project');

    expect(source?.status, 'deleted');
    expect(source?.deleteReason, contains('Merged into Target'));
    expect(targetStages, hasLength(2));
    expect(targetWork.map((item) => item.title), contains('Source task'));
    expect(targetMedia.map((item) => item.originalFilename), ['photo.png']);
    expect(targetTags.map((tag) => tag.name), ['Merged']);
    expect(targetRisks.map((risk) => risk.title), ['Risk']);
    expect(targetDecisions.map((decision) => decision.title), ['Decision']);
    expect(targetDraft?.title, 'Source summary');
    expect(result['media'], 1);
  });
}
