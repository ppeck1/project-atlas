import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/mcp/atlas_mcp_server.dart';
import 'package:project_atlas/services/atlas_agent_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  group('AtlasMcpAdapter', () {
    late AppDb db;
    late AppState state;
    late AtlasMcpAdapter adapter;

    setUp(() {
      db = AppDb.withExecutor(NativeDatabase.memory());
      state = AppState(db, enableBackgroundSummaryRefresh: false);
      adapter = AtlasMcpAdapter(AtlasAgentService(state));
    });

    tearDown(() async {
      state.dispose();
      await db.close();
    });

    test('lists MCP-safe Atlas tools', () {
      final names = adapter.listTools().map((tool) => tool.name).toSet();

      expect(names, contains('list_projects'));
      expect(names, contains('get_project_brief'));
      expect(names, contains('get_project_identity'));
      expect(names, contains('get_project_capsule_status'));
      expect(names, contains('get_project_bootstrap_context'));
      expect(names, contains('atlas.workload_snapshot'));
      expect(names, contains('atlas.project_workload'));
      expect(names, contains('atlas.suggest_next_work'));
      expect(names, contains('atlas.work_item_context_bundle'));
      expect(names, contains('get_github_remote_status'));
      expect(names, contains('refresh_github_remote_status'));
      expect(names, contains('list_project_enrichment_runs'));
      expect(names, contains('get_project_enrichment_run'));
      expect(names, contains('run_project_enrichment'));
      expect(names, contains('enqueue_llm_task'));
      expect(names, contains('claim_llm_task'));
      expect(names, contains('complete_llm_task'));
      expect(names, contains('get_llm_task_bootstrap'));
      expect(names, contains('propose_status_change'));
      expect(names, contains('record_validation_run'));
      expect(names, contains('propose_closeout'));
      expect(names, isNot(contains('get_project_summary')));
      expect(names, isNot(contains('refresh_project_summaries')));
      expect(names, isNot(contains('delete_project')));
      expect(names, isNot(contains('push_to_github')));
    });

    test('dispatches read tools with JSON-safe results', () async {
      await db.createProject('bravo', 'Bravo', DateTime(2026, 1, 1));
      await db.createProject('alpha', 'Alpha', DateTime(2026, 1, 1));
      await db.updateProjectMeta('alpha', {'category': 'Program'});

      final result = await adapter.callTool('list_projects');

      expect(result.isError, isFalse);
      final rows = result.data as List;
      expect(rows.map((row) => (row as Map)['title']), ['Alpha', 'Bravo']);
      expect((rows.first as Map)['category'], 'Program');
    });

    test('dispatches bootstrap context with capsule visibility', () async {
      final root = await Directory.systemTemp.createTemp(
        'atlas_mcp_bootstrap_test_',
      );
      try {
        final projectDir = Directory(p.join(root.path, '.project'));
        Directory(p.join(projectDir.path, 'runs')).createSync(recursive: true);
        Directory(
          p.join(projectDir.path, 'atlas_outbox'),
        ).createSync(recursive: true);
        Directory(
          p.join(projectDir.path, 'boh_outbox'),
        ).createSync(recursive: true);
        File(
          p.join(projectDir.path, 'project_manifest.json'),
        ).writeAsStringSync(
          jsonEncode({
            'schema_version': '0.2',
            'project_id': 'atlas',
            'display_name': 'Atlas',
            'root': '.',
            'repo_kind': 'software',
            'visibility': 'public',
            'profiles': ['public_repo', 'software_project'],
            'canonical_docs': {
              'readme': 'README.md',
              'handoff': 'docs/HANDOFF.md',
              'variable_matrix': 'docs/VARIABLE_MATRIX.md',
            },
            'validation': {
              'required': ['flutter analyze'],
              'focused': <String>[],
              'smoke': <String>[],
              'manual': <String>[],
            },
            'protected_paths': ['README.md'],
            'generated_paths': ['build/'],
            'secrets_policy': 'names-only',
            'atlas_sync': {
              'enabled': true,
              'mode': 'outbox',
              'project_key': 'atlas',
            },
            'boh_sync': {
              'enabled': true,
              'mode': 'outbox',
              'authority': 'evidence-only',
              'project_key': 'atlas',
            },
            'git_policy': {
              'require_git': true,
              'commit_after_signable_run': true,
              'push_policy': 'manual',
              'allow_dirty_unrelated': false,
            },
          }),
        );
        File(p.join(projectDir.path, 'ops_capsule.json')).writeAsStringSync(
          jsonEncode({
            'schema_version': '0.2',
            'capsule_version': '0.2',
            'installed_from': 'test',
            'installed_at': '2026-01-01T00:00:00Z',
            'run_ledger_required': true,
            'repair_iteration_limit': 2,
            'readme_update_mode': 'audit-every-run',
            'variable_matrix_update_mode': 'audit-every-run',
            'handoff_update_mode': 'non-read-only',
            'subagent_policy': 'token-saving-default',
            'profiles': ['public_repo', 'software_project'],
          }),
        );
        File(
          p.join(projectDir.path, 'atlas_outbox', 'latest.json'),
        ).writeAsStringSync('{}');

        await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
        await _insertProjectRegistry(
          db,
          id: 'registry-atlas',
          projectId: 'atlas',
          displayName: 'Atlas Repo',
          localPath: root.path,
          gitRoot: root.path,
        );
        await adapter.callTool('enqueue_llm_task', {
          'projectId': 'atlas',
          'title': 'Read startup packet',
          'objective': 'Use the bootstrap context before work.',
        });

        final result = await adapter.callTool('get_project_bootstrap_context', {
          'projectId': 'atlas',
        });

        expect(result.isError, isFalse);
        final data = result.data as Map;
        expect(data['schema'], 'atlas.project_bootstrap_context.v1');
        expect((data['identity'] as Map)['capsuleProjectId'], 'atlas');
        expect(
          ((data['capsule'] as Map)['counts'] as Map)['atlasOutboxPending'],
          1,
        );
        expect((data['pendingLlmTasks'] as List), hasLength(1));
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('returns cached GitHub remote status through read tool', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      await db.upsertProjectGitRemoteStatus(
        projectId: 'atlas',
        provider: 'github',
        owner: 'ppeck1',
        repo: 'project-atlas',
        remoteUrl: 'https://github.com/ppeck1/project-atlas.git',
        visibility: 'public',
        defaultBranch: 'main',
        onlineHeadSha: 'abc123',
        isPrivate: false,
        isFork: false,
        isArchived: false,
        checkedAt: DateTime(2026, 6, 29),
      );

      final result = await adapter.callTool('get_github_remote_status', {
        'projectId': 'atlas',
      });

      expect(result.isError, isFalse);
      expect((result.data as Map)['fullName'], 'ppeck1/project-atlas');
      expect((result.data as Map)['visibility'], 'public');
    });

    test('dispatches read-only workload planning tools', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final stage = (await db.getStagesForProject('atlas')).single;
      final workItemId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Plan workboard slice',
        priority: 'high',
      );
      await db.updateWorkItem(
        id: workItemId,
        readiness: 'ready',
        size: 'tiny',
        risk: 'docs_only',
        suggestedActor: 'codex',
        verificationNeeded: 'tests',
        nextAction: 'Run workload tests.',
      );
      await db.enqueueLlmTask(
        projectId: 'atlas',
        workItemId: workItemId,
        title: 'Review plan',
        objective: 'Summarize the selected task for review.',
        contextJson: '{}',
        readiness: 'needs_context',
      );
      final decisionItemId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Choose reviewer',
        priority: 'urgent',
        readiness: 'needs_decision',
      );
      final workItemBefore = await db.getWorkItem(workItemId);
      final queueRowsBefore = await db.getLlmTasks(projectId: 'atlas');
      final draftCountBefore = await _rowCount(db, 'drafts');

      final snapshot = await adapter.callTool('atlas.workload_snapshot', {
        'actor': 'codex',
      });
      final projectWorkload = await adapter.callTool('atlas.project_workload', {
        'projectId': 'atlas',
      });
      final suggestions = await adapter.callTool('atlas.suggest_next_work', {
        'projectId': 'atlas',
        'limit': 3,
      });
      final bundle = await adapter.callTool('atlas.work_item_context_bundle', {
        'workItemId': workItemId,
      });

      expect(snapshot.isError, isFalse);
      expect((snapshot.data as Map)['schema'], 'atlas.workload_snapshot.v1');
      expect(
        ((((snapshot.data as Map)['counts'] as Map)['byActor']
            as Map)['codex']),
        1,
      );
      expect(projectWorkload.isError, isFalse);
      expect(((projectWorkload.data as Map)['cards'] as List), hasLength(3));
      expect(suggestions.isError, isFalse);
      final suggestedIds = (suggestions.data as List)
          .map((item) => (item as Map)['id'])
          .toList(growable: false);
      expect(suggestedIds, [workItemId]);
      expect(suggestedIds, isNot(contains(decisionItemId)));
      final planningIds =
          ((projectWorkload.data as Map)['planningCandidateItems'] as List)
              .map((item) => (item as Map)['id'])
              .toList(growable: false);
      expect(planningIds, contains(decisionItemId));
      expect(bundle.isError, isFalse);
      final context = bundle.data as Map;
      expect((context['workItem'] as Map)['id'], workItemId);
      expect((context['linkedLlmTasks'] as List), hasLength(1));

      final workItemAfter = await db.getWorkItem(workItemId);
      final queueRowsAfter = await db.getLlmTasks(projectId: 'atlas');
      final draftCountAfter = await _rowCount(db, 'drafts');
      expect(workItemAfter!.status, workItemBefore!.status);
      expect(workItemAfter.updatedAt, workItemBefore.updatedAt);
      expect(
        queueRowsAfter.map((task) => task.id),
        queueRowsBefore.map((task) => task.id),
      );
      expect(
        queueRowsAfter.map((task) => task.status),
        queueRowsBefore.map((task) => task.status),
      );
      expect(queueRowsAfter.map((task) => task.leasedBy), everyElement(isNull));
      expect(draftCountAfter, draftCountBefore);
    });

    test('dispatches Atlas-only project enrichment tools', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

      final runResult = await adapter.callTool('run_project_enrichment', {
        'refreshLinkedProjects': false,
        'includeSourceDocuments': false,
        'refreshSummaries': false,
      });
      final listResult = await adapter.callTool('list_project_enrichment_runs');
      final runId = (((runResult.data as Map)['run'] as Map)['id']).toString();
      final getResult = await adapter.callTool('get_project_enrichment_run', {
        'runId': runId,
      });

      expect(runResult.isError, isFalse);
      expect(listResult.isError, isFalse);
      expect((listResult.data as List), hasLength(1));
      expect(getResult.isError, isFalse);
      expect(((getResult.data as Map)['run'] as Map)['id'], runId);
      expect((getResult.data as Map)['findings'], isNotEmpty);
      expect((getResult.data as Map)['steps'], isNotEmpty);
      expect((getResult.data as Map)['proposals'], isNotEmpty);
    });

    test('dispatches proposal tools without applying changes', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

      final result = await adapter.callTool('propose_status_change', {
        'projectId': 'atlas',
        'status': 'blocked',
        'reason': 'Waiting on review',
      });
      final project = await db.getProjectFull('atlas');
      final proposals = await adapter.callTool('list_agent_proposals');

      expect(result.isError, isFalse);
      expect((result.data as Map)['acceptedForReview'], isTrue);
      expect(project!.status, 'active');
      expect(proposals.isError, isFalse);
      expect((proposals.data as List), hasLength(1));
    });

    test('dispatches closeout proposals without applying them', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

      final result = await adapter.callTool('propose_closeout', {
        'projectId': 'atlas',
        'runId': 'run-20260703',
        'runState': 'signable',
        'summary': 'MCP stdio smoke passed.',
        'changedFiles': ['lib/mcp/atlas_mcp_stdio.dart'],
        'validation': [
          {'command': 'smoke_mcp_stdio.py', 'passed': true},
        ],
        'gitState': {'dirty': true},
        'risks': ['Manual UI verification remains pending.'],
        'nextAction': 'Human review.',
      });
      final project = await db.getProjectFull('atlas');
      final proposals = await adapter.callTool('list_agent_proposals');

      expect(result.isError, isFalse);
      expect((result.data as Map)['type'], 'closeout_record');
      expect((result.data as Map)['acceptedForReview'], isTrue);
      expect(project!.status, 'active');
      expect(proposals.isError, isFalse);
      final review = (proposals.data as List).single as Map;
      expect(review['type'], 'closeout_record');
      expect(review['reviewStatus'], AtlasAgentService.reviewStatusPending);
    });

    test(
      'dispatches LLM queue lifecycle tools without direct project mutation',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

        final enqueue = await adapter.callTool('enqueue_llm_task', {
          'projectId': 'atlas',
          'title': 'Draft next action',
          'objective': 'Prepare a proposed next action for review.',
          'priority': 'high',
          'context': {'from': 'mcp-test'},
        });
        final taskId = (enqueue.data as Map)['id'] as String;
        final claim = await adapter.callTool('claim_llm_task', {
          'taskId': taskId,
          'workerId': 'llm-harness-test',
        });
        final complete = await adapter.callTool('complete_llm_task', {
          'taskId': taskId,
          'workerId': 'llm-harness-test',
          'result': {'summary': 'Review me'},
          'proposalTitle': 'Queued result',
          'proposalBody': 'This result should be reviewed by a human.',
        });
        final project = await db.getProjectFull('atlas');
        final proposals = await adapter.callTool('list_agent_proposals');

        expect(enqueue.isError, isFalse);
        expect(claim.isError, isFalse);
        expect((claim.data as Map)['status'], 'leased');
        expect(complete.isError, isFalse);
        expect((complete.data as Map)['status'], 'completed');
        expect((complete.data as Map)['reviewDraftId'], isNotNull);
        expect(project!.status, 'active');
        expect((proposals.data as List), hasLength(1));
      },
    );

    test('returns attached media metadata for LLM task detail', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final taskId = await db.enqueueLlmTask(
        projectId: 'atlas',
        title: 'Review screenshot',
        objective: 'Use the attached screenshot as context.',
        contextJson: '{}',
      );
      final mediaId = await db.saveProjectMedia(
        projectId: 'atlas',
        title: 'Screenshot',
        originalFilename: 'screenshot.png',
        storedPath: r'B:\tmp\screenshot.png',
        mediaType: 'image',
        mimeType: 'image/png',
        extension: 'png',
        byteSize: 42,
        source: 'test_fixtures/screenshot.png',
      );
      await db.linkProjectMediaToEntity(
        mediaId: mediaId,
        entityType: 'llm_task',
        entityId: taskId,
      );

      final result = await adapter.callTool('get_llm_task', {'taskId': taskId});

      expect(result.isError, isFalse);
      final task = result.data as Map;
      expect(task['id'], taskId);
      final media = task['media'] as List;
      expect(media, hasLength(1));
      expect((media.single as Map)['id'], mediaId);
      expect((media.single as Map)['originalFilename'], 'screenshot.png');
      expect((media.single as Map)['mediaType'], 'image');
      expect((media.single as Map)['storedPath'], r'B:\tmp\screenshot.png');
    });

    test('dispatches queue-bound bootstrap context for an LLM task', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final enqueue = await adapter.callTool('enqueue_llm_task', {
        'projectId': 'atlas',
        'title': 'Start from queue context',
        'objective': 'Read the task-bound bootstrap packet first.',
      });
      final taskId = (enqueue.data as Map)['id'] as String;

      final result = await adapter.callTool('get_llm_task_bootstrap', {
        'taskId': taskId,
        'projectId': 'atlas',
      });

      expect(result.isError, isFalse);
      final data = result.data as Map;
      expect(data['schema'], 'atlas.llm_task_bootstrap_context.v1');
      expect((data['task'] as Map)['id'], taskId);
      expect(
        ((data['projectBootstrap'] as Map)['identity'] as Map)['projectId'],
        'atlas',
      );
    });

    test('returns an error result for unknown tools', () async {
      final result = await adapter.callTool('delete_project', {
        'projectId': 'atlas',
      });

      expect(result.isError, isTrue);
      expect((result.data as Map)['tool'], 'delete_project');
    });
  });
}

Future<int> _rowCount(AppDb db, String table) async {
  final row = await db
      .customSelect('SELECT COUNT(*) AS count FROM "$table"')
      .getSingle();
  return row.data['count'] as int;
}

Future<void> _insertProjectRegistry(
  AppDb db, {
  required String id,
  required String projectId,
  required String displayName,
  required String localPath,
  required String gitRoot,
}) async {
  final now = DateTime(2026, 1, 1).millisecondsSinceEpoch;
  await db.customStatement(
    '''INSERT INTO project_registry (
       id, atlas_project_id, display_name, local_path, git_root,
       classification, review_state, notes, created_at, updated_at,
       last_reviewed_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
    [
      id,
      projectId,
      displayName,
      localPath,
      gitRoot,
      'software',
      'linked',
      null,
      now,
      now,
      now,
    ],
  );
}
