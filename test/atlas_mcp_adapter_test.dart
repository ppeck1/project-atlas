import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
      expect(names, contains('get_github_remote_status'));
      expect(names, contains('refresh_github_remote_status'));
      expect(names, contains('list_project_enrichment_runs'));
      expect(names, contains('get_project_enrichment_run'));
      expect(names, contains('run_project_enrichment'));
      expect(names, contains('enqueue_llm_task'));
      expect(names, contains('claim_llm_task'));
      expect(names, contains('complete_llm_task'));
      expect(names, contains('propose_status_change'));
      expect(names, contains('record_validation_run'));
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

    test('returns an error result for unknown tools', () async {
      final result = await adapter.callTool('delete_project', {
        'projectId': 'atlas',
      });

      expect(result.isError, isTrue);
      expect((result.data as Map)['tool'], 'delete_project');
    });
  });
}
