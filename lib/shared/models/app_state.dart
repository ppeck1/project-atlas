import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../db/app_db.dart';
import '../../services/github_remote_metadata_service.dart';
import '../../services/local_git_visibility_service.dart';
import '../../services/local_project_refresh_service.dart';
import '../../services/local_operations_scanner.dart';
import '../../services/ollama_service.dart';
import '../../services/project_summary_models.dart';
import '../../services/telegram_service.dart';

class ProjectLocalRepoSummary {
  final ProjectRegistryEntry? registry;
  final ProjectObservation? observation;
  final List<LocalProjectRefreshItem> refreshItems;
  final List<Document> documents;
  final List<ProjectMediaItem> media;

  const ProjectLocalRepoSummary({
    required this.registry,
    required this.refreshItems,
    required this.documents,
    required this.media,
    this.observation,
  });

  String? get repoRoot =>
      registry == null ? null : registry!.gitRoot ?? registry!.localPath;
  int get sourceFileCount =>
      refreshItems.where((item) => item.sourceKind == 'source_file').length;
  int get documentRefreshCount =>
      refreshItems.where((item) => item.sourceKind == 'document').length;
  int get mediaRefreshCount =>
      refreshItems.where((item) => item.sourceKind == 'media').length;
  int get cardCount =>
      refreshItems.where((item) => item.sourceKind == 'atlas_card').length;
}

String _pathKey(String value) => value
    .trim()
    .replaceAll('/', r'\')
    .replaceAll(RegExp(r'\\+$'), '')
    .toLowerCase();

class ProjectBundleExportPreview {
  final String schema;
  final String projectId;
  final String projectTitle;
  final bool includeFiles;
  final int stages;
  final int workItems;
  final int workItemNotes;
  final int workItemAnalyses;
  final int documents;
  final int copiedDocumentFiles;
  final int media;
  final int copiedMediaFiles;
  final int people;
  final int risks;
  final int decisions;
  final bool hasRegistry;
  final int observations;
  final int refreshItems;
  final List<String> warnings;

  const ProjectBundleExportPreview({
    required this.schema,
    required this.projectId,
    required this.projectTitle,
    required this.includeFiles,
    required this.stages,
    required this.workItems,
    required this.workItemNotes,
    required this.workItemAnalyses,
    required this.documents,
    required this.copiedDocumentFiles,
    required this.media,
    required this.copiedMediaFiles,
    required this.people,
    required this.risks,
    required this.decisions,
    required this.hasRegistry,
    required this.observations,
    required this.refreshItems,
    required this.warnings,
  });

  int get atlasRecordCount =>
      1 +
      stages +
      workItems +
      workItemNotes +
      workItemAnalyses +
      documents +
      media +
      people +
      risks +
      decisions +
      (hasRegistry ? 1 : 0) +
      observations +
      refreshItems;

  int get copiedFileCount =>
      includeFiles ? copiedDocumentFiles + copiedMediaFiles : 0;
}

class ProjectSummaryRefreshResult {
  final int considered;
  final int refreshed;
  final int skipped;
  final int failed;
  final bool aiUnavailable;
  final bool alreadyRunning;
  final List<String> errors;

  const ProjectSummaryRefreshResult({
    required this.considered,
    required this.refreshed,
    required this.skipped,
    required this.failed,
    required this.aiUnavailable,
    this.alreadyRunning = false,
    required this.errors,
  });
}

class LocalProjectBatchRefreshResult {
  final int considered;
  final int refreshed;
  final int created;
  final int updated;
  final int unchanged;
  final int skipped;
  final int failed;
  final bool alreadyRunning;
  final List<String> warnings;

  const LocalProjectBatchRefreshResult({
    required this.considered,
    required this.refreshed,
    required this.created,
    required this.updated,
    required this.unchanged,
    required this.skipped,
    required this.failed,
    this.alreadyRunning = false,
    required this.warnings,
  });
}

typedef ProjectEnrichmentStatusCallback =
    void Function(String status, {int? current, int? total});

class ProjectEnrichmentRunResult {
  final ProjectEnrichmentRun run;
  final List<ProjectEnrichmentFinding> findings;
  final List<ProjectEnrichmentStep> steps;
  final List<ProjectEnrichmentProposal> proposals;

  const ProjectEnrichmentRunResult({
    required this.run,
    required this.findings,
    this.steps = const [],
    this.proposals = const [],
  });

  Map<String, Object?> toJson() => {
    'run': run.toJson(),
    'findings': findings.map((finding) => finding.toJson()).toList(),
    'steps': steps.map((step) => step.toJson()).toList(),
    'proposals': proposals.map((proposal) => proposal.toJson()).toList(),
  };
}

class _ProjectEnrichmentFindingDraft {
  final String? projectId;
  final String? registryId;
  final String severity;
  final String category;
  final String title;
  final String? detail;
  final Map<String, Object?> evidence;

  const _ProjectEnrichmentFindingDraft({
    this.projectId,
    this.registryId,
    required this.severity,
    required this.category,
    required this.title,
    this.detail,
    this.evidence = const {},
  });
}

class _ProjectEnrichmentAudit {
  final List<_ProjectEnrichmentFindingDraft> findings;
  final Map<String, Object?> coverage;

  const _ProjectEnrichmentAudit({
    required this.findings,
    required this.coverage,
  });
}

class _ProjectIdentityEnrichmentResult {
  final int considered;
  final int updated;
  final int unchanged;
  final int skipped;
  final List<String> warnings;

  const _ProjectIdentityEnrichmentResult({
    required this.considered,
    required this.updated,
    required this.unchanged,
    required this.skipped,
    required this.warnings,
  });
}

/// App-wide state wrapper around [AppDb].
class AppState extends ChangeNotifier {
  final AppDb db;
  static const Set<String> _safeLocalProjectDocNames = {
    'README.md',
    'ACTIVE_TASK.md',
    'CURRENT_STATE.md',
    'AGENTS.md',
    'CLAUDE.md',
    'package.json',
    'pubspec.yaml',
    'pyproject.toml',
  };
  static const int _projectEnrichmentProposalCap = 120;

  Timer? _summaryRefreshTimer;
  Timer? _localProjectRefreshTimer;
  bool _summaryRefreshRunning = false;
  bool _localProjectRefreshRunning = false;
  bool _projectEnrichmentRunning = false;
  String? _projectEnrichmentStatus;
  DateTime? _projectEnrichmentStartedAt;
  int? _projectEnrichmentProgressCurrent;
  int? _projectEnrichmentProgressTotal;

  bool get isProjectSummaryRefreshRunning => _summaryRefreshRunning;
  bool get isLocalProjectRefreshRunning => _localProjectRefreshRunning;
  bool get isProjectEnrichmentRunning => _projectEnrichmentRunning;
  String? get projectEnrichmentStatus => _projectEnrichmentStatus;
  DateTime? get projectEnrichmentStartedAt => _projectEnrichmentStartedAt;
  double? get projectEnrichmentProgress {
    final total = _projectEnrichmentProgressTotal;
    final current = _projectEnrichmentProgressCurrent;
    if (total == null || current == null || total <= 0) return null;
    return current.clamp(0, total).toDouble() / total;
  }

  String? get projectEnrichmentProgressLabel {
    final total = _projectEnrichmentProgressTotal;
    final current = _projectEnrichmentProgressCurrent;
    if (total == null || current == null || total <= 0) return null;
    return '$current/$total';
  }

  AppState(this.db, {bool enableBackgroundSummaryRefresh = true}) {
    _activeProjectSub = db.watchActiveProject().listen(
      (p) {
        _activeProject = p;
        hasActiveProject.value = p != null;
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Atlas] active project stream failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
    unawaited(
      db.ensureDefaultStagesForProjects().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        debugPrint('[Atlas] ensureDefaultStages failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }),
    );
    if (enableBackgroundSummaryRefresh) {
      // Background-refresh project summaries after the UI has settled.
      Future.delayed(const Duration(seconds: 10), _backgroundSummaryRefresh);
      _summaryRefreshTimer = Timer.periodic(
        const Duration(hours: 6),
        (_) => _backgroundSummaryRefresh(),
      );
      _localProjectRefreshTimer = Timer.periodic(
        const Duration(hours: 12),
        (_) => refreshLinkedLocalProjects(includeSourceDocuments: false),
      );
    }
  }

  late final StreamSubscription<Project?> _activeProjectSub;
  Project? _activeProject;

  Project? get activeProject => _activeProject;
  final ValueNotifier<bool> hasActiveProject = ValueNotifier<bool>(false);

  // ---------------------------------------------------------------------------
  // Projects
  // ---------------------------------------------------------------------------

  Stream<List<Project>> watchProjects() => db.watchProjects();
  Future<List<Project>> getVisibleProjects() => db.getVisibleProjects();
  Stream<Project?> watchProject(String id) => db.watchProject(id);
  Stream<Project?> watchActiveProject() => db.watchActiveProject();

  Future<void> createProject(String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    debugPrint('[Atlas] AppState.createProject: "$t" id=$id');
    await db.createProject(id, t, DateTime.now());
    await db.logEvent(
      area: 'ui',
      action: 'create_project',
      entityType: 'project',
      entityId: id,
      inputJson: t,
    );
    notifyListeners();
    debugPrint('[Atlas] AppState.createProject: done, notified listeners');
  }

  Future<void> setActiveById(String id) async {
    await db.setActiveProjectId(id);
    notifyListeners();
  }

  Future<Map<String, int>> mergeProjects({
    required String sourceProjectId,
    required String targetProjectId,
  }) async {
    final result = await db.mergeProjects(
      sourceProjectId: sourceProjectId,
      targetProjectId: targetProjectId,
    );
    notifyListeners();
    return result;
  }

  // ---------------------------------------------------------------------------
  // Stages
  // ---------------------------------------------------------------------------

  Stream<List<Stage>> watchStagesForProject(String projectId) =>
      db.watchStagesForProject(projectId);

  Stream<Stage?> watchActiveStageForProject(String projectId) =>
      db.watchActiveStageForProject(projectId);

  Future<void> setActiveStageForProject(
    String projectId,
    String stageId,
  ) async {
    await db.setActiveStageIdForProject(projectId, stageId);
    notifyListeners();
  }

  // Stage management
  Future<void> addStage(String projectId, String title) async {
    await db.addStage(projectId, title);
    notifyListeners();
  }

  Future<void> updateStageTitle(String stageId, String title) async {
    await db.updateStageTitle(stageId, title);
    notifyListeners();
  }

  Future<void> deleteStage(String stageId) async {
    await db.deleteStage(stageId);
    notifyListeners();
  }

  Future<void> reorderStage(String stageId, int newPosition) async {
    await db.reorderStage(stageId, newPosition);
    notifyListeners();
  }

  // Daily reviews
  Future<void> saveDailyReview(String summary) => db.saveDailyReview(summary);
  Future<DailyReview?> getDailyReviewForDate(DateTime date) =>
      db.getDailyReviewForDate(date);
  Stream<List<DailyReview>> watchRecentDailyReviews({int limit = 30}) =>
      db.watchRecentDailyReviews(limit: limit);

  // ---------------------------------------------------------------------------
  // Work items
  // ---------------------------------------------------------------------------

  Stream<List<WorkItem>> watchWorkItemsForStage(String stageId) =>
      db.watchWorkItemsForStage(stageId);

  Stream<List<WorkItem>> watchTodayItems() => db.watchTodayItems();
  Stream<List<WorkItem>> watchAllActiveWorkItems() =>
      db.watchAllActiveWorkItems();

  Future<void> addWorkItem(
    String stageId,
    String title, {
    String? description,
    String? owner,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? source,
    String? blockedReason,
  }) async {
    await db.logEvent(
      area: 'ui',
      action: 'create_task_request',
      entityType: 'stage',
      entityId: stageId,
      inputJson: title,
    );
    await db.addWorkItem(
      stageId: stageId,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      dueAt: dueAt,
      source: source,
      blockedReason: blockedReason,
    );
    await db.logEvent(
      area: 'ui',
      action: 'create_task_success',
      entityType: 'stage',
      entityId: stageId,
      inputJson: title,
    );
    notifyListeners();
  }

  Future<String> addWorkItemToProject(
    String projectId,
    String title, {
    String? description,
    String? owner,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? source,
    String? blockedReason,
    Iterable<String> tagIds = const [],
  }) async {
    var stages = await db.getStagesForProject(projectId);
    if (stages.isEmpty) {
      await db.ensureDefaultStagesForProjects();
      stages = await db.getStagesForProject(projectId);
    }
    if (stages.isEmpty) {
      throw StateError('Project has no stage for tasks.');
    }
    await db.logEvent(
      area: 'ui',
      action: 'create_today_task_request',
      entityType: 'project',
      entityId: projectId,
      inputJson: title,
    );
    final workItemId = await db.addWorkItem(
      stageId: stages.first.id,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      dueAt: dueAt,
      source: source,
      blockedReason: blockedReason,
    );
    await db.setWorkItemTags(workItemId, tagIds);
    await db.logEvent(
      area: 'ui',
      action: 'create_today_task_success',
      entityType: 'work_item',
      entityId: workItemId,
      inputJson: title,
    );
    notifyListeners();
    return workItemId;
  }

  Future<String> addGeneralWorkItem(
    String title, {
    String? description,
    String? owner,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? source,
    String? blockedReason,
    Iterable<String> tagIds = const [],
  }) async {
    final stageId = await db.ensureGeneralTaskStage();
    await db.logEvent(
      area: 'ui',
      action: 'create_general_task_request',
      entityType: 'stage',
      entityId: stageId,
      inputJson: title,
    );
    final workItemId = await db.addWorkItem(
      stageId: stageId,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      dueAt: dueAt,
      source: source,
      blockedReason: blockedReason,
    );
    await db.setWorkItemTags(workItemId, tagIds);
    await db.logEvent(
      area: 'ui',
      action: 'create_general_task_success',
      entityType: 'work_item',
      entityId: workItemId,
      inputJson: title,
    );
    notifyListeners();
    return workItemId;
  }

  Future<void> updateWorkItem({
    required String id,
    String? title,
    String? description,
    String? owner,
    String? status,
    String? priority,
    bool clearDueAt = false,
    DateTime? dueAt,
    String? blockedReason,
    bool clearBlockedReason = false,
    bool? phoneQueue,
  }) async {
    await db.logEvent(
      area: 'ui',
      action: 'update_task_request',
      entityType: 'work_item',
      entityId: id,
    );
    await db.updateWorkItem(
      id: id,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      clearDueAt: clearDueAt,
      dueAt: dueAt,
      blockedReason: blockedReason,
      clearBlockedReason: clearBlockedReason,
      phoneQueue: phoneQueue,
    );
    await db.logEvent(
      area: 'ui',
      action: 'update_task_success',
      entityType: 'work_item',
      entityId: id,
    );
    notifyListeners();
  }

  Future<void> setWorkItemStatus(String id, String status) async {
    await db.setWorkItemStatus(id, status);
    notifyListeners();
  }

  Future<void> toggleWorkDone(String workItemId) async {
    await db.toggleWorkDone(workItemId);
    notifyListeners();
  }

  Future<WorkItem?> getWorkItem(String id) => db.getWorkItem(id);
  Future<Project?> getProjectForWorkItem(String id) =>
      db.getProjectForWorkItem(id);
  Future<List<WorkItem>> getAllActiveWorkItems() => db.getAllActiveWorkItems();
  Future<List<WorkItem>> getTodayItems() => db.getTodayItems();
  Future<List<WorkItem>> getBlockedItems() => db.getBlockedItems();

  // ---------------------------------------------------------------------------
  // Governance
  // ---------------------------------------------------------------------------

  Stream<String?> watchWorkOwner(String id) => db.watchWorkOwner(id);
  Future<void> setWorkOwner(String id, String? owner) async {
    await db.setWorkOwner(id, owner);
    notifyListeners();
  }

  Stream<String?> watchBottleneckOwner(String id) =>
      db.watchBottleneckOwner(id);
  Future<void> setBottleneckOwner(String id, String? owner) async {
    await db.setBottleneckOwner(id, owner);
    notifyListeners();
  }

  Stream<bool> watchIsBottleneck(String id) => db.watchIsBottleneck(id);
  Future<void> setIsBottleneck(String id, bool v) async {
    await db.setIsBottleneck(id, v);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  Future<String?> getSetting(String key) => db.getMetaString(key);
  Future<void> setSetting(String key, String? value) =>
      db.setMetaString(key, value);
  Stream<String?> watchSetting(String key) => db.watchMetaString(key);

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  Stream<List<Draft>> watchDrafts() => db.watchDrafts();
  Future<Draft?> getDraft(String id) => db.getDraft(id);

  Future<String> saveDraft({
    required String kind,
    required String title,
    required String body,
    String? inputJson,
    String? projectId,
    String? workItemId,
  }) async {
    final id = await db.saveDraft(
      kind: kind,
      title: title,
      body: body,
      inputJson: inputJson,
      projectId: projectId,
      workItemId: workItemId,
    );
    notifyListeners();
    return id;
  }

  Future<void> updateDraftReview({
    required String id,
    required bool accepted,
    String? inputJson,
    String? body,
  }) async {
    await db.updateDraftReview(
      id: id,
      accepted: accepted,
      inputJson: inputJson,
      body: body,
    );
    notifyListeners();
  }

  Future<void> deleteDraft(String id) async {
    await db.deleteDraft(id);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Ollama ��������� human-in-the-loop only. Output is never auto-applied.
  // ---------------------------------------------------------------------------

  OllamaService _buildOllama(String? host, String? model) => OllamaService(
    host: host?.trim().isNotEmpty == true
        ? host!.trim()
        : 'http://localhost:11434',
    model: model?.trim().isNotEmpty == true ? model!.trim() : 'qwen3.5:9b',
  );

  Future<OllamaResult> summarizeProject(String projectId) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final proj = await (db.select(
      db.projects,
    )..where((t) => t.id.equals(projectId))).getSingleOrNull();

    // Resolve items by querying stages that belong to this project
    final projectStages = await db.getStagesForProject(projectId);
    final stageIds = projectStages.map((s) => s.id).toSet();

    final all = await db.getAllActiveWorkItems();
    final projectItems = all
        .where((i) => stageIds.contains(i.stageId))
        .toList();

    final active = projectItems
        .where((i) => !['done', 'archived'].contains(i.status))
        .map((i) => i.title)
        .toList();
    final blocked = projectItems
        .where((i) => i.blockedReason != null)
        .map((i) => '${i.title} (${i.blockedReason})')
        .toList();
    final done = projectItems
        .where((i) => i.status == 'done')
        .map((i) => i.title)
        .take(10)
        .toList();

    return svc.summarizeProject(
      projectTitle: proj?.title ?? projectId,
      activeItems: active,
      blockedItems: blocked,
      completedRecently: done,
    );
  }

  Future<OllamaResult> summarizeToday() async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final items = await getTodayItems();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return svc.summarizeToday(
      doingItems: items
          .where((i) => i.status == 'doing')
          .map((i) => i.title)
          .toList(),
      overdueItems: items
          .where(
            (i) =>
                i.dueAt != null &&
                i.dueAt!.isBefore(today) &&
                i.status != 'doing',
          )
          .map((i) => i.title)
          .toList(),
      dueTodayItems: items
          .where(
            (i) =>
                i.dueAt != null &&
                !i.dueAt!.isBefore(today) &&
                i.dueAt!.isBefore(today.add(const Duration(days: 1))),
          )
          .map((i) => i.title)
          .toList(),
      blockedItems: items
          .where((i) => i.blockedReason != null)
          .map((i) => '${i.title} ��������� ${i.blockedReason}')
          .toList(),
    );
  }

  Future<OllamaResult> draftEmailForTask(
    String workItemId,
    String instruction,
  ) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final item = await getWorkItem(workItemId);
    if (item == null) {
      return OllamaResult(
        input: instruction,
        output: null,
        kind: 'email_draft',
        title: 'Email Draft',
      );
    }

    return svc.draftEmail(
      taskTitle: item.title,
      taskDescription: item.description,
      blockedReason: item.blockedReason,
      instruction: instruction,
    );
  }

  Future<OllamaResult> extractTasksFromNote(
    String projectId,
    String rawNote,
  ) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final proj = await (db.select(
      db.projects,
    )..where((t) => t.id.equals(projectId))).getSingleOrNull();

    return svc.extractTasksFromNote(
      rawNote: rawNote,
      projectTitle: proj?.title ?? projectId,
    );
  }

  // ---------------------------------------------------------------------------
  // Extended project lifecycle
  // ---------------------------------------------------------------------------

  Stream<List<ProjectFull>> watchProjectsFull() => db.watchProjectsFull();
  Future<List<ProjectFull>> getProjectsFull() => db.getProjectsFull();
  Future<ProjectFull?> getProjectFull(String id) => db.getProjectFull(id);
  Stream<Map<String, ProjectUpdateAttribution>>
  watchProjectUpdateAttributions() => db.watchProjectUpdateAttributions();
  Future<Map<String, ProjectUpdateAttribution>>
  getProjectUpdateAttributions() => db.getProjectUpdateAttributions();

  Future<void> updateProjectMeta(String id, Map<String, Object?> fields) async {
    await db.updateProjectMeta(id, fields);
    notifyListeners();
  }

  Future<void> softDeleteProject(String id, String reason) async {
    await db.softDeleteProject(id, reason);
    if (_activeProject?.id == id) await db.setActiveProjectId(null);
    notifyListeners();
  }

  Future<List<WorkItem>> getWorkItemsForProject(String projectId) =>
      db.getWorkItemsForProject(projectId);

  Stream<List<Contact>> watchContacts() => db.watchContacts();
  Future<List<Contact>> getContacts() => db.getContacts();

  Future<String> saveContact({
    String? id,
    required String name,
    String? title,
    String? phone,
    String? alternatePhone,
    String? email,
    String? website,
    String? businessName,
    String? notes,
    String? photoPath,
  }) async {
    final contactId = await db.saveContact(
      id: id,
      name: name,
      title: title,
      phone: phone,
      alternatePhone: alternatePhone,
      email: email,
      website: website,
      businessName: businessName,
      notes: notes,
      photoPath: photoPath,
    );
    await db.logEvent(
      area: 'contacts',
      action: id == null ? 'contact_created' : 'contact_updated',
      entityType: 'contact',
      entityId: contactId,
      inputJson: name,
    );
    notifyListeners();
    return contactId;
  }

  Future<void> deleteContact(String id) async {
    await db.deleteContact(id);
    await db.logEvent(
      area: 'contacts',
      action: 'contact_deleted',
      entityType: 'contact',
      entityId: id,
    );
    notifyListeners();
  }

  Future<ContactResponsibilities> getContactResponsibilities(
    Contact contact,
  ) async {
    final projects = await db.getProjectsFull();
    final peopleMatches = <ProjectPerson>[];
    final ownedProjects = <Project>[];
    final contributingProjects = <Project>[];
    for (final project in projects) {
      if (_sameContactLabel(project.owner, contact)) ownedProjects.add(project);
      final people = await db.getProjectPeople(project.id);
      for (final person in people) {
        if (_sameContactLabel(person.name, contact)) {
          peopleMatches.add(person);
          contributingProjects.add(project);
        }
      }
    }
    final tasks = (await db.getAllActiveWorkItems())
        .where((item) => _sameContactLabel(item.owner, contact))
        .toList(growable: false);
    return ContactResponsibilities(
      ownedProjects: ownedProjects,
      contributingProjects: contributingProjects,
      projectPeople: peopleMatches,
      workItems: tasks,
    );
  }

  bool _sameContactLabel(String? value, Contact contact) {
    final raw = value?.trim().toLowerCase();
    if (raw == null || raw.isEmpty) return false;
    return raw == contact.name.trim().toLowerCase() ||
        (contact.email?.trim().toLowerCase().isNotEmpty == true &&
            raw == contact.email!.trim().toLowerCase());
  }

  Future<int> exportContactsToJson(String path) async {
    final contacts = await db.getContacts();
    final payload = {
      'schema': 'project_atlas_contacts_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'contacts': contacts.map(_contactToJson).toList(),
    };
    await File(
      path,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    await db.logEvent(
      area: 'contacts',
      action: 'contacts_exported',
      outputJson: jsonEncode({'path': path, 'count': contacts.length}),
    );
    return contacts.length;
  }

  Future<int> exportContactsToCsv(String path) async {
    final contacts = await db.getContacts();
    final rows = <String>[
      'id,name,title,phone,alternatePhone,email,website,businessName,notes,photoPath',
      ...contacts.map(
        (c) => [
          c.id,
          c.name,
          c.title ?? '',
          c.phone ?? '',
          c.alternatePhone ?? '',
          c.email ?? '',
          c.website ?? '',
          c.businessName ?? '',
          c.notes ?? '',
          c.photoPath ?? '',
        ].map(_csvEscape).join(','),
      ),
    ];
    await File(path).writeAsString(rows.join('\n'));
    await db.logEvent(
      area: 'contacts',
      action: 'contacts_exported_csv',
      outputJson: jsonEncode({'path': path, 'count': contacts.length}),
    );
    return contacts.length;
  }

  Future<int> importContactsFromJson(String path) async {
    final raw = await File(path).readAsString();
    final decoded = jsonDecode(raw);
    final list = decoded is Map<String, dynamic>
        ? decoded['contacts'] as List<dynamic>? ?? const []
        : decoded as List<dynamic>;
    var count = 0;
    for (final entry in list.whereType<Map>()) {
      final map = entry.cast<String, dynamic>();
      final existing = await db.findContactForImport(
        id: map['id']?.toString(),
        email: map['email']?.toString(),
        name: map['name']?.toString(),
      );
      await db.saveContact(
        id: existing?.id ?? map['id']?.toString(),
        name: map['name']?.toString() ?? '',
        title: map['title']?.toString(),
        phone: map['phone']?.toString(),
        alternatePhone: map['alternatePhone']?.toString(),
        email: map['email']?.toString(),
        website: map['website']?.toString(),
        businessName: map['businessName']?.toString(),
        notes: map['notes']?.toString(),
        photoPath: map['photoPath']?.toString(),
      );
      count++;
    }
    await db.logEvent(
      area: 'contacts',
      action: 'contacts_imported',
      outputJson: jsonEncode({'path': path, 'count': count}),
    );
    notifyListeners();
    return count;
  }

  Map<String, Object?> _contactToJson(Contact c) => {
    'id': c.id,
    'name': c.name,
    'title': c.title,
    'phone': c.phone,
    'alternatePhone': c.alternatePhone,
    'email': c.email,
    'website': c.website,
    'businessName': c.businessName,
    'notes': c.notes,
    'photoPath': c.photoPath,
  };

  String _csvEscape(String value) {
    final needsQuotes =
        value.contains(',') || value.contains('"') || value.contains('\n');
    final escaped = value.replaceAll('"', '""');
    return needsQuotes ? '"$escaped"' : escaped;
  }

  // People
  Future<List<ProjectPerson>> getProjectPeople(String projectId) =>
      db.getProjectPeople(projectId);
  Future<void> addProjectPerson(
    String projectId,
    String name,
    String? role,
    String? authority,
  ) async {
    await db.addProjectPerson(projectId, name, role, authority);
    notifyListeners();
  }

  Future<void> updateProjectPerson(
    String personId,
    String name,
    String? role,
    String? authority,
  ) async {
    await db.updateProjectPerson(personId, name, role, authority);
    notifyListeners();
  }

  Future<void> deleteProjectPerson(String personId) async {
    await db.deleteProjectPerson(personId);
    notifyListeners();
  }

  // Risks
  Future<List<ProjectRisk>> getProjectRisks(String projectId) =>
      db.getProjectRisks(projectId);
  Future<void> addProjectRisk(
    String projectId,
    String title,
    String? desc,
    String severity,
  ) async {
    await db.addProjectRisk(projectId, title, desc, severity);
    notifyListeners();
  }

  Future<void> deleteProjectRisk(String riskId) async {
    await db.deleteProjectRisk(riskId);
    notifyListeners();
  }

  // Decisions
  Future<List<ProjectDecision>> getProjectDecisions(String projectId) =>
      db.getProjectDecisions(projectId);
  Future<void> addProjectDecision(
    String projectId,
    String title,
    String? ctx,
    String? decider,
  ) async {
    await db.addProjectDecision(projectId, title, ctx, decider);
    notifyListeners();
  }

  Future<void> deleteProjectDecision(String decisionId) async {
    await db.deleteProjectDecision(decisionId);
    notifyListeners();
  }

  // Tags
  Stream<List<Tag>> watchTags() => db.watchTags();
  Future<List<Tag>> getTags() => db.getTags();
  Stream<List<Tag>> watchTagsForProject(String projectId) =>
      db.watchTagsForProject(projectId);
  Future<List<Tag>> getTagsForProject(String projectId) =>
      db.getTagsForProject(projectId);
  Stream<List<Project>> watchProjectsForTag(String tagId) =>
      db.watchProjectsForTag(tagId);
  Future<List<Project>> getProjectsForTag(String tagId) =>
      db.getProjectsForTag(tagId);
  Future<List<Project>> getProjectsMatchingTags(
    Iterable<String> tagIds, {
    bool matchAll = false,
  }) => db.getProjectsMatchingTags(tagIds, matchAll: matchAll);

  Future<String> saveTag({
    String? id,
    required String name,
    String? color,
  }) async {
    final tagId = await db.saveTag(id: id, name: name, color: color);
    notifyListeners();
    return tagId;
  }

  Future<void> updateTag(String id, {String? name, String? color}) async {
    await db.updateTag(id, name: name, color: color);
    notifyListeners();
  }

  Future<void> deleteTag(String id) async {
    await db.deleteTag(id);
    notifyListeners();
  }

  Future<void> assignTagToProject(String projectId, String tagId) async {
    await db.assignTagToProject(projectId, tagId);
    notifyListeners();
  }

  Future<void> unassignTagFromProject(String projectId, String tagId) async {
    await db.unassignTagFromProject(projectId, tagId);
    notifyListeners();
  }

  Future<void> setProjectTags(String projectId, Iterable<String> tagIds) async {
    await db.setProjectTags(projectId, tagIds);
    notifyListeners();
  }

  Future<List<Tag>> getTagsForWorkItem(String workItemId) =>
      db.getTagsForWorkItem(workItemId);

  Future<Map<String, List<Tag>>> getTagsForWorkItems(
    Iterable<String> workItemIds,
  ) => db.getTagsForWorkItems(workItemIds);

  Future<void> setWorkItemTags(
    String workItemId,
    Iterable<String> tagIds,
  ) async {
    await db.setWorkItemTags(workItemId, tagIds);
    notifyListeners();
  }

  // Project media
  Stream<List<ProjectMediaItem>> watchAllProjectMedia() =>
      db.watchAllProjectMedia();
  Future<List<ProjectMediaItem>> getAllProjectMedia() =>
      db.getAllProjectMedia();
  Stream<List<ProjectMediaItem>> watchProjectMedia(String projectId) =>
      db.watchProjectMedia(projectId);
  Future<List<ProjectMediaItem>> getProjectMedia(String projectId) =>
      db.getProjectMedia(projectId);
  Future<ProjectMediaItem?> getProjectMediaItem(String id) =>
      db.getProjectMediaItem(id);

  Future<String> saveProjectMedia({
    String? id,
    required String projectId,
    required String title,
    required String originalFilename,
    required String storedPath,
    String mediaType = 'file',
    String? mimeType,
    String? extension,
    int? byteSize,
    DateTime? fileModifiedAt,
    String? caption,
    bool isCover = false,
    String? source,
    String? metadataJson,
  }) async {
    final mediaId = await db.saveProjectMedia(
      id: id,
      projectId: projectId,
      title: title,
      originalFilename: originalFilename,
      storedPath: storedPath,
      mediaType: mediaType,
      mimeType: mimeType,
      extension: extension,
      byteSize: byteSize,
      fileModifiedAt: fileModifiedAt,
      caption: caption,
      isCover: isCover,
      source: source,
      metadataJson: metadataJson,
    );
    notifyListeners();
    return mediaId;
  }

  Future<String> importProjectMediaFromPath(
    String projectId,
    String path, {
    String? title,
    String? caption,
    bool isCover = false,
    String? source,
    String? metadataJson,
  }) async {
    final sourceFile = File(path);
    if (!sourceFile.existsSync()) {
      throw FileSystemException('File not found', path);
    }
    final mediaDir = await _projectMediaDirectory(projectId);
    final storedPath = await _copyIntoMediaVault(sourceFile, mediaDir);
    final sourcePayload = source?.trim().isNotEmpty == true
        ? source
        : sourceFile.path;
    final metadataPayload = _mergeMediaMetadata(metadataJson, {
      'originalPath': sourceFile.path,
    });
    final mediaId = await db.importProjectMediaFromPath(
      projectId,
      storedPath,
      title: title,
      caption: caption,
      isCover: isCover,
      source: sourcePayload,
      metadataJson: metadataPayload,
    );
    notifyListeners();
    return mediaId;
  }

  Future<void> updateProjectMedia(
    String id, {
    String? title,
    String? caption,
    bool? isCover,
    String? source,
    String? metadataJson,
  }) async {
    await db.updateProjectMedia(
      id,
      title: title,
      caption: caption,
      isCover: isCover,
      source: source,
      metadataJson: metadataJson,
    );
    notifyListeners();
  }

  Future<void> setProjectCoverMedia(String projectId, String mediaId) async {
    await db.setProjectCoverMedia(projectId, mediaId);
    notifyListeners();
  }

  Future<void> deleteProjectMedia(String id) async {
    await db.deleteProjectMedia(id);
    notifyListeners();
  }

  Stream<List<ProjectMediaItem>> watchMediaForWorkItem(String workItemId) =>
      db.watchProjectMediaForEntity(
        entityType: 'work_item',
        entityId: workItemId,
      );

  Future<List<ProjectMediaItem>> getMediaForWorkItem(String workItemId) => db
      .getProjectMediaForEntity(entityType: 'work_item', entityId: workItemId);

  Stream<List<ProjectMediaItem>> watchMediaForLlmTask(String taskId) =>
      db.watchProjectMediaForEntity(entityType: 'llm_task', entityId: taskId);

  Future<List<ProjectMediaItem>> getMediaForLlmTask(String taskId) =>
      db.getProjectMediaForEntity(entityType: 'llm_task', entityId: taskId);

  Future<void> attachProjectMediaToWorkItem(
    String workItemId,
    String mediaId,
  ) async {
    final project = await db.getProjectForWorkItem(workItemId);
    final media = await db.getProjectMediaItem(mediaId);
    if (project == null) throw StateError('Work item not found: $workItemId');
    if (media == null) throw StateError('Media not found: $mediaId');
    if (media.projectId != project.id) {
      throw StateError('Media belongs to a different project: $mediaId');
    }
    await db.linkProjectMediaToEntity(
      mediaId: mediaId,
      entityType: 'work_item',
      entityId: workItemId,
    );
    notifyListeners();
  }

  Future<String> importWorkItemMediaFromPath(
    String workItemId,
    String path, {
    String? title,
    String? caption,
  }) async {
    final project = await db.getProjectForWorkItem(workItemId);
    if (project == null) throw StateError('Work item not found: $workItemId');
    final mediaId = await importProjectMediaFromPath(
      project.id,
      path,
      title: title,
      caption: caption,
      source: path,
      metadataJson: jsonEncode({'entityType': 'work_item'}),
    );
    await attachProjectMediaToWorkItem(workItemId, mediaId);
    return mediaId;
  }

  Future<void> unlinkProjectMediaFromWorkItem(
    String workItemId,
    String mediaId,
  ) async {
    await db.unlinkProjectMediaFromEntity(
      mediaId: mediaId,
      entityType: 'work_item',
      entityId: workItemId,
    );
    notifyListeners();
  }

  Future<void> attachProjectMediaToLlmTask(
    String taskId,
    String mediaId,
  ) async {
    final task = await db.getLlmTask(taskId);
    final media = await db.getProjectMediaItem(mediaId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    if (media == null) throw StateError('Media not found: $mediaId');
    if (media.projectId != task.projectId) {
      throw StateError('Media belongs to a different project: $mediaId');
    }
    await db.linkProjectMediaToEntity(
      mediaId: mediaId,
      entityType: 'llm_task',
      entityId: taskId,
    );
    notifyListeners();
  }

  Future<String> importLlmTaskMediaFromPath(
    String taskId,
    String path, {
    String? title,
    String? caption,
  }) async {
    final task = await db.getLlmTask(taskId);
    if (task == null) throw StateError('LLM task not found: $taskId');
    final mediaId = await importProjectMediaFromPath(
      task.projectId,
      path,
      title: title,
      caption: caption,
      source: path,
      metadataJson: jsonEncode({'entityType': 'llm_task'}),
    );
    await attachProjectMediaToLlmTask(taskId, mediaId);
    return mediaId;
  }

  Future<void> unlinkProjectMediaFromLlmTask(
    String taskId,
    String mediaId,
  ) async {
    await db.unlinkProjectMediaFromEntity(
      mediaId: mediaId,
      entityType: 'llm_task',
      entityId: taskId,
    );
    notifyListeners();
  }

  Future<void> deleteDocument(String id) async {
    await db.deleteDocument(id);
    notifyListeners();
  }

  Future<Directory> _projectMediaDirectory(String projectId) async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'project_media', projectId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _copyIntoMediaVault(File source, Directory dir) async {
    final basename = p.basename(source.path);
    final ext = p.extension(basename);
    final stem = p.basenameWithoutExtension(basename);
    var candidate = p.join(dir.path, basename);
    var index = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(dir.path, '${stem}_$index$ext');
      index++;
    }
    final copied = await source.copy(candidate);
    return copied.path;
  }

  String? _mergeMediaMetadata(String? rawJson, Map<String, Object?> extra) {
    final base = <String, Object?>{};
    if (rawJson != null && rawJson.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawJson);
        if (decoded is Map<String, dynamic>) {
          base.addAll(decoded);
        }
      } catch (_) {
        base['raw'] = rawJson;
      }
    }
    base.addAll(extra);
    return jsonEncode(base);
  }

  // Documents for project
  Stream<List<Document>> watchDocumentsForProject(String projectId) =>
      db.watchDocumentsForProject(projectId);

  // ── Project summary cache ───────────────────────────────────────────────

  // ---------------------------------------------------------------------------
  // Local Operations Registry
  // ---------------------------------------------------------------------------

  Stream<List<ProjectEnrichmentRun>> watchProjectEnrichmentRuns({
    int limit = 50,
  }) => db.watchProjectEnrichmentRuns(limit: limit);

  Future<List<ProjectEnrichmentRun>> getProjectEnrichmentRuns({
    int limit = 50,
  }) => db.getProjectEnrichmentRuns(limit: limit);

  Future<ProjectEnrichmentRun?> getProjectEnrichmentRun(String id) =>
      db.getProjectEnrichmentRun(id);

  Future<List<ProjectEnrichmentFinding>> getProjectEnrichmentFindingsForRun(
    String runId,
  ) => db.getProjectEnrichmentFindingsForRun(runId);

  Future<List<ProjectEnrichmentStep>> getProjectEnrichmentStepsForRun(
    String runId,
  ) => db.getProjectEnrichmentStepsForRun(runId);

  Future<List<ProjectEnrichmentProposal>> getProjectEnrichmentProposalsForRun(
    String runId,
  ) => db.getProjectEnrichmentProposalsForRun(runId);

  Stream<List<ProjectEnrichmentFinding>> watchProjectEnrichmentFindingsForRun(
    String runId,
  ) => db.watchProjectEnrichmentFindingsForRun(runId);

  Stream<List<ProjectEnrichmentStep>> watchProjectEnrichmentStepsForRun(
    String runId,
  ) => db.watchProjectEnrichmentStepsForRun(runId);

  Stream<List<ProjectEnrichmentProposal>> watchProjectEnrichmentProposalsForRun(
    String runId,
  ) => db.watchProjectEnrichmentProposalsForRun(runId);

  Future<List<ProjectEnrichmentFinding>> getOpenProjectEnrichmentFindings({
    String? projectId,
    int limit = 100,
  }) => db.getOpenProjectEnrichmentFindings(projectId: projectId, limit: limit);

  void _setProjectEnrichmentStatus(
    String status, {
    int? current,
    int? total,
    bool resetProgress = false,
  }) {
    _projectEnrichmentStatus = status;
    if (resetProgress) {
      _projectEnrichmentProgressCurrent = null;
      _projectEnrichmentProgressTotal = null;
    } else {
      if (current != null) _projectEnrichmentProgressCurrent = current;
      if (total != null) _projectEnrichmentProgressTotal = total;
    }
    notifyListeners();
  }

  Future<String> _startEnrichmentStep(
    String runId, {
    required String worker,
    required String title,
  }) {
    _setProjectEnrichmentStatus('$title...', resetProgress: true);
    return db.startProjectEnrichmentStep(
      runId: runId,
      worker: worker,
      title: title,
      startedAt: DateTime.now(),
    );
  }

  Future<void> _finishEnrichmentStep(
    String stepId, {
    required String status,
    int considered = 0,
    int createdItems = 0,
    int updatedItems = 0,
    int skippedItems = 0,
    int failedItems = 0,
    int findings = 0,
    int proposals = 0,
    List<String> warnings = const [],
    Map<String, Object?> output = const {},
  }) {
    return db.finishProjectEnrichmentStep(
      id: stepId,
      completedAt: DateTime.now(),
      status: status,
      considered: considered,
      createdItems: createdItems,
      updatedItems: updatedItems,
      skippedItems: skippedItems,
      failedItems: failedItems,
      findings: findings,
      proposals: proposals,
      warningsJson: jsonEncode(warnings),
      outputJson: jsonEncode(output),
    );
  }

  Future<void> _addEnrichmentProposal({
    required String runId,
    String? projectId,
    String? registryId,
    required String worker,
    required String proposalType,
    required String title,
    String? detail,
    required Map<String, Object?> payload,
    int confidence = 70,
  }) async {
    final now = DateTime.now();
    final raw = [
      runId,
      worker,
      proposalType,
      projectId,
      registryId,
      title,
    ].whereType<String>().join('__');
    await db.addProjectEnrichmentProposal(
      id: 'proposal_${now.microsecondsSinceEpoch}_${raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}',
      runId: runId,
      projectId: projectId,
      registryId: registryId,
      worker: worker,
      proposalType: proposalType,
      title: title,
      detail: detail,
      payloadJson: jsonEncode(payload),
      confidence: confidence,
      createdAt: now,
    );
  }

  Future<int> _createCorrectionProposalsForFindings(
    String runId,
    List<_ProjectEnrichmentFindingDraft> findings,
  ) async {
    var created = 0;
    for (final finding in findings) {
      if (created >= _projectEnrichmentProposalCap) break;
      await _addEnrichmentProposal(
        runId: runId,
        projectId: finding.projectId,
        registryId: finding.registryId,
        worker: 'correction',
        proposalType: _proposalTypeForFinding(finding),
        title: 'Resolve: ${finding.title}',
        detail: finding.detail,
        payload: {
          'schema': 'project_atlas_enrichment_correction_v1',
          'finding': {
            'severity': finding.severity,
            'category': finding.category,
            'title': finding.title,
            'detail': finding.detail,
            'evidence': finding.evidence,
          },
          'recommendedAction': _recommendedActionForFinding(finding),
          'writeBoundary': 'atlas_only',
          'sourceReposMutated': false,
        },
        confidence: _proposalConfidenceForFinding(finding),
      );
      created++;
    }
    return created;
  }

  String _proposalTypeForFinding(_ProjectEnrichmentFindingDraft finding) {
    return switch (finding.category) {
      'registry' => 'registry_review',
      'library' => 'library_import_review',
      'media' => 'media_import_review',
      'identity' => 'identity_update',
      'people' => 'people_role_update',
      'workboard' => 'task_update',
      'governance' => 'governance_update',
      'repository' => 'repository_metadata_review',
      'ai_summary' => 'summary_refresh',
      _ => 'enrichment_follow_up',
    };
  }

  String _recommendedActionForFinding(_ProjectEnrichmentFindingDraft finding) {
    return switch (finding.category) {
      'registry' =>
        'Link, import, merge, or ignore the local registry entry in Operations.',
      'library' =>
        'Refresh linked project documents/cards/source files or review import exclusions.',
      'media' =>
        'Attach project media or confirm that this project intentionally has none.',
      'identity' =>
        'Review project identity fields such as description, tags, type, phase, and priority.',
      'people' =>
        'Add owner or people/role assignments, or mark the project as unassigned.',
      'workboard' =>
        'Create or import project tasks, or mark the project as intentionally taskless.',
      'governance' =>
        'Add risks/issues or decision-log entries, or confirm no governance record is needed.',
      'repository' =>
        'Refresh local/GitHub repository metadata or mark the project local-only.',
      'ai_summary' =>
        'Refresh the AI summary when Ollama is available, or keep the unavailable finding.',
      _ => 'Review and resolve this enrichment finding.',
    };
  }

  int _proposalConfidenceForFinding(_ProjectEnrichmentFindingDraft finding) {
    return switch (finding.severity) {
      'error' => 85,
      'warning' => 75,
      _ => 60,
    };
  }

  Future<_ProjectIdentityEnrichmentResult> _refreshProjectIdentityRecords(
    List<ProjectRegistryEntry> registry, {
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
    ProjectEnrichmentStatusCallback? onStatus,
  }) async {
    final linked = registry
        .where(
          (entry) =>
              entry.reviewState != 'ignored' &&
              (entry.atlasProjectId ?? '').trim().isNotEmpty,
        )
        .toList(growable: false);
    var considered = 0;
    var updated = 0;
    var unchanged = 0;
    var skipped = 0;
    final warnings = <String>[];

    for (final entry in linked) {
      considered++;
      final projectId = entry.atlasProjectId!.trim();
      onStatus?.call(
        'Updating identity for ${entry.displayName} ($considered/${linked.length}).',
        current: considered,
        total: linked.length,
      );
      final project = await db.getProjectFull(projectId);
      if (project == null) {
        skipped++;
        warnings.add('${entry.displayName}: linked Atlas project is missing.');
        continue;
      }
      try {
        final plan = await service.buildPlan(entry.localPath);
        warnings.addAll(
          plan.warnings.map((warning) => '${entry.displayName}: $warning'),
        );
        final projectActions = plan.actions
            .where((action) => action.targetType == 'project')
            .toList(growable: false);
        var changed = false;
        if (projectActions.isEmpty) {
          changed = await _applyProjectIdentityTags(
            projectId: projectId,
            entry: entry,
            planProfile: plan.profile,
          );
        } else {
          for (final action in projectActions) {
            changed =
                await _applyProjectIdentityAction(
                  projectId: projectId,
                  entry: entry,
                  action: action,
                  planProfile: plan.profile,
                ) ||
                changed;
          }
        }
        if (changed) {
          updated++;
        } else {
          unchanged++;
        }
      } catch (error) {
        skipped++;
        warnings.add('${entry.displayName}: identity update failed: $error');
      }
    }

    return _ProjectIdentityEnrichmentResult(
      considered: considered,
      updated: updated,
      unchanged: unchanged,
      skipped: skipped,
      warnings: List.unmodifiable(warnings),
    );
  }

  Future<bool> _applyProjectIdentityAction({
    required String projectId,
    required ProjectRegistryEntry entry,
    required LocalProjectRefreshAction action,
    required String planProfile,
  }) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) return false;
    final fields = <String, Object?>{};

    void maybeSet(String key, String? current) {
      final value = _payloadCleanString(action.payload, key);
      if (value == null || value == current?.trim()) return;
      fields[key] = value;
    }

    maybeSet('title', project.title);
    maybeSet('description', project.description);
    maybeSet('desiredOutcome', project.desiredOutcome);
    maybeSet('successCriteria', project.successCriteria);
    maybeSet('phase', project.phase);
    maybeSet('priority', project.priority);
    maybeSet('scopeIncluded', project.scopeIncluded);
    maybeSet('scopeExcluded', project.scopeExcluded);
    maybeSet('outcomeSummary', project.outcomeSummary);
    maybeSet('lessonsLearned', project.lessonsLearned);

    var changed = false;
    if (fields.isNotEmpty) {
      await db.updateProjectMeta(projectId, fields);
      changed = true;
    }
    changed =
        await _applyProjectIdentityTags(
          projectId: projectId,
          entry: entry,
          planProfile: planProfile,
          payload: action.payload,
        ) ||
        changed;
    return changed;
  }

  Future<bool> _applyProjectIdentityTags({
    required String projectId,
    required ProjectRegistryEntry entry,
    required String planProfile,
    Map<String, Object?> payload = const {},
  }) async {
    final manifestType = _payloadCleanString(payload, 'manifestType');
    final manifestGroup = _payloadCleanString(payload, 'manifestGroup');
    final tags = <String>[
      ..._payloadStringList(payload, 'manifestTags'),
      ?manifestType,
      ?manifestGroup,
      entry.classification,
      if (planProfile.trim().isNotEmpty && planProfile != 'unknown')
        planProfile,
    ];
    final observation = await db.getLatestProjectObservationForPath(
      entry.localPath,
    );
    final remoteUrl = observation?.remoteUrl?.trim();
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      tags.add(
        remoteUrl.toLowerCase().contains('github.com') ? 'github' : 'git',
      );
    } else {
      tags.add('local-only');
    }
    if ((observation?.dirtyCount ?? 0) > 0) {
      tags.add('needs-update');
    }
    return _assignProjectTagsByName(projectId, tags);
  }

  Future<bool> _assignProjectTagsByName(
    String projectId,
    Iterable<String> names,
  ) async {
    final existing = await db.getTagsForProject(projectId);
    final assignedNames = existing
        .map((tag) => tag.name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    var changed = false;
    final uniqueNames = <String, String>{};
    for (final rawName in names) {
      final name = _normalizeIdentityTagName(rawName);
      if (name == null) continue;
      uniqueNames.putIfAbsent(name.toLowerCase(), () => name);
    }
    for (final entry in uniqueNames.entries) {
      if (assignedNames.contains(entry.key)) continue;
      final tag = await db.findTagByName(entry.value);
      final tagId = tag?.id ?? await db.saveTag(name: entry.value);
      await db.assignTagToProject(projectId, tagId);
      assignedNames.add(entry.key);
      changed = true;
    }
    return changed;
  }

  String? _normalizeIdentityTagName(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  String? _payloadCleanString(Map<String, Object?> payload, String key) =>
      _normalizeIdentityTagName(payload[key]);

  List<String> _payloadStringList(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is Iterable) {
      return value
          .map(_normalizeIdentityTagName)
          .whereType<String>()
          .toList(growable: false);
    }
    final single = _normalizeIdentityTagName(value);
    return single == null ? const [] : [single];
  }

  Future<ProjectEnrichmentRunResult> runProjectEnrichment({
    bool refreshLinkedProjects = true,
    bool includeSourceDocuments = true,
    bool refreshSummaries = true,
    bool forceSummaries = false,
    bool includeLibraryInSummaries = true,
    Duration betweenProjects = Duration.zero,
  }) async {
    if (_projectEnrichmentRunning) {
      throw StateError('Project enrichment run is already running.');
    }
    final startedAt = DateTime.now();
    _projectEnrichmentRunning = true;
    _projectEnrichmentStartedAt = startedAt;
    _projectEnrichmentStatus = 'Starting enrichment run.';
    _projectEnrichmentProgressCurrent = null;
    _projectEnrichmentProgressTotal = null;
    notifyListeners();

    final scope = {
      'schema': 'project_atlas_enrichment_run_v1',
      'refreshLinkedProjects': refreshLinkedProjects,
      'includeSourceDocuments': includeSourceDocuments,
      'refreshSummaries': refreshSummaries,
      'forceSummaries': forceSummaries,
      'includeLibraryInSummaries': includeLibraryInSummaries,
      'writeBoundary': 'atlas_only',
      'sourceReposMutated': false,
    };
    _setProjectEnrichmentStatus('Recording enrichment run.');
    late final String runId;
    try {
      runId = await db.startProjectEnrichmentRun(
        startedAt: startedAt,
        scopeJson: jsonEncode(scope),
      );
    } catch (_) {
      _projectEnrichmentRunning = false;
      _projectEnrichmentStatus = null;
      _projectEnrichmentStartedAt = null;
      _projectEnrichmentProgressCurrent = null;
      _projectEnrichmentProgressTotal = null;
      notifyListeners();
      rethrow;
    }

    LocalProjectBatchRefreshResult? refreshResult;
    ProjectSummaryRefreshResult? summaryResult;
    var registryEntries = 0;
    var linkedProjects = 0;
    var refreshedProjects = 0;
    var createdItems = 0;
    var updatedItems = 0;
    var unchangedItems = 0;
    var skippedItems = 0;
    var failedProjects = 0;
    var identityConsidered = 0;
    var identityUpdated = 0;
    var identityUnchanged = 0;
    var identitySkipped = 0;
    var summaryConsidered = 0;
    var summaryRefreshed = 0;
    var summarySkipped = 0;
    var summaryFailed = 0;
    final warnings = <String>[];
    var savedFindings = const <ProjectEnrichmentFinding>[];
    var savedSteps = const <ProjectEnrichmentStep>[];
    var savedProposals = const <ProjectEnrichmentProposal>[];
    String? activeStepId;
    String? activeWorker;

    Future<String> startTrackedStep({
      required String worker,
      required String title,
    }) async {
      activeWorker = worker;
      activeStepId = await _startEnrichmentStep(
        runId,
        worker: worker,
        title: title,
      );
      return activeStepId!;
    }

    Future<void> finishTrackedStep(
      String stepId, {
      required String status,
      int considered = 0,
      int createdItems = 0,
      int updatedItems = 0,
      int skippedItems = 0,
      int failedItems = 0,
      int findings = 0,
      int proposals = 0,
      List<String> warnings = const [],
      Map<String, Object?> output = const {},
    }) async {
      await _finishEnrichmentStep(
        stepId,
        status: status,
        considered: considered,
        createdItems: createdItems,
        updatedItems: updatedItems,
        skippedItems: skippedItems,
        failedItems: failedItems,
        findings: findings,
        proposals: proposals,
        warnings: warnings,
        output: output,
      );
      if (activeStepId == stepId) {
        activeStepId = null;
        activeWorker = null;
      }
    }

    try {
      final registryStepId = await startTrackedStep(
        worker: 'registry',
        title: 'Registry agent: read local project registry',
      );
      final registryBefore = await db.getProjectRegistry();
      registryEntries = registryBefore.length;
      linkedProjects = registryBefore
          .where((entry) => (entry.atlasProjectId ?? '').isNotEmpty)
          .length;
      await finishTrackedStep(
        registryStepId,
        status: 'completed',
        considered: registryEntries,
        output: {
          'registryEntries': registryEntries,
          'linkedProjects': linkedProjects,
          'unlinkedRegistryEntries': registryBefore
              .where(
                (entry) =>
                    entry.reviewState != 'ignored' &&
                    (entry.atlasProjectId ?? '').isEmpty,
              )
              .length,
        },
      );

      if (refreshLinkedProjects) {
        final refreshStepId = await startTrackedStep(
          worker: 'documents_media',
          title:
              'Documents/media agent: refresh linked project library records',
        );
        refreshResult = await refreshLinkedLocalProjects(
          includeSourceDocuments: includeSourceDocuments,
          betweenProjects: betweenProjects,
          onStatus: _setProjectEnrichmentStatus,
        );
        refreshedProjects = refreshResult.refreshed;
        createdItems = refreshResult.created;
        updatedItems = refreshResult.updated;
        unchangedItems = refreshResult.unchanged;
        skippedItems = refreshResult.skipped;
        failedProjects = refreshResult.failed;
        warnings.addAll(refreshResult.warnings);
        if (refreshResult.alreadyRunning) {
          warnings.add('Linked project refresh was already running.');
        }
        await finishTrackedStep(
          refreshStepId,
          status: failedProjects > 0 ? 'completed_with_errors' : 'completed',
          considered: refreshResult.considered,
          createdItems: refreshResult.created,
          updatedItems: refreshResult.updated,
          skippedItems: refreshResult.skipped + refreshResult.unchanged,
          failedItems: refreshResult.failed,
          warnings: refreshResult.warnings,
          output: {
            'refreshed': refreshResult.refreshed,
            'includeSourceDocuments': includeSourceDocuments,
            'alreadyRunning': refreshResult.alreadyRunning,
          },
        );
        _setProjectEnrichmentStatus(
          'Linked refresh complete: $createdItems created, $updatedItems updated, $failedProjects failed.',
        );
      } else {
        final refreshStepId = await startTrackedStep(
          worker: 'documents_media',
          title: 'Documents/media agent: skipped by run scope',
        );
        await finishTrackedStep(
          refreshStepId,
          status: 'skipped',
          output: {'reason': 'refreshLinkedProjects=false'},
        );
      }

      final identityStepId = await startTrackedStep(
        worker: 'identity',
        title: 'Identity agent: apply deterministic project metadata and tags',
      );
      final identityResult = await _refreshProjectIdentityRecords(
        await db.getProjectRegistry(),
        onStatus: _setProjectEnrichmentStatus,
      );
      identityConsidered = identityResult.considered;
      identityUpdated = identityResult.updated;
      identityUnchanged = identityResult.unchanged;
      identitySkipped = identityResult.skipped;
      updatedItems += identityUpdated;
      unchangedItems += identityUnchanged;
      skippedItems += identitySkipped;
      warnings.addAll(identityResult.warnings);
      await finishTrackedStep(
        identityStepId,
        status: identityResult.skipped > 0
            ? 'completed_with_warnings'
            : 'completed',
        considered: identityResult.considered,
        updatedItems: identityResult.updated,
        skippedItems: identityResult.unchanged + identityResult.skipped,
        failedItems: identityResult.skipped,
        warnings: identityResult.warnings,
        output: {
          'autoApplied': true,
          'updatedProjects': identityResult.updated,
          'unchangedProjects': identityResult.unchanged,
          'skippedProjects': identityResult.skipped,
          'sources': [
            '.project/launchpad.json',
            'CURRENT_STATE.md',
            'README.md',
            'local git observation',
          ],
        },
      );
      _setProjectEnrichmentStatus(
        'Identity update complete: ${identityResult.updated} updated, ${identityResult.unchanged} unchanged.',
      );

      if (refreshSummaries) {
        final summaryStepId = await startTrackedStep(
          worker: 'summary',
          title: 'Summary agent: refresh AI summaries when available',
        );
        summaryResult = await refreshMissingProjectSummaries(
          force: forceSummaries,
          includeLibrary: includeLibraryInSummaries,
          betweenProjects: Duration.zero,
          onStatus: _setProjectEnrichmentStatus,
        );
        summaryConsidered = summaryResult.considered;
        summaryRefreshed = summaryResult.refreshed;
        summarySkipped = summaryResult.skipped;
        summaryFailed = summaryResult.failed;
        warnings.addAll(summaryResult.errors);
        if (summaryResult.aiUnavailable) {
          warnings.add(
            'AI summary refresh skipped because Ollama is unavailable.',
          );
        }
        if (summaryResult.alreadyRunning) {
          warnings.add('AI summary refresh was already running.');
        }
        await finishTrackedStep(
          summaryStepId,
          status: summaryFailed > 0
              ? 'completed_with_errors'
              : summaryResult.aiUnavailable || summaryResult.alreadyRunning
              ? 'skipped'
              : 'completed',
          considered: summaryConsidered,
          createdItems: summaryRefreshed,
          skippedItems: summarySkipped,
          failedItems: summaryFailed,
          warnings: summaryResult.errors,
          output: {
            'aiUnavailable': summaryResult.aiUnavailable,
            'alreadyRunning': summaryResult.alreadyRunning,
            'includeLibrary': includeLibraryInSummaries,
          },
        );
        _setProjectEnrichmentStatus(
          'AI summaries complete: $summaryRefreshed refreshed, $summaryFailed failed, $summarySkipped skipped.',
        );
      } else {
        final summaryStepId = await startTrackedStep(
          worker: 'summary',
          title: 'Summary agent: skipped by run scope',
        );
        await finishTrackedStep(
          summaryStepId,
          status: 'skipped',
          output: {'reason': 'refreshSummaries=false'},
        );
      }

      final verificationStepId = await startTrackedStep(
        worker: 'verification',
        title: 'Verification agent: audit project completeness',
      );
      final registry = await db.getProjectRegistry();
      registryEntries = registry.length;
      linkedProjects = registry
          .where((entry) => (entry.atlasProjectId ?? '').isNotEmpty)
          .length;
      final projects = await db.getVisibleProjects();
      final audit = await _buildProjectEnrichmentAudit(
        registry: registry,
        projects: projects,
        refreshSummaries: refreshSummaries,
        summaryResult: summaryResult,
      );
      await finishTrackedStep(
        verificationStepId,
        status: audit.findings.isEmpty
            ? 'completed'
            : 'completed_with_findings',
        considered: projects.length,
        findings: audit.findings.length,
        output: audit.coverage,
      );

      _setProjectEnrichmentStatus(
        'Saving ${audit.findings.length} enrichment findings.',
      );
      for (var i = 0; i < audit.findings.length; i++) {
        final finding = audit.findings[i];
        await db.addProjectEnrichmentFinding(
          id: 'finding_${runId}_$i',
          runId: runId,
          projectId: finding.projectId,
          registryId: finding.registryId,
          severity: finding.severity,
          category: finding.category,
          title: finding.title,
          detail: finding.detail,
          evidenceJson: jsonEncode(finding.evidence),
          createdAt: DateTime.now(),
        );
      }
      savedFindings = await db.getProjectEnrichmentFindingsForRun(runId);
      final correctionStepId = await startTrackedStep(
        worker: 'correction',
        title: 'Correction agent: draft reviewable follow-up proposals',
      );
      final proposalCount = await _createCorrectionProposalsForFindings(
        runId,
        audit.findings,
      );
      savedProposals = await db.getProjectEnrichmentProposalsForRun(runId);
      await finishTrackedStep(
        correctionStepId,
        status: proposalCount == 0 ? 'completed' : 'completed_with_proposals',
        considered: audit.findings.length,
        proposals: proposalCount,
        output: {
          'policy': 'proposal_only',
          'autoApplied': false,
          'proposalCap': _projectEnrichmentProposalCap,
        },
      );
      savedSteps = await db.getProjectEnrichmentStepsForRun(runId);
      final openFindings = savedFindings
          .where((finding) => finding.status == 'open')
          .length;
      final status = failedProjects > 0 || summaryFailed > 0
          ? 'completed_with_errors'
          : openFindings > 0 || warnings.isNotEmpty
          ? 'completed_with_findings'
          : 'completed';
      final output = {
        'coverage': audit.coverage,
        'refresh': refreshResult == null
            ? null
            : {
                'considered': refreshResult.considered,
                'refreshed': refreshResult.refreshed,
                'created': refreshResult.created,
                'updated': refreshResult.updated,
                'unchanged': refreshResult.unchanged,
                'skipped': refreshResult.skipped,
                'failed': refreshResult.failed,
                'alreadyRunning': refreshResult.alreadyRunning,
              },
        'summary': summaryResult == null
            ? null
            : {
                'considered': summaryResult.considered,
                'refreshed': summaryResult.refreshed,
                'skipped': summaryResult.skipped,
                'failed': summaryResult.failed,
                'aiUnavailable': summaryResult.aiUnavailable,
                'alreadyRunning': summaryResult.alreadyRunning,
              },
        'identity': {
          'considered': identityConsidered,
          'updated': identityUpdated,
          'unchanged': identityUnchanged,
          'skipped': identitySkipped,
        },
        'workers': savedSteps.map((step) => step.toJson()).toList(),
        'proposals': {
          'count': savedProposals.length,
          'policy': 'proposal_only',
          'autoApplied': false,
        },
      };
      _setProjectEnrichmentStatus('Finalizing enrichment run.');
      await db.finishProjectEnrichmentRun(
        id: runId,
        completedAt: DateTime.now(),
        status: status,
        registryEntries: registryEntries,
        linkedProjects: linkedProjects,
        refreshedProjects: refreshedProjects,
        createdItems: createdItems,
        updatedItems: updatedItems,
        unchangedItems: unchangedItems,
        skippedItems: skippedItems,
        failedProjects: failedProjects,
        // Identity updates are counted in updated/unchanged/skipped item totals.
        summaryConsidered: summaryConsidered,
        summaryRefreshed: summaryRefreshed,
        summarySkipped: summarySkipped,
        summaryFailed: summaryFailed,
        findings: savedFindings.length,
        openFindings: openFindings,
        warningsJson: jsonEncode(warnings),
        outputJson: jsonEncode(output),
      );
      await db.logEvent(
        area: 'operations',
        action: 'project_enrichment_completed',
        entityType: 'project_enrichment_run',
        entityId: runId,
        outputJson: jsonEncode({
          'status': status,
          'registryEntries': registryEntries,
          'linkedProjects': linkedProjects,
          'findings': savedFindings.length,
          'openFindings': openFindings,
        }),
      );
      final run = await db.getProjectEnrichmentRun(runId);
      if (run == null) {
        throw StateError('Project enrichment run was not saved: $runId');
      }
      return ProjectEnrichmentRunResult(
        run: run,
        findings: savedFindings,
        steps: savedSteps,
        proposals: savedProposals,
      );
    } catch (error, stackTrace) {
      _setProjectEnrichmentStatus('Enrichment failed: $error');
      warnings.add(error.toString());
      final failedAt = DateTime.now();
      final failedWorker = activeWorker;
      final activeFailure = activeStepId != null || activeWorker != null;
      final failedRunOutput = <String, Object?>{'error': error.toString()};
      if (failedWorker != null) {
        failedRunOutput['worker'] = failedWorker;
      }
      if (activeFailure) {
        try {
          await db.failRunningProjectEnrichmentStepsForRun(
            runId: runId,
            completedAt: failedAt,
            warningsJson: jsonEncode([error.toString()]),
            outputJson: jsonEncode(failedRunOutput),
          );
          await db.addProjectEnrichmentFinding(
            id: 'finding_${runId}_error_${failedAt.microsecondsSinceEpoch}',
            runId: runId,
            severity: 'error',
            category: failedWorker ?? 'enrichment',
            title: 'Enrichment worker failed before completing.',
            detail: error.toString(),
            evidenceJson: jsonEncode(failedRunOutput),
            createdAt: failedAt,
          );
          savedFindings = await db.getProjectEnrichmentFindingsForRun(runId);
          activeStepId = null;
          activeWorker = null;
        } catch (cleanupError, cleanupStackTrace) {
          await db.logError(
            area: 'operations',
            action: 'project_enrichment_failure_cleanup_failed',
            error: cleanupError,
            stackTrace: cleanupStackTrace,
            entityType: 'project_enrichment_run',
            entityId: runId,
          );
        }
      }
      await db.finishProjectEnrichmentRun(
        id: runId,
        completedAt: failedAt,
        status: 'failed',
        registryEntries: registryEntries,
        linkedProjects: linkedProjects,
        refreshedProjects: refreshedProjects,
        createdItems: createdItems,
        updatedItems: updatedItems,
        unchangedItems: unchangedItems,
        skippedItems: skippedItems,
        failedProjects: failedProjects,
        summaryConsidered: summaryConsidered,
        summaryRefreshed: summaryRefreshed,
        summarySkipped: summarySkipped,
        summaryFailed: summaryFailed,
        findings: savedFindings.length,
        openFindings: savedFindings
            .where((finding) => finding.status == 'open')
            .length,
        warningsJson: jsonEncode(warnings),
        outputJson: jsonEncode(failedRunOutput),
      );
      await db.logError(
        area: 'operations',
        action: 'project_enrichment_failed',
        error: error,
        stackTrace: stackTrace,
        entityType: 'project_enrichment_run',
        entityId: runId,
      );
      rethrow;
    } finally {
      _projectEnrichmentRunning = false;
      _projectEnrichmentStatus = null;
      _projectEnrichmentStartedAt = null;
      _projectEnrichmentProgressCurrent = null;
      _projectEnrichmentProgressTotal = null;
      notifyListeners();
    }
  }

  Future<_ProjectEnrichmentAudit> _buildProjectEnrichmentAudit({
    required List<ProjectRegistryEntry> registry,
    required List<Project> projects,
    required bool refreshSummaries,
    ProjectSummaryRefreshResult? summaryResult,
  }) async {
    final findings = <_ProjectEnrichmentFindingDraft>[];
    final registryByProjectId = <String, ProjectRegistryEntry>{};
    final registryEntriesByProjectId = <String, List<ProjectRegistryEntry>>{};
    for (final entry in registry) {
      final linkedProjectId = entry.atlasProjectId?.trim();
      if (linkedProjectId == null || linkedProjectId.isEmpty) continue;
      registryEntriesByProjectId
          .putIfAbsent(linkedProjectId, () => <ProjectRegistryEntry>[])
          .add(entry);
      registryByProjectId.putIfAbsent(linkedProjectId, () => entry);
    }
    final projectsById = <String, Project>{
      for (final project in projects) project.id: project,
    };
    final projectIds = projects.map((project) => project.id).toSet();
    var documents = 0;
    var media = 0;
    var sourceFiles = 0;
    var cards = 0;
    var projectsWithDocs = 0;
    var projectsWithMedia = 0;
    var projectsWithSourceFiles = 0;
    var projectsWithCards = 0;
    var projectsWithPeople = 0;
    var projectsWithTags = 0;
    var projectsWithTasks = 0;
    var projectsWithRisks = 0;
    var projectsWithDecisions = 0;
    var projectsWithSummaries = 0;
    var projectsWithGithubCache = 0;

    void addFinding({
      Project? project,
      ProjectRegistryEntry? registryEntry,
      required String severity,
      required String category,
      required String title,
      String? detail,
      Map<String, Object?> evidence = const {},
    }) {
      findings.add(
        _ProjectEnrichmentFindingDraft(
          projectId: project?.id,
          registryId: registryEntry?.id,
          severity: severity,
          category: category,
          title: title,
          detail: detail,
          evidence: {
            if (project != null) 'projectTitle': project.title,
            if (registryEntry != null) ...{
              'registryDisplayName': registryEntry.displayName,
              'localPath': registryEntry.localPath,
              'reviewState': registryEntry.reviewState,
            },
            ...evidence,
          },
        ),
      );
    }

    for (final entry in registry) {
      final linkedProjectId = entry.atlasProjectId?.trim();
      if (entry.reviewState == 'ignored') continue;
      if (linkedProjectId == null || linkedProjectId.isEmpty) {
        addFinding(
          registryEntry: entry,
          severity: 'warning',
          category: 'registry',
          title: 'Registered local project is not linked to an Atlas project.',
          detail:
              'Link it to an existing project, import it as a new project, or mark it ignored.',
        );
      } else if (!projectIds.contains(linkedProjectId)) {
        addFinding(
          registryEntry: entry,
          severity: 'error',
          category: 'registry',
          title: 'Registry row points to a missing Atlas project.',
          detail: linkedProjectId,
        );
      }
      if (entry.reviewState == 'needs_review') {
        addFinding(
          registryEntry: entry,
          severity: 'warning',
          category: 'registry',
          title: 'Registered local project still needs review.',
        );
      }
      if (!Directory(entry.localPath).existsSync()) {
        addFinding(
          registryEntry: entry,
          severity: 'error',
          category: 'registry',
          title: 'Registered local path does not exist.',
          detail: entry.localPath,
        );
      }
    }

    for (final duplicateGroup in registryEntriesByProjectId.entries.where(
      (entry) => entry.value.length > 1,
    )) {
      final linkedProject = projectsById[duplicateGroup.key];
      final entries = duplicateGroup.value;
      addFinding(
        project: linkedProject,
        registryEntry: entries.first,
        severity: 'warning',
        category: 'registry',
        title:
            'Multiple local registry entries are linked to the same Atlas project.',
        detail:
            'Review these registry rows and merge, unlink, or mark duplicates ignored.',
        evidence: {
          'atlasProjectId': duplicateGroup.key,
          'linkedRegistryIds': entries.map((entry) => entry.id).toList(),
          'linkedDisplayNames': entries
              .map((entry) => entry.displayName)
              .toList(),
          'linkedLocalPaths': entries.map((entry) => entry.localPath).toList(),
        },
      );
    }

    for (final project in projects) {
      final registryEntry = registryEntriesByProjectId[project.id]?.first;
      final docs = await db.getDocumentsForProject(project.id);
      final mediaItems = await getProjectMedia(project.id);
      final tags = await getTagsForProject(project.id);
      final people = await getProjectPeople(project.id);
      final items = await getWorkItemsForProject(project.id);
      final risks = await getProjectRisks(project.id);
      final decisions = await getProjectDecisions(project.id);
      final summary = await db.getLatestProjectSummaryDraft(project.id);
      final observation = registryEntry == null
          ? null
          : await db.getLatestProjectObservationForPath(
              registryEntry.localPath,
            );
      final github = await getLatestProjectGitRemoteStatus(project.id);
      final refreshItems = registryEntry == null
          ? const <LocalProjectRefreshItem>[]
          : await db.getLocalProjectRefreshItemsForRegistry(registryEntry.id);
      final sourceFileCount = refreshItems
          .where((item) => item.sourceKind == 'source_file')
          .length;
      final cardCount = refreshItems
          .where((item) => item.sourceKind == 'atlas_card')
          .length;

      documents += docs.length;
      media += mediaItems.length;
      sourceFiles += sourceFileCount;
      cards += cardCount;
      if (docs.isNotEmpty) projectsWithDocs++;
      if (mediaItems.isNotEmpty) projectsWithMedia++;
      if (sourceFileCount > 0) projectsWithSourceFiles++;
      if (cardCount > 0) projectsWithCards++;
      if (people.isNotEmpty) projectsWithPeople++;
      if (tags.isNotEmpty) projectsWithTags++;
      if (items.isNotEmpty) projectsWithTasks++;
      if (risks.isNotEmpty) projectsWithRisks++;
      if (decisions.isNotEmpty) projectsWithDecisions++;
      if (summary != null) projectsWithSummaries++;
      if (github != null) projectsWithGithubCache++;

      if (registryEntry == null) {
        addFinding(
          project: project,
          severity: 'warning',
          category: 'registry',
          title: 'Atlas project is not linked to a local registry entry.',
          detail:
              'Run an Operations scan and link or upload the matching local project.',
        );
      }
      if (_isBlank(project.description)) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'identity',
          title: 'Project description is blank.',
        );
      }
      if (_isBlank(project.owner)) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'people',
          title: 'Project owner is blank.',
        );
      }
      if (tags.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'identity',
          title: 'Project has no tags.',
        );
      }
      if (docs.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'library',
          title: 'Project has no imported documents.',
        );
      }
      if (_looksLikeSoftwareProject(observation, registryEntry) &&
          sourceFileCount == 0) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'library',
          title: 'Software project has no individual source files imported.',
          detail:
              'Run linked project refresh with source documents enabled, or review source import caps/exclusions.',
        );
      }
      if (_looksLikeCardProject(project, registryEntry) && cardCount == 0) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'library',
          title: 'Card-style project has no individual cards imported.',
          detail:
              'Run linked project refresh and review card source parser coverage.',
        );
      }
      if (mediaItems.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'media',
          title: 'Project has no imported media.',
        );
      }
      if (people.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'people',
          title: 'Project has no people/role assignments.',
        );
      }
      if (items.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'workboard',
          title: 'Project workboard has no tasks.',
        );
      }
      if (risks.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'governance',
          title: 'Project has no risks/issues recorded.',
        );
      }
      if (decisions.isEmpty) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'governance',
          title: 'Project decision log is empty.',
        );
      }
      if (refreshSummaries && summary == null) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: summaryResult?.aiUnavailable == true ? 'info' : 'warning',
          category: 'ai_summary',
          title: 'Project has no cached AI summary.',
          detail: summaryResult?.aiUnavailable == true
              ? 'AI summary refresh was skipped because Ollama is unavailable.'
              : 'Run AI summary refresh after documents and media are imported.',
        );
      }
      final remote = observation?.remoteUrl;
      final githubIdentity = GithubRemoteMetadataService.parseGithubRemoteUrl(
        remote,
      );
      if (githubIdentity != null && github == null) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'repository',
          title: 'GitHub remote is detected but metadata is not cached.',
          detail:
              'Use Refresh GitHub so Atlas can show public/private/default-branch state.',
          evidence: {'remoteUrl': remote},
        );
      } else if (github?.hasError == true) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'warning',
          category: 'repository',
          title: 'Latest GitHub metadata refresh has a warning.',
          detail: github?.error,
          evidence: {'remoteUrl': github?.remoteUrl},
        );
      } else if (_isBlank(remote) && registryEntry != null) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'repository',
          title: 'Project appears local-only.',
          detail: 'No git remote URL was recorded in the latest observation.',
        );
      }
      final dirtyCount = observation?.dirtyCount ?? 0;
      if (dirtyCount > 0) {
        addFinding(
          project: project,
          registryEntry: registryEntry,
          severity: 'info',
          category: 'repository',
          title: 'Latest local git observation has uncommitted changes.',
          evidence: {'dirtyCount': dirtyCount},
        );
      }
    }

    final coverage = {
      'projects': projects.length,
      'registryEntries': registry.length,
      'linkedProjects': registryByProjectId.length,
      'unlinkedRegistryEntries': registry
          .where(
            (entry) =>
                entry.reviewState != 'ignored' &&
                (entry.atlasProjectId ?? '').isEmpty,
          )
          .length,
      'atlasProjectsWithoutRegistry': projects
          .where((project) => !registryByProjectId.containsKey(project.id))
          .length,
      'documents': documents,
      'media': media,
      'sourceFiles': sourceFiles,
      'cards': cards,
      'projectsWithDocs': projectsWithDocs,
      'projectsWithMedia': projectsWithMedia,
      'projectsWithSourceFiles': projectsWithSourceFiles,
      'projectsWithCards': projectsWithCards,
      'projectsWithPeople': projectsWithPeople,
      'projectsWithTags': projectsWithTags,
      'projectsWithTasks': projectsWithTasks,
      'projectsWithRisks': projectsWithRisks,
      'projectsWithDecisions': projectsWithDecisions,
      'projectsWithSummaries': projectsWithSummaries,
      'projectsWithGithubCache': projectsWithGithubCache,
    };
    return _ProjectEnrichmentAudit(findings: findings, coverage: coverage);
  }

  bool _looksLikeSoftwareProject(
    ProjectObservation? observation,
    ProjectRegistryEntry? registry,
  ) {
    final markers = observation == null
        ? const <String>[]
        : _decodeStringList(observation.markerFilesJson);
    const softwareMarkers = {
      'package.json',
      'pubspec.yaml',
      'pyproject.toml',
      'Cargo.toml',
      'go.mod',
      'pom.xml',
      'build.gradle',
    };
    if (markers.any(softwareMarkers.contains)) return true;
    final path = [
      registry?.localPath,
      observation?.observedPath,
    ].whereType<String>().join(' ').toLowerCase();
    return path.contains(r'\src') ||
        path.contains(r'\lib') ||
        path.contains(r'\app') ||
        path.contains('flutter') ||
        path.contains('python') ||
        path.contains('node');
  }

  bool _looksLikeCardProject(Project project, ProjectRegistryEntry? registry) {
    final haystack = [
      project.title,
      project.description,
      registry?.displayName,
      registry?.localPath,
    ].whereType<String>().join(' ').toLowerCase();
    return haystack.contains('philosophy') ||
        haystack.contains('trade atlas') ||
        haystack.contains('trade_craft') ||
        haystack.contains('trade craft') ||
        haystack.contains('pre_industrialization') ||
        haystack.contains('pre industrialization') ||
        haystack.contains('goalcard') ||
        haystack.contains('card library');
  }

  bool _isBlank(String? value) => value == null || value.trim().isEmpty;

  Stream<List<ProjectScanRun>> watchProjectScanRuns({int limit = 50}) =>
      db.watchProjectScanRuns(limit: limit);

  Stream<List<ProjectObservation>> watchRecentProjectObservations({
    int limit = 500,
  }) => db.watchRecentProjectObservations(limit: limit);

  Stream<List<ProjectRegistryEntry>> watchProjectRegistry() =>
      db.watchProjectRegistry();

  Future<List<ProjectRegistryEntry>> getProjectRegistry() =>
      db.getProjectRegistry();

  Future<ProjectRegistryEntry?> getProjectRegistryForAtlasProject(
    String projectId,
  ) => db.getProjectRegistryByAtlasProjectId(projectId);

  Future<ProjectLocalRepoSummary?> getProjectLocalRepoSummary(
    String projectId,
  ) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    final observation = registry == null
        ? null
        : await db.getLatestProjectObservationForPath(registry.localPath);
    final refreshItems = registry == null
        ? const <LocalProjectRefreshItem>[]
        : await db.getLocalProjectRefreshItemsForRegistry(registry.id);
    final documents = await db.getDocumentsForProject(projectId);
    final media = await db.getProjectMedia(projectId);
    return ProjectLocalRepoSummary(
      registry: registry,
      observation: observation,
      refreshItems: refreshItems,
      documents: documents,
      media: media,
    );
  }

  Future<ProjectObservation?> getLatestLocalProjectObservation(
    String projectId,
  ) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    if (registry == null) return null;
    return db.getLatestProjectObservationForPath(registry.localPath);
  }

  Future<LocalGitVisibilityReport> inspectLocalGitVisibility(
    String projectId, {
    LocalGitVisibilityService service = const LocalGitVisibilityService(),
  }) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    if (registry == null) {
      throw StateError('Project is not linked to a local registry entry.');
    }
    return service.inspect(registry.localPath);
  }

  Future<ProjectGitRemoteStatus?> getLatestProjectGitRemoteStatus(
    String projectId,
  ) => db.getLatestProjectGitRemoteStatus(projectId);

  Future<List<ProjectGitRemoteStatus>> getProjectGitRemoteStatuses(
    String projectId,
  ) => db.getProjectGitRemoteStatuses(projectId);

  Future<String> enqueueLlmTask({
    required String projectId,
    String? workItemId,
    required String title,
    required String objective,
    Map<String, Object?> context = const {},
    String priority = 'normal',
    String createdBy = 'ui',
  }) async {
    final id = await db.enqueueLlmTask(
      projectId: projectId,
      workItemId: workItemId,
      title: title,
      objective: objective,
      contextJson: jsonEncode(context),
      priority: priority,
      createdBy: createdBy,
    );
    await db.logEvent(
      area: 'llm_queue',
      action: 'task_enqueued',
      entityType: 'project',
      entityId: projectId,
      outputJson: jsonEncode({'taskId': id, 'workItemId': workItemId}),
    );
    notifyListeners();
    return id;
  }

  Future<List<LlmTaskQueueItem>> getLlmTasks({
    String? projectId,
    String? status,
    int limit = 50,
  }) => db.getLlmTasks(projectId: projectId, status: status, limit: limit);

  Future<List<LlmTaskQueueItem>> getLlmTasksForProject(
    String projectId, {
    int limit = 50,
  }) => db.getLlmTasksForProject(projectId, limit: limit);

  Future<LlmTaskQueueItem?> getLlmTask(String taskId) => db.getLlmTask(taskId);

  Future<LlmTaskQueueItem> updateLlmTask({
    required String taskId,
    required String projectId,
    String? workItemId,
    required String title,
    required String objective,
    Map<String, Object?> context = const {},
    String priority = 'normal',
  }) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) {
      throw StateError('LLM task not found: $taskId');
    }
    if (existing.status == 'completed') {
      throw StateError('Completed LLM tasks cannot be edited.');
    }
    final cleanProjectId = projectId.trim();
    final project = await db.getProjectFull(cleanProjectId);
    if (project == null ||
        project.deletedAt != null ||
        project.id == AppDb.kGeneralTasksProjectId) {
      throw StateError('Project not found or not visible: $cleanProjectId');
    }
    final cleanTitle = title.trim();
    final cleanObjective = objective.trim();
    if (cleanTitle.isEmpty) throw StateError('LLM task title is required.');
    if (cleanObjective.isEmpty) {
      throw StateError('LLM task objective is required.');
    }
    const priorities = {'low', 'normal', 'high', 'urgent'};
    final cleanPriority = priority.trim().isEmpty ? 'normal' : priority.trim();
    if (!priorities.contains(cleanPriority)) {
      throw StateError('Unsupported priority: $cleanPriority.');
    }
    final cleanWorkItemId = workItemId?.trim();
    final normalizedWorkItemId =
        cleanWorkItemId == null || cleanWorkItemId.isEmpty
        ? null
        : cleanWorkItemId;
    if (normalizedWorkItemId != null) {
      final item = await db.getWorkItem(normalizedWorkItemId);
      final owningProject = await db.getProjectForWorkItem(
        normalizedWorkItemId,
      );
      if (item == null || owningProject?.id != cleanProjectId) {
        throw StateError(
          'Work item is not part of project $cleanProjectId: $normalizedWorkItemId.',
        );
      }
    }

    final item = await db.updateLlmTask(
      id: taskId,
      projectId: cleanProjectId,
      workItemId: normalizedWorkItemId,
      title: cleanTitle,
      objective: cleanObjective,
      contextJson: jsonEncode(context),
      priority: cleanPriority,
    );
    if (item == null) throw StateError('LLM task disappeared: $taskId');
    await db.logEvent(
      area: 'llm_queue',
      action: 'task_updated',
      entityType: 'llm_task',
      entityId: taskId,
      outputJson: jsonEncode({
        'projectId': cleanProjectId,
        'workItemId': normalizedWorkItemId,
        'leaseRevoked': existing.status == 'leased',
      }),
    );
    notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem?> claimLlmTask({
    String? taskId,
    required String leasedBy,
    Duration leaseDuration = const Duration(hours: 1),
  }) async {
    final item = await db.claimLlmTask(
      taskId: taskId,
      leasedBy: leasedBy,
      leaseDuration: leaseDuration,
    );
    if (item != null) notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem> cancelLlmTask(
    String taskId, {
    String? reason,
  }) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) {
      throw StateError('LLM task not found: $taskId');
    }
    if (existing.status == 'completed') {
      throw StateError('Completed LLM tasks cannot be cancelled.');
    }
    final cleanReason = reason?.trim();
    final item = await db.cancelLlmTask(
      id: taskId,
      reason: cleanReason == null || cleanReason.isEmpty
          ? 'Cancelled by operator.'
          : cleanReason,
    );
    if (item == null) throw StateError('LLM task disappeared: $taskId');
    await db.logEvent(
      area: 'llm_queue',
      action: 'task_cancelled',
      entityType: 'llm_task',
      entityId: taskId,
      outputJson: jsonEncode({'projectId': item.projectId}),
    );
    notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem> requeueLlmTask(String taskId) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) {
      throw StateError('LLM task not found: $taskId');
    }
    if (!{'failed', 'cancelled'}.contains(existing.status)) {
      throw StateError('Only failed or cancelled LLM tasks can be requeued.');
    }
    final item = await db.requeueLlmTask(id: taskId);
    if (item == null) throw StateError('LLM task disappeared: $taskId');
    await db.logEvent(
      area: 'llm_queue',
      action: 'task_requeued',
      entityType: 'llm_task',
      entityId: taskId,
      outputJson: jsonEncode({'projectId': item.projectId}),
    );
    notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem?> completeLlmTask({
    required String taskId,
    required Map<String, Object?> result,
    String? reviewDraftId,
  }) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) return null;
    if (existing.status != 'leased') {
      throw StateError('Only leased LLM tasks can be completed.');
    }
    final item = await db.completeLlmTask(
      id: taskId,
      resultJson: jsonEncode(result),
      reviewDraftId: reviewDraftId,
    );
    notifyListeners();
    return item;
  }

  Future<LlmTaskQueueItem?> failLlmTask({
    required String taskId,
    required String error,
    Map<String, Object?> result = const {},
  }) async {
    final existing = await db.getLlmTask(taskId);
    if (existing == null) return null;
    if (existing.status != 'leased') {
      throw StateError('Only leased LLM tasks can be failed.');
    }
    final item = await db.failLlmTask(
      id: taskId,
      error: error,
      resultJson: result.isEmpty ? null : jsonEncode(result),
    );
    notifyListeners();
    return item;
  }

  Future<ProjectGitRemoteStatus> refreshProjectGithubRemoteMetadata(
    String projectId, {
    GithubRemoteMetadataService? service,
  }) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    if (registry == null) {
      throw StateError('Project is not linked to a local registry entry.');
    }
    final observation = await db.getLatestProjectObservationForPath(
      registry.localPath,
    );
    final remoteUrl = observation?.remoteUrl;
    final identity = GithubRemoteMetadataService.parseGithubRemoteUrl(
      remoteUrl,
    );
    if (identity == null) {
      throw StateError('No GitHub origin remote is recorded for this project.');
    }

    final result = await (service ?? GithubRemoteMetadataService()).fetch(
      identity,
    );
    final status = await db.upsertProjectGitRemoteStatus(
      projectId: projectId,
      registryId: registry.id,
      provider: result.identity.provider,
      owner: result.identity.owner,
      repo: result.identity.repo,
      remoteUrl: result.identity.remoteUrl,
      htmlUrl: result.htmlUrl,
      visibility: result.visibility,
      defaultBranch: result.defaultBranch,
      onlineHeadSha: result.onlineHeadSha,
      isPrivate: result.isPrivate,
      isFork: result.isFork,
      isArchived: result.isArchived,
      checkedAt: result.checkedAt,
      remoteUpdatedAt: result.remoteUpdatedAt,
      remotePushedAt: result.remotePushedAt,
      error: result.error,
      rawJson: result.rawJson,
    );
    await db.logEvent(
      level: result.hasError ? 'warn' : 'info',
      area: 'github',
      action: 'project_github_metadata_refreshed',
      entityType: 'project',
      entityId: projectId,
      inputJson: remoteUrl,
      outputJson: jsonEncode(status.toJson()),
      error: result.error,
    );
    notifyListeners();
    return status;
  }

  Future<String> associateProjectFile(String projectId, String path) async {
    final filePath = path.trim();
    if (filePath.isEmpty) {
      throw ArgumentError('Choose a file to associate.');
    }
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Associated file not found', filePath);
    }
    final filename = p.basename(filePath);
    final extension = p.extension(filename).replaceFirst('.', '').toLowerCase();
    final metadataJson = jsonEncode({
      'associationKind': 'file',
      'originalPath': filePath,
    });
    if (LocalProjectRefreshService.mediaExtensions.contains(extension)) {
      return importProjectMediaFromPath(
        projectId,
        filePath,
        source: 'associated_file:$filePath',
        metadataJson: metadataJson,
      );
    }
    final id = await db.importDocumentFromPath(
      filePath,
      projectId: projectId,
      source: 'associated_file:$filePath',
      metadataJson: metadataJson,
    );
    notifyListeners();
    return id;
  }

  Future<String> associateProjectFolder(String projectId, String path) async {
    final folderPath = path.trim();
    if (folderPath.isEmpty) {
      throw ArgumentError('Choose a folder to associate.');
    }
    if (isUnsafeOperationsScanRoot(folderPath)) {
      throw ArgumentError('Choose a project folder, not a drive root.');
    }
    final folder = Directory(folderPath);
    if (!folder.existsSync()) {
      throw FileSystemException('Associated folder not found', folderPath);
    }
    final title = p.basename(folderPath);
    final stat = folder.statSync();
    return saveProjectMedia(
      projectId: projectId,
      title: title.isEmpty ? folderPath : title,
      originalFilename: title.isEmpty ? folderPath : title,
      storedPath: folderPath,
      mediaType: 'folder',
      fileModifiedAt: stat.modified,
      source: 'associated_folder:$folderPath',
      metadataJson: jsonEncode({
        'associationKind': 'folder',
        'originalPath': folderPath,
      }),
    );
  }

  Future<ProjectRegistryEntry> replaceProjectLocalRepoLink(
    String projectId,
    String selectedPath,
  ) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) {
      throw StateError('Atlas project not found: $projectId');
    }
    final rootPath = selectedPath.trim();
    if (rootPath.isEmpty) {
      throw ArgumentError('Choose a project folder.');
    }
    if (isUnsafeOperationsScanRoot(rootPath)) {
      throw ArgumentError('Choose a project folder, not a drive root.');
    }
    if (!Directory(rootPath).existsSync()) {
      throw FileSystemException('Local repo folder not found', rootPath);
    }
    final gitReport = await const LocalGitVisibilityService().inspect(rootPath);
    final scanRoot = gitReport.gitRoot ?? rootPath;

    final runId = await runLocalOperationsScan(
      scanner: LocalOperationsScanner(roots: [scanRoot], maxDepth: 0),
    );
    final observations = await db.getProjectObservationsForScanRun(runId);
    if (observations.isEmpty) {
      throw StateError('No project markers found in that folder.');
    }
    final observation = _chooseLocalRepoReplacementObservation(
      scanRoot,
      observations,
    );
    final existingForPath = await db.getProjectRegistryByPath(
      observation.observedPath,
    );
    final existingProjectId = existingForPath?.atlasProjectId?.trim();
    if (existingProjectId != null &&
        existingProjectId.isNotEmpty &&
        existingProjectId != projectId) {
      throw StateError(
        'That folder is already linked to another Atlas project.',
      );
    }

    late ProjectRegistryEntry linkedRegistry;
    await db.transaction(() async {
      await db.reviewProjectObservation(
        observationId: observation.id,
        reviewState: 'linked',
        atlasProjectId: projectId,
      );
      final registry = await db.getProjectRegistryByPath(
        observation.observedPath,
      );
      if (registry == null) {
        throw StateError('Project registry row was not created.');
      }
      await db.unlinkProjectRegistryEntriesForAtlasProject(
        atlasProjectId: projectId,
        exceptRegistryId: registry.id,
      );
      await db.linkProjectRegistryEntryToAtlasProject(
        registryId: registry.id,
        atlasProjectId: projectId,
      );
      await db.updateProjectMeta(projectId, {
        'scopeIncluded': 'Local project root: ${registry.localPath}',
      });
      linkedRegistry = (await db.getProjectRegistryEntry(registry.id))!;
    });

    await db.logEvent(
      area: 'projects',
      action: 'local_repo_link_replaced',
      entityType: 'project',
      entityId: projectId,
      inputJson: rootPath,
      outputJson: jsonEncode({
        'registryId': linkedRegistry.id,
        'localPath': linkedRegistry.localPath,
        'gitRoot': linkedRegistry.gitRoot,
        'selectedPath': rootPath,
        'scanRunId': runId,
      }),
    );
    notifyListeners();
    return linkedRegistry;
  }

  ProjectObservation _chooseLocalRepoReplacementObservation(
    String rootPath,
    List<ProjectObservation> observations,
  ) {
    final normalizedRoot = _pathKey(rootPath);
    return observations.firstWhere(
      (observation) => _pathKey(observation.observedPath) == normalizedRoot,
      orElse: () => observations.first,
    );
  }

  Future<LocalProjectRefreshPreview> previewLocalProjectRefresh(
    String projectId, {
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    if (registry == null) {
      throw StateError('Project is not linked to a local registry entry.');
    }
    return _buildLocalProjectRefreshPreview(
      registry,
      projectId,
      service: service,
    );
  }

  Future<LocalProjectRefreshPreview> previewLocalProjectRefreshForRegistryEntry(
    String registryId,
    String projectId, {
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final registry = await db.getProjectRegistryEntry(registryId);
    if (registry == null) {
      throw StateError('Project registry entry not found: $registryId');
    }
    final linkedProjectId = registry.atlasProjectId;
    if (linkedProjectId != null &&
        linkedProjectId.isNotEmpty &&
        linkedProjectId != projectId) {
      throw StateError(
        'Registry entry $registryId is linked to $linkedProjectId, not $projectId.',
      );
    }
    return _buildLocalProjectRefreshPreview(
      registry,
      projectId,
      service: service,
    );
  }

  Future<LocalProjectRefreshPreview> _buildLocalProjectRefreshPreview(
    ProjectRegistryEntry registry,
    String projectId, {
    required LocalProjectRefreshService service,
  }) async {
    final observation = await db.getLatestProjectObservationForPath(
      registry.localPath,
    );
    final plan = await service.buildPlan(registry.localPath);
    final entries = <LocalProjectRefreshPreviewEntry>[];
    for (final action in plan.actions) {
      final ledger = await db.getLocalProjectRefreshItem(
        registryId: registry.id,
        sourceKind: action.sourceKind,
        sourceKey: action.sourceKey,
      );
      final status = ledger == null
          ? 'new'
          : ledger.sourceFingerprint == action.fingerprint
          ? 'unchanged'
          : 'changed';
      entries.add(
        LocalProjectRefreshPreviewEntry(
          action: action,
          status: status,
          existingTargetId: ledger?.targetId,
        ),
      );
    }
    return LocalProjectRefreshPreview(
      registryId: registry.id,
      projectId: projectId,
      localPath: registry.localPath,
      profile: plan.profile,
      branch: observation?.branch,
      headSha: observation?.headSha,
      dirtyCount: observation?.dirtyCount,
      remoteUrl: observation?.remoteUrl,
      observedAt: observation?.observedAt,
      entries: entries,
      warnings: plan.warnings,
    );
  }

  Future<LocalProjectRefreshApplyResult> applyLocalProjectRefresh(
    String projectId, {
    Iterable<String>? selectedActionIds,
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final preview = await previewLocalProjectRefresh(
      projectId,
      service: service,
    );
    return _applyLocalProjectRefreshPreview(
      projectId,
      preview,
      selectedActionIds: selectedActionIds,
    );
  }

  Future<LocalProjectRefreshApplyResult>
  applyLocalProjectRefreshForRegistryEntry(
    String registryId,
    String projectId, {
    Iterable<String>? selectedActionIds,
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
  }) async {
    final preview = await previewLocalProjectRefreshForRegistryEntry(
      registryId,
      projectId,
      service: service,
    );
    return _applyLocalProjectRefreshPreview(
      projectId,
      preview,
      selectedActionIds: selectedActionIds,
    );
  }

  Future<LocalProjectBatchRefreshResult> refreshLinkedLocalProjects({
    bool includeSourceDocuments = true,
    Duration betweenProjects = const Duration(milliseconds: 100),
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
    ProjectEnrichmentStatusCallback? onStatus,
  }) async {
    if (_localProjectRefreshRunning) {
      return const LocalProjectBatchRefreshResult(
        considered: 0,
        refreshed: 0,
        created: 0,
        updated: 0,
        unchanged: 0,
        skipped: 0,
        failed: 0,
        alreadyRunning: true,
        warnings: ['Local project refresh is already running.'],
      );
    }
    _localProjectRefreshRunning = true;
    notifyListeners();
    var considered = 0;
    var refreshed = 0;
    var created = 0;
    var updated = 0;
    var unchanged = 0;
    var skipped = 0;
    var failed = 0;
    final warnings = <String>[];
    try {
      onStatus?.call('Reading linked project registry.', current: 0);
      final registry = await db.getProjectRegistry();
      final linked = registry
          .where(
            (entry) =>
                entry.reviewState != 'ignored' &&
                (entry.atlasProjectId ?? '').isNotEmpty,
          )
          .toList(growable: false);
      onStatus?.call(
        linked.isEmpty
            ? 'No linked projects to refresh.'
            : 'Refreshing linked projects (0/${linked.length}).',
        current: 0,
        total: linked.length,
      );
      for (final entry in linked) {
        considered++;
        final projectId = entry.atlasProjectId!;
        onStatus?.call(
          'Refreshing ${entry.displayName} ($considered/${linked.length}).',
          current: considered,
          total: linked.length,
        );
        try {
          final preview = await previewLocalProjectRefreshForRegistryEntry(
            entry.id,
            projectId,
            service: service,
          );
          final selected = preview.entries
              .where((previewEntry) {
                if (!previewEntry.shouldApplyByDefault) return false;
                if (includeSourceDocuments) return true;
                final kind = previewEntry.action.sourceKind;
                return kind != 'source_file' && kind != 'atlas_card';
              })
              .map((previewEntry) => previewEntry.action.id)
              .toList(growable: false);
          final result = await _applyLocalProjectRefreshPreview(
            projectId,
            preview,
            selectedActionIds: selected,
          );
          created += result.created;
          updated += result.updated;
          unchanged += result.unchanged;
          skipped += result.skipped;
          warnings.addAll(result.warnings);
          if (result.created > 0 || result.updated > 0) refreshed++;
          onStatus?.call(
            'Imported ${entry.displayName}: ${result.created} created, ${result.updated} updated.',
            current: considered,
            total: linked.length,
          );
        } catch (error) {
          failed++;
          warnings.add('${entry.displayName}: $error');
          onStatus?.call(
            'Failed ${entry.displayName}: $error',
            current: considered,
            total: linked.length,
          );
        }
        if (betweenProjects > Duration.zero) {
          await Future<void>.delayed(betweenProjects);
        }
      }
      onStatus?.call(
        'Linked refresh complete: $created created, $updated updated, $failed failed.',
        current: linked.length,
        total: linked.length,
      );
      await db.logEvent(
        area: 'operations',
        action: 'linked_local_projects_refreshed',
        outputJson: jsonEncode({
          'considered': considered,
          'refreshed': refreshed,
          'created': created,
          'updated': updated,
          'unchanged': unchanged,
          'skipped': skipped,
          'failed': failed,
          'includeSourceDocuments': includeSourceDocuments,
          'warnings': warnings.length,
        }),
      );
      return LocalProjectBatchRefreshResult(
        considered: considered,
        refreshed: refreshed,
        created: created,
        updated: updated,
        unchanged: unchanged,
        skipped: skipped,
        failed: failed,
        warnings: List.unmodifiable(warnings),
      );
    } finally {
      _localProjectRefreshRunning = false;
      notifyListeners();
    }
  }

  Future<LocalProjectRefreshApplyResult> _applyLocalProjectRefreshPreview(
    String projectId,
    LocalProjectRefreshPreview preview, {
    Iterable<String>? selectedActionIds,
  }) async {
    final selected = selectedActionIds?.toSet();
    var created = 0;
    var updated = 0;
    var unchanged = 0;
    var skipped = 0;
    final warnings = <String>[...preview.warnings];

    for (final entry in preview.entries) {
      if (selected != null && !selected.contains(entry.action.id)) {
        skipped++;
        continue;
      }
      if (entry.status == 'unchanged') {
        unchanged++;
        continue;
      }
      try {
        final wasCreated = await _applyLocalProjectRefreshAction(
          preview.registryId,
          projectId,
          entry,
          planProfile: preview.profile,
        );
        if (wasCreated) {
          created++;
        } else {
          updated++;
        }
      } catch (error) {
        warnings.add('${entry.action.title}: $error');
      }
    }

    await db.logEvent(
      area: 'operations',
      action: 'local_project_refresh_applied',
      entityType: 'project',
      entityId: projectId,
      outputJson: jsonEncode({
        'created': created,
        'updated': updated,
        'unchanged': unchanged,
        'skipped': skipped,
        'warnings': warnings.length,
      }),
    );
    notifyListeners();
    return LocalProjectRefreshApplyResult(
      created: created,
      updated: updated,
      unchanged: unchanged,
      skipped: skipped,
      warnings: warnings,
    );
  }

  Future<String> importProjectRegistryEntryAsProject(
    String registryId, {
    bool importDocs = true,
    bool refresh = true,
  }) async {
    final entry = await db.getProjectRegistryEntry(registryId);
    if (entry == null) {
      throw StateError('Project registry entry not found: $registryId');
    }
    if (entry.atlasProjectId != null && entry.atlasProjectId!.isNotEmpty) {
      return entry.atlasProjectId!;
    }
    final matchingProject = await _findSingleMatchingProjectForRegistryEntry(
      entry,
    );
    if (matchingProject != null) {
      return updateExistingProjectFromRegistryEntry(
        registryId,
        matchingProject.id,
        importDocs: importDocs,
        refresh: refresh,
      );
    }

    final now = DateTime.now();
    final projectId = now.microsecondsSinceEpoch.toString();
    await db.transaction(() async {
      await db.createProject(projectId, entry.displayName, now);
      await db.updateProjectMeta(projectId, {
        'description': _projectDescriptionFromRegistry(entry),
        'scopeIncluded': 'Local project root: ${entry.localPath}',
        'scopeExcluded': refresh
            ? 'Repo mutation, GitHub import, and AI summarization were not performed during import.'
            : 'Full source indexing, repo mutation, GitHub import, and AI summarization were not performed during import.',
      });
      await db.linkProjectRegistryEntryToAtlasProject(
        registryId: registryId,
        atlasProjectId: projectId,
      );
      await db.setActiveProjectId(projectId);
    });

    final importedDocs = importDocs
        ? await _importSafeLocalProjectDocs(projectId, entry.localPath)
        : 0;
    LocalProjectRefreshApplyResult? refreshResult;
    if (refresh) {
      refreshResult = await applyLocalProjectRefreshForRegistryEntry(
        registryId,
        projectId,
      );
    }
    await db.logEvent(
      area: 'operations',
      action: 'registry_imported_to_project',
      entityType: 'project',
      entityId: projectId,
      inputJson: registryId,
      outputJson: jsonEncode({
        'localPath': entry.localPath,
        'importedDocuments': importedDocs,
        if (refreshResult != null) ...{
          'refreshCreated': refreshResult.created,
          'refreshUpdated': refreshResult.updated,
          'refreshUnchanged': refreshResult.unchanged,
          'refreshSkipped': refreshResult.skipped,
          'refreshWarnings': refreshResult.warnings.length,
        },
      }),
    );
    notifyListeners();
    return projectId;
  }

  Future<String> updateExistingProjectFromRegistryEntry(
    String registryId,
    String atlasProjectId, {
    bool importDocs = true,
    bool refresh = true,
  }) async {
    final entry = await db.getProjectRegistryEntry(registryId);
    if (entry == null) {
      throw StateError('Project registry entry not found: $registryId');
    }
    final project = await db.getProjectFull(atlasProjectId);
    if (project == null) {
      throw StateError('Atlas project not found: $atlasProjectId');
    }

    await db.transaction(() async {
      await db.linkProjectRegistryEntryToAtlasProject(
        registryId: registryId,
        atlasProjectId: atlasProjectId,
      );
      await db.updateProjectMeta(atlasProjectId, {
        'scopeIncluded': 'Local project root: ${entry.localPath}',
        'scopeExcluded':
            'Full source indexing, repo mutation, GitHub import, and AI summarization were not performed during local update.',
      });
      await db.setActiveProjectId(atlasProjectId);
    });

    final importedDocs = importDocs
        ? await _importSafeLocalProjectDocs(atlasProjectId, entry.localPath)
        : 0;
    LocalProjectRefreshApplyResult? refreshResult;
    if (refresh) {
      refreshResult = await applyLocalProjectRefreshForRegistryEntry(
        registryId,
        atlasProjectId,
      );
    }
    await db.logEvent(
      area: 'operations',
      action: 'registry_updated_existing_project',
      entityType: 'project',
      entityId: atlasProjectId,
      inputJson: registryId,
      outputJson: jsonEncode({
        'localPath': entry.localPath,
        'importedDocuments': importedDocs,
        if (refreshResult != null) ...{
          'refreshCreated': refreshResult.created,
          'refreshUpdated': refreshResult.updated,
          'refreshUnchanged': refreshResult.unchanged,
          'refreshSkipped': refreshResult.skipped,
          'refreshWarnings': refreshResult.warnings.length,
        },
      }),
    );
    notifyListeners();
    return atlasProjectId;
  }

  Future<bool> _applyLocalProjectRefreshAction(
    String registryId,
    String projectId,
    LocalProjectRefreshPreviewEntry entry, {
    required String planProfile,
  }) async {
    final action = entry.action;
    final now = DateTime.now();
    var created = entry.existingTargetId == null;
    String targetId;

    switch (action.targetType) {
      case 'document':
        final path = _payloadNullableString(action, 'path');
        final filename = _payloadString(action, 'filename');
        final title = _payloadNullableString(action, 'title');
        final source = _payloadNullableString(action, 'source');
        final metadataJson = _payloadNullableString(action, 'metadataJson');
        final generatedText = _payloadNullableString(action, 'generatedText');
        final extension = _payloadNullableString(action, 'extension');
        final existingBySource = source == null
            ? null
            : await db.getProjectDocumentBySource(projectId, source);
        final existingId = entry.existingTargetId ?? existingBySource?.id;
        if (existingId != null && await db.documentExists(existingId)) {
          if (entry.status != 'changed') {
            targetId = existingId;
          } else {
            await db.deleteDocument(existingId);
            targetId = await _importRefreshDocument(
              path: path,
              filename: filename,
              title: title,
              source: source,
              metadataJson: metadataJson,
              generatedText: generatedText,
              extension: extension,
              projectId: projectId,
            );
          }
          created = false;
        } else {
          final existing = generatedText == null
              ? await db.getProjectDocumentByOriginalFilename(
                  projectId,
                  filename,
                )
              : null;
          if (existing != null) {
            targetId = existing.id;
            created = false;
          } else {
            targetId = await _importRefreshDocument(
              path: path,
              filename: filename,
              title: title,
              source: source,
              metadataJson: metadataJson,
              generatedText: generatedText,
              extension: extension,
              projectId: projectId,
            );
            created = true;
          }
        }
        break;
      case 'media':
        final path = _payloadString(action, 'path');
        final filename = _payloadString(action, 'filename');
        final title = _payloadString(action, 'title');
        final relativePath = _payloadString(action, 'relativePath');
        final source = 'local_refresh:${action.sourceKey}';
        final existingBySource = await db.getProjectMediaBySource(
          projectId,
          source,
        );
        final existingId = entry.existingTargetId ?? existingBySource?.id;
        final existingMedia = existingId == null
            ? null
            : await db.getProjectMediaItem(existingId);
        if (existingMedia != null && entry.status != 'changed') {
          targetId = existingMedia.id;
          created = false;
        } else {
          if (existingMedia != null) {
            await db.deleteProjectMedia(existingMedia.id);
            created = false;
          }
          targetId = await importProjectMediaFromPath(
            projectId,
            path,
            title: title,
            caption: 'Imported from local project media: $relativePath',
            source: source,
            metadataJson: jsonEncode({
              'refreshSourceKey': action.sourceKey,
              'relativePath': relativePath,
              'filename': filename,
            }),
          );
        }
        break;
      case 'decision':
        final title = _payloadString(action, 'title');
        final ctx = _payloadNullableString(action, 'ctx');
        final decider = _payloadNullableString(action, 'decider');
        if (entry.existingTargetId != null &&
            await db.getProjectDecision(entry.existingTargetId!) != null) {
          await db.updateProjectDecision(
            entry.existingTargetId!,
            title: title,
            ctx: ctx,
            decider: decider,
          );
          targetId = entry.existingTargetId!;
          created = false;
        } else {
          targetId = await db.addProjectDecision(
            projectId,
            title,
            ctx,
            decider,
          );
          created = true;
        }
        break;
      case 'work_item':
        final title = _payloadString(action, 'title');
        final description = _payloadNullableString(action, 'description');
        final status = _payloadString(action, 'status');
        final priority = _payloadString(action, 'priority');
        final blockedReason = _payloadNullableString(action, 'blockedReason');
        if (entry.existingTargetId != null &&
            await db.workItemExists(entry.existingTargetId!)) {
          await db.updateWorkItem(
            id: entry.existingTargetId!,
            title: title,
            description: description,
            status: status,
            priority: priority,
            blockedReason: blockedReason,
            clearBlockedReason: blockedReason == null,
          );
          targetId = entry.existingTargetId!;
          created = false;
        } else {
          final stages = await db.getStagesForProject(projectId);
          if (stages.isEmpty) {
            await db.ensureDefaultStagesForProjects();
          }
          final stageList = await db.getStagesForProject(projectId);
          if (stageList.isEmpty) {
            throw StateError('Project has no stage for imported work items.');
          }
          targetId = await db.addWorkItem(
            stageId: stageList.first.id,
            title: title,
            description: description,
            status: status,
            priority: priority,
            source: _payloadNullableString(action, 'source'),
            blockedReason: blockedReason,
          );
          created = true;
        }
        break;
      case 'risk':
        final title = _payloadString(action, 'title');
        final desc = _payloadNullableString(action, 'desc');
        final severity = _payloadString(action, 'severity');
        if (entry.existingTargetId != null &&
            await db.getProjectRisk(entry.existingTargetId!) != null) {
          await db.updateProjectRisk(
            entry.existingTargetId!,
            title: title,
            desc: desc,
            severity: severity,
          );
          targetId = entry.existingTargetId!;
          created = false;
        } else {
          targetId = await db.addProjectRisk(projectId, title, desc, severity);
          created = true;
        }
        break;
      case 'project':
        final registry = await db.getProjectRegistryEntry(registryId);
        if (registry == null) {
          throw StateError('Project registry entry not found: $registryId');
        }
        await _applyProjectIdentityAction(
          projectId: projectId,
          entry: registry,
          action: action,
          planProfile: planProfile,
        );
        targetId = projectId;
        created = false;
        break;
      default:
        throw StateError('Unsupported refresh target: ${action.targetType}');
    }

    await db.upsertLocalProjectRefreshItem(
      registryId: registryId,
      sourceKind: action.sourceKind,
      sourceKey: action.sourceKey,
      targetType: action.targetType,
      targetId: targetId,
      sourceFingerprint: action.fingerprint,
      lastImportedAt: now,
    );
    return created;
  }

  Future<String> _importRefreshDocument({
    required String? path,
    required String filename,
    required String? title,
    required String? source,
    required String? metadataJson,
    required String? generatedText,
    required String? extension,
    required String projectId,
  }) {
    if (generatedText != null) {
      return db.importGeneratedDocument(
        title: title ?? filename,
        originalFilename: filename,
        body: generatedText,
        projectId: projectId,
        extension: extension,
        source: source,
        metadataJson: metadataJson,
      );
    }
    if (path == null || path.trim().isEmpty) {
      throw StateError('Document refresh action is missing a source path.');
    }
    return db.importDocumentFromPath(
      path,
      projectId: projectId,
      title: title,
      source: source,
      metadataJson: metadataJson,
    );
  }

  String _payloadString(LocalProjectRefreshAction action, String key) {
    final value = action.payload[key];
    if (value == null) {
      throw StateError('Refresh action ${action.id} is missing $key.');
    }
    return '$value';
  }

  String? _payloadNullableString(LocalProjectRefreshAction action, String key) {
    final value = action.payload[key];
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  Future<String> runLocalOperationsScan({
    LocalOperationsScanner scanner = const LocalOperationsScanner(),
  }) async {
    final startedAt = DateTime.now();
    final runId = await db.startProjectScanRun(
      rootsJson: jsonEncode(scanner.roots),
      startedAt: startedAt,
    );
    try {
      final result = await scanner.scan();
      for (var i = 0; i < result.observations.length; i++) {
        final observation = result.observations[i];
        final existing = await db.getProjectRegistryByPath(
          observation.observedPath,
        );
        await db.addProjectObservation(
          id: 'obs_${runId}_$i',
          registryId: existing?.id,
          scanRunId: runId,
          observedPath: observation.observedPath,
          classificationGuess: observation.classificationGuess,
          confidence: observation.confidence,
          branch: observation.branch,
          headSha: observation.headSha,
          dirtyCount: observation.dirtyCount,
          remoteUrl: observation.remoteUrl,
          markerFilesJson: jsonEncode(observation.markerFiles),
          warningsJson: jsonEncode(observation.warnings),
          rawJson: observation.toRawJson(),
          observedAt: observation.observedAt,
        );
      }
      await db.finishProjectScanRun(
        id: runId,
        completedAt: result.completedAt,
        status: 'completed',
        totalSeen: result.totalSeen,
        candidates: result.observations.length,
        ignored: result.ignored,
        warningsJson: jsonEncode(result.warnings),
      );
      await db.logEvent(
        area: 'operations',
        action: 'local_scan_completed',
        entityType: 'project_scan_run',
        entityId: runId,
        outputJson: jsonEncode({
          'roots': result.roots,
          'candidates': result.observations.length,
          'totalSeen': result.totalSeen,
        }),
      );
      notifyListeners();
      return runId;
    } catch (error, stackTrace) {
      await db.finishProjectScanRun(
        id: runId,
        completedAt: DateTime.now(),
        status: 'failed',
        totalSeen: 0,
        candidates: 0,
        ignored: 0,
        warningsJson: jsonEncode([error.toString()]),
      );
      await db.logError(
        area: 'operations',
        action: 'local_scan_failed',
        error: error,
        stackTrace: stackTrace,
        entityType: 'project_scan_run',
        entityId: runId,
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> acceptProjectObservation(String observationId) async {
    await db.reviewProjectObservation(
      observationId: observationId,
      reviewState: 'accepted',
    );
    notifyListeners();
  }

  Future<void> acceptProjectObservations(
    Iterable<String> observationIds,
  ) async {
    await _reviewProjectObservations(observationIds, 'accepted');
  }

  Future<void> linkProjectObservation(
    String observationId,
    String atlasProjectId,
  ) async {
    await db.reviewProjectObservation(
      observationId: observationId,
      reviewState: 'linked',
      atlasProjectId: atlasProjectId,
    );
    notifyListeners();
  }

  Future<void> ignoreProjectObservation(String observationId) async {
    await db.reviewProjectObservation(
      observationId: observationId,
      reviewState: 'ignored',
    );
    notifyListeners();
  }

  Future<void> ignoreProjectObservations(
    Iterable<String> observationIds,
  ) async {
    await _reviewProjectObservations(observationIds, 'ignored');
  }

  Future<void> markProjectObservationNeedsReview(String observationId) async {
    await db.reviewProjectObservation(
      observationId: observationId,
      reviewState: 'needs_review',
    );
    notifyListeners();
  }

  Future<void> markProjectObservationsNeedsReview(
    Iterable<String> observationIds,
  ) async {
    await _reviewProjectObservations(observationIds, 'needs_review');
  }

  Future<void> _reviewProjectObservations(
    Iterable<String> observationIds,
    String reviewState,
  ) async {
    final ids = observationIds.toSet();
    if (ids.isEmpty) return;
    for (final id in ids) {
      await db.reviewProjectObservation(
        observationId: id,
        reviewState: reviewState,
      );
    }
    notifyListeners();
  }

  Future<String> buildProjectScanRunExportJson(String scanRunId) async {
    final run = await db.getProjectScanRun(scanRunId);
    if (run == null) {
      throw StateError('Project scan run not found: $scanRunId');
    }
    final observations = await db.getProjectObservationsForScanRun(scanRunId);
    final runWarnings = _decodeStringList(run.warningsJson);
    final observationWarnings = <Map<String, Object?>>[];
    for (final observation in observations) {
      final warnings = _decodeStringList(observation.warningsJson);
      for (final warning in warnings) {
        observationWarnings.add({
          'observationId': observation.id,
          'observedPath': observation.observedPath,
          'displayName': _displayNameFromObservation(observation),
          'warning': warning,
        });
      }
    }
    final payload = {
      'schema': 'project_atlas_local_operations_scan_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'summary': {
        'status': run.status,
        'roots': _decodeStringList(run.rootsJson),
        'totalSeen': run.totalSeen,
        'candidates': run.candidates,
        'ignored': run.ignored,
        'runWarnings': runWarnings.length,
        'observationWarnings': observationWarnings.length,
      },
      'scanRun': run.toJson(),
      'warnings': {'run': runWarnings, 'observations': observationWarnings},
      'observations': observations.map((row) => row.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<String> buildProjectScanRunWarningsExportJson(String scanRunId) async {
    final run = await db.getProjectScanRun(scanRunId);
    if (run == null) {
      throw StateError('Project scan run not found: $scanRunId');
    }
    final observations = await db.getProjectObservationsForScanRun(scanRunId);
    final warningsPayload = _projectScanRunWarningsPayload(run, observations);
    return const JsonEncoder.withIndent('  ').convert({
      'schema': 'project_atlas_local_operations_warnings_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      ...warningsPayload,
    });
  }

  Future<Directory> ensureOperationsScansFolder() async {
    final supportDir = await getApplicationSupportDirectory();
    final root = Directory(p.join(supportDir.path, 'operations_scans'));
    for (final child in ['runs', 'warnings', 'logs']) {
      await Directory(p.join(root.path, child)).create(recursive: true);
    }
    return root;
  }

  Future<String> saveProjectScanRunExportToAppFolder(String scanRunId) async {
    final root = await ensureOperationsScansFolder();
    final path = p.join(
      root.path,
      'runs',
      '${_safeFileStem(scanRunId)}_operations_scan.json',
    );
    await File(
      path,
    ).writeAsString(await buildProjectScanRunExportJson(scanRunId));
    return path;
  }

  Future<String> saveProjectScanRunWarningsToAppFolder(String scanRunId) async {
    final root = await ensureOperationsScansFolder();
    final path = p.join(
      root.path,
      'warnings',
      '${_safeFileStem(scanRunId)}_operations_warnings.json',
    );
    await File(
      path,
    ).writeAsString(await buildProjectScanRunWarningsExportJson(scanRunId));
    return path;
  }

  Future<void> openOperationsScansFolder() async {
    final root = await ensureOperationsScansFolder();
    await Process.start('explorer.exe', [root.path]);
  }

  List<String> _decodeStringList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((item) => '$item').toList();
    } catch (_) {}
    return const [];
  }

  String _displayNameFromObservation(ProjectObservation observation) {
    try {
      final raw = jsonDecode(observation.rawJson);
      if (raw is Map && raw['displayName'] is String) {
        final value = (raw['displayName'] as String).trim();
        if (value.isNotEmpty) return value;
      }
    } catch (_) {}
    return p.basename(observation.observedPath);
  }

  String _projectDescriptionFromRegistry(ProjectRegistryEntry entry) {
    final lines = <String>[
      'Imported from the Local Operations Registry.',
      'Local path: ${entry.localPath}',
      'Classification: ${entry.classification}',
    ];
    if ((entry.gitRoot ?? '').trim().isNotEmpty) {
      lines.add('Git root: ${entry.gitRoot}');
    }
    return lines.join('\n');
  }

  Future<ProjectFull?> _findSingleMatchingProjectForRegistryEntry(
    ProjectRegistryEntry entry,
  ) async {
    final key = _projectTitleKey(entry.displayName);
    if (key.isEmpty) return null;
    final matches = (await db.getProjectsFull())
        .where((project) => _projectTitleKey(project.title) == key)
        .toList(growable: false);
    if (matches.length > 1) {
      throw StateError(
        'Multiple Atlas projects already match "${entry.displayName}". Use Update existing in Operations to choose the target project.',
      );
    }
    return matches.isEmpty ? null : matches.single;
  }

  String _projectTitleKey(String value) => value.trim().toLowerCase();

  Future<int> _importSafeLocalProjectDocs(
    String projectId,
    String localPath,
  ) async {
    final dir = Directory(localPath);
    if (!dir.existsSync()) return 0;
    var imported = 0;
    for (final filename in _safeLocalProjectDocNames) {
      final file = File(p.join(dir.path, filename));
      if (!file.existsSync()) continue;
      try {
        final existing = await db.getProjectDocumentByOriginalFilename(
          projectId,
          filename,
        );
        if (existing != null) continue;
        await importDocumentFromPath(file.path, projectId: projectId);
        imported++;
      } catch (error) {
        await db.logEvent(
          level: 'warn',
          area: 'operations',
          action: 'local_project_doc_import_failed',
          entityType: 'project',
          entityId: projectId,
          inputJson: file.path,
          error: error.toString(),
        );
      }
    }
    return imported;
  }

  Map<String, Object?> _projectScanRunWarningsPayload(
    ProjectScanRun run,
    List<ProjectObservation> observations,
  ) {
    final runWarnings = _decodeStringList(run.warningsJson);
    final observationWarnings = <Map<String, Object?>>[];
    for (final observation in observations) {
      final warnings = _decodeStringList(observation.warningsJson);
      for (final warning in warnings) {
        observationWarnings.add({
          'observationId': observation.id,
          'observedPath': observation.observedPath,
          'displayName': _displayNameFromObservation(observation),
          'warning': warning,
        });
      }
    }
    return {
      'summary': {
        'scanRunId': run.id,
        'status': run.status,
        'roots': _decodeStringList(run.rootsJson),
        'totalSeen': run.totalSeen,
        'candidates': run.candidates,
        'ignored': run.ignored,
        'runWarnings': runWarnings.length,
        'observationWarnings': observationWarnings.length,
      },
      'scanRun': run.toJson(),
      'warnings': {'run': runWarnings, 'observations': observationWarnings},
    };
  }

  String _safeFileStem(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  Future<Draft?> getLatestProjectSummaryDraft(String projectId) =>
      db.getLatestProjectSummaryDraft(projectId);

  Future<Map<String, String?>> getDocumentPathsForProject(String projectId) =>
      db.getDocumentPathsForProject(projectId);

  /// Generates summaries for operational projects that are missing one today.
  /// Runs silently in the background — errors are swallowed per project.
  Future<void> _backgroundSummaryRefresh() async {
    await refreshMissingProjectSummaries();
  }

  Future<ProjectSummaryRefreshResult> refreshMissingProjectSummaries({
    bool force = false,
    bool includeLibrary = false,
    Duration betweenProjects = const Duration(seconds: 3),
    ProjectEnrichmentStatusCallback? onStatus,
  }) async {
    if (_summaryRefreshRunning) {
      return const ProjectSummaryRefreshResult(
        considered: 0,
        refreshed: 0,
        skipped: 0,
        failed: 0,
        aiUnavailable: false,
        alreadyRunning: true,
        errors: ['Project summary refresh is already running.'],
      );
    }
    _summaryRefreshRunning = true;
    notifyListeners();
    var considered = 0;
    var refreshed = 0;
    var skipped = 0;
    var failed = 0;
    var aiUnavailable = false;
    final errors = <String>[];
    try {
      onStatus?.call('Checking Ollama summary service.', current: 0);
      final host = await getSetting(AppDb.kOllamaHost);
      final model = await getSetting(AppDb.kOllamaModel);
      if (!await _buildOllama(host, model).isAvailable()) {
        aiUnavailable = true;
        onStatus?.call('AI summary refresh skipped: Ollama unavailable.');
        await db.logEvent(
          level: 'warn',
          area: 'ai',
          action: 'project_summary_refresh_skipped',
          outputJson: jsonEncode({'reason': 'ollama_unavailable'}),
        );
        return ProjectSummaryRefreshResult(
          considered: considered,
          refreshed: refreshed,
          skipped: skipped,
          failed: failed,
          aiUnavailable: aiUnavailable,
          errors: errors,
        );
      }
      final projects = await db.getSummaryEligibleProjects();
      onStatus?.call(
        projects.isEmpty
            ? 'No summary-eligible projects found.'
            : 'Refreshing AI summaries for ${projects.length} projects.',
        current: 0,
        total: projects.length,
      );
      for (final project in projects) {
        considered++;
        onStatus?.call(
          'Summarizing ${project.title} ($considered/${projects.length}).',
          current: considered,
          total: projects.length,
        );
        if (!force && await db.hasTodayProjectSummaryDraft(project.id)) {
          skipped++;
          onStatus?.call(
            'Skipped ${project.title}: summary exists today.',
            current: considered,
            total: projects.length,
          );
          continue;
        }
        try {
          final outcome = await summarizeProjectFull(
            project.id,
            includeLibrary: includeLibrary,
          );
          if (outcome.isSuccess) {
            refreshed++;
            onStatus?.call(
              'Summary refreshed for ${project.title}.',
              current: considered,
              total: projects.length,
            );
          } else {
            failed++;
            errors.add('${project.title}: summary returned no output');
            onStatus?.call(
              'Summary failed for ${project.title}: no output.',
              current: considered,
              total: projects.length,
            );
          }
        } catch (error) {
          failed++;
          errors.add('${project.title}: $error');
          onStatus?.call(
            'Summary failed for ${project.title}: $error',
            current: considered,
            total: projects.length,
          );
        }
        // Yield between projects to avoid locking up Ollama.
        if (betweenProjects > Duration.zero) {
          await Future<void>.delayed(betweenProjects);
        }
      }
      onStatus?.call(
        'AI summaries complete: $refreshed refreshed, $failed failed, $skipped skipped.',
        current: projects.length,
        total: projects.length,
      );
      await db.logEvent(
        area: 'ai',
        action: 'project_summary_refresh_completed',
        outputJson: jsonEncode({
          'considered': considered,
          'refreshed': refreshed,
          'skipped': skipped,
          'failed': failed,
          'force': force,
          'includeLibrary': includeLibrary,
        }),
      );
      return ProjectSummaryRefreshResult(
        considered: considered,
        refreshed: refreshed,
        skipped: skipped,
        failed: failed,
        aiUnavailable: aiUnavailable,
        errors: errors,
      );
    } finally {
      _summaryRefreshRunning = false;
      notifyListeners();
    }
  }

  // Project AI summary (with optional library context)
  Future<ProjectSummaryOutcome> summarizeProjectFull(
    String projectId, {
    bool includeLibrary = false,
  }) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);
    final proj = await getProjectFull(projectId);
    final items = await getWorkItemsForProject(projectId);

    List<ProjectRisk> risks = [];
    List<ProjectDecision> decisions = [];
    List<ProjectPerson> people = [];
    try {
      risks = await getProjectRisks(projectId);
    } catch (_) {}
    try {
      decisions = await getProjectDecisions(projectId);
    } catch (_) {}
    try {
      people = await getProjectPeople(projectId);
    } catch (_) {}

    // Build document list with excerpts
    const _kMaxCharsPerDoc = 3000;
    const _kMaxTotalDocChars = 16000;
    final contextDocs = <ProjectSummaryContextDoc>[];
    final docPaths = <String, String?>{};

    if (includeLibrary) {
      final docs = await (db.select(
        db.documents,
      )..where((t) => t.projectId.equals(projectId))).get();

      var totalChars = 0;
      for (final doc in docs) {
        docPaths[doc.id] = doc.storedPath;
        String? excerpt;
        if (totalChars < _kMaxTotalDocChars) {
          excerpt = await _readDocumentExcerpt(doc, maxChars: _kMaxCharsPerDoc);
          if (excerpt != null) {
            final remaining = _kMaxTotalDocChars - totalChars;
            if (excerpt.length > remaining) {
              excerpt = excerpt.substring(0, remaining);
            }
            totalChars += excerpt.length;
          }
        }
        final canOpen =
            doc.storedPath != null &&
            doc.storedPath!.isNotEmpty &&
            const [
              'md',
              'txt',
              'json',
              'csv',
              'pdf',
              'docx',
              'doc',
            ].contains(doc.extension?.toLowerCase());
        contextDocs.add(
          ProjectSummaryContextDoc(
            id: doc.id,
            title: doc.title,
            extension: doc.extension,
            excerpt: excerpt,
            storedPath: doc.storedPath,
            canOpenInExplorer: canOpen,
          ),
        );
      }
    }

    final context = ProjectSummaryContext(
      id: projectId,
      title: proj?.title ?? projectId,
      description: proj?.description,
      desiredOutcome: proj?.desiredOutcome,
      successCriteria: proj?.successCriteria,
      status: proj?.status ?? 'active',
      phase: proj?.phase,
      priority: proj?.priority,
      owner: proj?.owner,
      workItems: items
          .map(
            (i) => ProjectSummaryContextWorkItem(
              id: i.id,
              title: i.title,
              status: i.status,
              priority: i.priority,
              owner: i.owner,
              blockedReason: i.blockedReason,
              dueAt: i.dueAt,
            ),
          )
          .toList(),
      people: people
          .map(
            (p) => ProjectSummaryContextPerson(
              id: p.id,
              name: p.name,
              role: p.role,
              authority: p.authority,
            ),
          )
          .toList(),
      risks: risks
          .map(
            (r) => ProjectSummaryContextRisk(
              id: r.id,
              title: r.title,
              severity: r.severity,
              description: r.desc,
            ),
          )
          .toList(),
      decisions: decisions
          .map(
            (d) => ProjectSummaryContextDecision(
              id: d.id,
              title: d.title,
              context: d.ctx,
              decider: d.decider,
            ),
          )
          .toList(),
      documents: contextDocs,
    );

    ProjectSummaryOutcome outcome;
    try {
      final (:result, :parsed) = await svc.summarizeProjectStructured(
        context: context,
      );
      outcome = ProjectSummaryOutcome(
        rawOutput: result.output,
        structured: parsed,
        documentPaths: docPaths,
      );
    } catch (e) {
      // Fall back to old prose summary on unexpected error
      final blocked = items
          .where((i) => i.blockedReason != null)
          .map((i) => '${i.title} — ${i.blockedReason}')
          .toList();
      final active = items
          .where((i) => !['done', 'archived'].contains(i.status))
          .map((i) => i.title)
          .toList();
      final done = items
          .where((i) => i.status == 'done')
          .map((i) => i.title)
          .take(5)
          .toList();
      final oldResult = await svc.summarizeProject(
        projectTitle: proj?.title ?? projectId,
        activeItems: active,
        blockedItems: blocked,
        completedRecently: done,
      );
      outcome = ProjectSummaryOutcome(
        rawOutput: oldResult.output,
        documentPaths: docPaths,
      );
    }

    // Persist as a draft so the project detail screen can load instantly next time.
    if (outcome.isSuccess) {
      try {
        // Replace any existing summary drafts for this project.
        await db.deleteProjectSummaryDrafts(projectId);
        await db.saveDraft(
          kind: 'project_summary',
          title: 'Project Summary — ${proj?.title ?? projectId}',
          body: outcome.rawOutput ?? '',
          inputJson: outcome.rawOutput,
          projectId: projectId,
        );
      } catch (_) {}
    }

    return outcome;
  }

  /// Read a bounded text excerpt from a document, trying in order:
  /// 1. extractedText, 2. renderedMarkdown, 3. disk read for text-like files.
  Future<String?> _readDocumentExcerpt(
    Document doc, {
    int maxChars = 3000,
  }) async {
    String? cap(String? s) {
      if (s == null || s.trim().isEmpty) return null;
      return s.length > maxChars ? s.substring(0, maxChars) : s;
    }

    final fromExtracted = cap(doc.extractedText);
    if (fromExtracted != null) return fromExtracted;

    final fromMarkdown = cap(doc.renderedMarkdown);
    if (fromMarkdown != null) return fromMarkdown;

    final path = doc.storedPath;
    final ext = doc.extension?.toLowerCase();
    if (path != null &&
        path.isNotEmpty &&
        const ['md', 'txt', 'json', 'csv'].contains(ext)) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final text = await file.readAsString();
          return cap(text);
        }
      } catch (_) {}
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Documents
  // ---------------------------------------------------------------------------

  Stream<List<Document>> watchDocuments() => db.watchDocuments();

  Future<void> importDocumentFromPath(String path, {String? projectId}) async {
    try {
      await db.logEvent(
        area: 'documents',
        action: 'import_request',
        inputJson: path,
      );
      await db.importDocumentFromPath(
        path,
        projectId: projectId ?? activeProject?.id,
      );
      notifyListeners();
    } catch (e, st) {
      await db.logError(
        area: 'documents',
        action: 'import_failed',
        error: e,
        stackTrace: st,
        inputJson: path,
      );
      rethrow;
    }
  }

  Stream<List<Document>> watchDocumentsForWorkItem(String workItemId) =>
      db.watchDocumentsForWorkItem(workItemId);

  Future<void> linkDocumentToWorkItem(
    String documentId,
    String workItemId,
  ) async {
    await db.linkDocumentToWorkItem(documentId, workItemId);
    await db.logEvent(
      area: 'documents',
      action: 'document_linked',
      entityType: 'work_item',
      entityId: workItemId,
      inputJson: jsonEncode({'documentId': documentId}),
    );
    notifyListeners();
  }

  Future<void> unlinkDocumentFromWorkItem(
    String documentId,
    String workItemId,
  ) async {
    await db.unlinkDocumentFromWorkItem(documentId, workItemId);
    await db.logEvent(
      area: 'documents',
      action: 'document_unlinked',
      entityType: 'work_item',
      entityId: workItemId,
      inputJson: jsonEncode({'documentId': documentId}),
    );
    notifyListeners();
  }

  Stream<List<WorkItemNote>> watchNotesForWorkItem(String workItemId) =>
      db.watchNotesForWorkItem(workItemId);

  Future<void> addWorkItemNote(String workItemId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    await db.addWorkItemNote(workItemId, trimmed);
    await db.logEvent(
      area: 'work_item_detail',
      action: 'note_created',
      entityType: 'work_item',
      entityId: workItemId,
    );
    notifyListeners();
  }

  Future<void> updateWorkItemNote(String noteId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    await db.updateWorkItemNote(noteId, trimmed);
    await db.logEvent(
      area: 'work_item_detail',
      action: 'note_updated',
      entityType: 'work_item_note',
      entityId: noteId,
    );
    notifyListeners();
  }

  Future<void> deleteWorkItemNote(String noteId) async {
    await db.deleteWorkItemNote(noteId);
    await db.logEvent(
      area: 'work_item_detail',
      action: 'note_deleted',
      entityType: 'work_item_note',
      entityId: noteId,
    );
    notifyListeners();
  }

  Stream<List<WorkItemAnalysis>> watchAnalysesForWorkItem(String workItemId) =>
      db.watchAnalysesForWorkItem(workItemId);

  Future<OllamaResult> analyzeWorkItemReadOnly(String workItemId) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final modelName = model?.trim().isNotEmpty == true
        ? model!.trim()
        : 'qwen3.5:9b';
    final svc = _buildOllama(host, modelName);
    final item = await getWorkItem(workItemId);
    if (item == null) {
      await db.logEvent(
        level: 'error',
        area: 'work_item_detail',
        action: 'analysis_missing_work_item',
        entityType: 'work_item',
        entityId: workItemId,
      );
      return const OllamaResult(
        input: 'Missing work item',
        output: null,
        kind: 'work_item_analysis',
        title: 'Work Item Analysis',
      );
    }

    final docs = await db.getDocumentsForWorkItem(workItemId);
    final linkedDocuments = docs
        .map(
          (d) => LinkedDocumentContext(
            title: d.title,
            text: d.extractedText ?? d.renderedMarkdown ?? '',
          ),
        )
        .toList(growable: false);

    try {
      await db.logEvent(
        area: 'ollama',
        action: 'work_item_analysis_requested',
        entityType: 'work_item',
        entityId: workItemId,
        inputJson: jsonEncode({
          'model': modelName,
          'documentCount': docs.length,
        }),
      );
      final result = await svc.analyzeWorkItemReadOnly(
        title: item.title,
        description: item.description,
        status: item.status,
        priority: item.priority,
        blockedReason: item.blockedReason,
        linkedDocuments: linkedDocuments,
      );
      if (result.isSuccess) {
        await db.saveWorkItemAnalysis(
          workItemId: workItemId,
          prompt: result.input,
          output: result.output!,
          model: modelName,
        );
        await db.logEvent(
          area: 'ollama',
          action: 'work_item_analysis_saved',
          entityType: 'work_item',
          entityId: workItemId,
          outputJson: jsonEncode({'model': modelName}),
        );
        notifyListeners();
      } else {
        await db.logEvent(
          level: 'error',
          area: 'ollama',
          action: 'work_item_analysis_empty',
          entityType: 'work_item',
          entityId: workItemId,
          inputJson: result.input,
        );
      }
      return result;
    } catch (e, st) {
      await db.logError(
        area: 'ollama',
        action: 'work_item_analysis_failed',
        entityType: 'work_item',
        entityId: workItemId,
        inputJson: item.title,
        error: e,
        stackTrace: st,
      );
      return OllamaResult(
        input: item.title,
        output: 'Ollama request failed: $e',
        kind: 'work_item_analysis',
        title: 'Work Item Analysis',
      );
    }
  }

  Stream<List<EventLogData>> watchRecentEvents() => db.watchRecentEvents();
  Future<List<EventLogData>> getRecentEvents() => db.getRecentEvents();
  Future<void> clearEventLog() => db.clearEventLog();

  Future<String> getAppDataPath() async {
    final supportDir = await getApplicationSupportDirectory();
    final docsDir = p.join(
      (await getApplicationDocumentsDirectory()).path,
      'atlas_documents',
    );
    return '${supportDir.path}\n$docsDir';
  }

  Future<void> openAppDataFolder() async {
    final supportDir = await getApplicationSupportDirectory();
    await Process.start('explorer.exe', [supportDir.path]);
    final docsDir = Directory(
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        'atlas_documents',
      ),
    );
    if (docsDir.existsSync()) {
      await Process.start('explorer.exe', [docsDir.path]);
    }
  }

  Future<int> exportOperationalBackupToJson(String path) async {
    final allDocs = await db.select(db.documents).get();
    final allMedia = await db.getAllProjectMedia();

    final payload = {
      'schema': 'project_atlas_operational_backup_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'projects': (await db.select(db.projects).get())
          .map((row) => row.toJson())
          .toList(),
      'tags': (await db.getTags()).map((row) => row.toJson()).toList(),
      'projectTags': (await db.select(db.projectTags).get())
          .map((row) => row.toJson())
          .toList(),
      'projectMedia': allMedia.map((row) => row.toJson()).toList(),
      'stages': (await db.select(db.stages).get())
          .map((row) => row.toJson())
          .toList(),
      'workItems': (await db.select(db.workItems).get())
          .map((row) => row.toJson())
          .toList(),
      'workItemNotes': (await db.select(db.workItemNotes).get())
          .map((row) => row.toJson())
          .toList(),
      'workItemAnalyses': (await db.select(db.workItemAnalyses).get())
          .map((row) => row.toJson())
          .toList(),
      'documents': allDocs.map((row) => row.toJson()).toList(),
      'documentLinks': (await db.select(db.documentLinks).get())
          .map((row) => row.toJson())
          .toList(),
      'contacts': (await db.getContacts()).map((row) => row.toJson()).toList(),
      'projectPeople': (await db.select(db.projectPeople).get())
          .map((row) => row.toJson())
          .toList(),
      'projectRisks': (await db.select(db.projectRisks).get())
          .map((row) => row.toJson())
          .toList(),
      'projectDecisions': (await db.select(db.projectDecisions).get())
          .map((row) => row.toJson())
          .toList(),
      'projectRegistry': (await db.select(db.projectRegistry).get())
          .map((row) => row.toJson())
          .toList(),
      'projectScanRuns': (await db.select(db.projectScanRuns).get())
          .map((row) => row.toJson())
          .toList(),
      'projectObservations': (await db.select(db.projectObservations).get())
          .map((row) => row.toJson())
          .toList(),
      'dailyReviews': (await db.select(db.dailyReviews).get())
          .map((row) => row.toJson())
          .toList(),
      'outboxMessages': (await db.select(db.outboxMessages).get())
          .map((row) => row.toJson())
          .toList(),
    };

    final archive = Archive();

    // Add backup.json
    final jsonBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    archive.addFile(ArchiveFile('backup.json', jsonBytes.length, jsonBytes));

    // Add document files
    for (final doc in allDocs) {
      if (doc.storedPath != null) {
        final f = File(doc.storedPath!);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          final name = 'documents/${doc.id}.${doc.extension ?? 'bin'}';
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }
      }
    }

    // Add project media files
    for (final m in allMedia) {
      final f = File(m.storedPath);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        final ext = m.extension ?? m.storedPath.split('.').lastOrNull ?? 'bin';
        archive.addFile(ArchiveFile('media/${m.id}.$ext', bytes.length, bytes));
      }
    }

    // Write ZIP
    final zipBytes = ZipEncoder().encode(archive)!;
    await File(path).writeAsBytes(zipBytes);

    await db.logEvent(
      area: 'backup',
      action: 'operational_backup_exported',
      outputJson: jsonEncode({'path': path}),
    );
    return payload.length;
  }

  Future<ProjectBundleExportPreview> previewProjectBundleExport(
    String projectId, {
    bool includeFiles = true,
  }) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) {
      throw StateError('Project not found: $projectId');
    }
    final stages = await db.getStagesForProject(projectId);
    final workItems = await db.getWorkItemsForProject(projectId);
    final workItemIds = workItems.map((item) => item.id).toList();
    final notes = workItemIds.isEmpty
        ? const <WorkItemNote>[]
        : await (db.select(
            db.workItemNotes,
          )..where((t) => t.workItemId.isIn(workItemIds))).get();
    final analyses = workItemIds.isEmpty
        ? const <WorkItemAnalysis>[]
        : await (db.select(
            db.workItemAnalyses,
          )..where((t) => t.workItemId.isIn(workItemIds))).get();
    final docs = await db.getDocumentsForProject(projectId);
    final media = await db.getProjectMedia(projectId);
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    final observations = registry == null
        ? const <ProjectObservation>[]
        : await (db.select(db.projectObservations)
                ..where((t) => t.observedPath.equals(registry.localPath))
                ..orderBy([(t) => OrderingTerm.desc(t.observedAt)]))
              .get();
    final refreshItems = registry == null
        ? const <LocalProjectRefreshItem>[]
        : await (db.select(
            db.localProjectRefreshItems,
          )..where((t) => t.registryId.equals(registry.id))).get();
    var copiedDocumentFiles = 0;
    var copiedMediaFiles = 0;
    final warnings = <String>[];
    if (includeFiles) {
      for (final doc in docs) {
        final storedPath = doc.storedPath;
        if (storedPath == null) continue;
        if (await File(storedPath).exists()) {
          copiedDocumentFiles++;
        } else {
          warnings.add('Document file missing: ${doc.originalFilename}');
        }
      }
      for (final item in media) {
        if (await File(item.storedPath).exists()) {
          copiedMediaFiles++;
        } else {
          warnings.add('Media file missing: ${item.originalFilename}');
        }
      }
    }

    return ProjectBundleExportPreview(
      schema: 'project_atlas_project_bundle_v1',
      projectId: projectId,
      projectTitle: project.title,
      includeFiles: includeFiles,
      stages: stages.length,
      workItems: workItems.length,
      workItemNotes: notes.length,
      workItemAnalyses: analyses.length,
      documents: docs.length,
      copiedDocumentFiles: copiedDocumentFiles,
      media: media.length,
      copiedMediaFiles: copiedMediaFiles,
      people: (await db.getProjectPeople(projectId)).length,
      risks: (await db.getProjectRisks(projectId)).length,
      decisions: (await db.getProjectDecisions(projectId)).length,
      hasRegistry: registry != null,
      observations: observations.length,
      refreshItems: refreshItems.length,
      warnings: List.unmodifiable(warnings),
    );
  }

  Future<int> exportProjectBundleToZip(
    String projectId,
    String path, {
    bool includeFiles = true,
  }) async {
    final preview = await previewProjectBundleExport(
      projectId,
      includeFiles: includeFiles,
    );
    final project = await db.getProjectFull(projectId);
    if (project == null) {
      throw StateError('Project not found: $projectId');
    }
    final stages = await db.getStagesForProject(projectId);
    final workItems = await db.getWorkItemsForProject(projectId);
    final workItemIds = workItems.map((item) => item.id).toList();
    final docs = await db.getDocumentsForProject(projectId);
    final media = await db.getProjectMedia(projectId);
    final registry = await db.getProjectRegistryByAtlasProjectId(projectId);
    final observations = registry == null
        ? const <ProjectObservation>[]
        : await (db.select(db.projectObservations)
                ..where((t) => t.observedPath.equals(registry.localPath))
                ..orderBy([(t) => OrderingTerm.desc(t.observedAt)]))
              .get();
    final refreshItems = registry == null
        ? const <LocalProjectRefreshItem>[]
        : await (db.select(
            db.localProjectRefreshItems,
          )..where((t) => t.registryId.equals(registry.id))).get();

    final payload = {
      'schema': 'project_atlas_project_bundle_v1',
      'exportedAt': DateTime.now().toIso8601String(),
      'project': project.toJson(),
      'stages': stages.map((row) => row.toJson()).toList(),
      'workItems': workItems.map((row) => row.toJson()).toList(),
      'workItemNotes': workItemIds.isEmpty
          ? const []
          : (await (db.select(
                  db.workItemNotes,
                )..where((t) => t.workItemId.isIn(workItemIds))).get())
                .map((row) => row.toJson())
                .toList(),
      'workItemAnalyses': workItemIds.isEmpty
          ? const []
          : (await (db.select(
                  db.workItemAnalyses,
                )..where((t) => t.workItemId.isIn(workItemIds))).get())
                .map((row) => row.toJson())
                .toList(),
      'documents': docs.map((row) => row.toJson()).toList(),
      'projectMedia': media.map((row) => row.toJson()).toList(),
      'projectPeople': (await db.getProjectPeople(
        projectId,
      )).map((row) => row.toJson()).toList(),
      'projectRisks': (await db.getProjectRisks(
        projectId,
      )).map((row) => row.toJson()).toList(),
      'projectDecisions': (await db.getProjectDecisions(
        projectId,
      )).map((row) => row.toJson()).toList(),
      'projectRegistry': registry?.toJson(),
      'projectObservations': observations.map((row) => row.toJson()).toList(),
      'localProjectRefreshItems': refreshItems
          .map((row) => row.toJson())
          .toList(),
    };

    final archive = Archive();
    final jsonBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    archive.addFile(
      ArchiveFile('project_bundle.json', jsonBytes.length, jsonBytes),
    );

    if (includeFiles) {
      for (final doc in docs) {
        final storedPath = doc.storedPath;
        if (storedPath == null) continue;
        final file = File(storedPath);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final ext = doc.extension == null ? '' : '.${doc.extension}';
        final name =
            'documents/${_safeFileStem(doc.originalFilename)}_${doc.id}$ext';
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
      for (final item in media) {
        final file = File(item.storedPath);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final ext = item.extension == null ? '' : '.${item.extension}';
        final name =
            'media/${_safeFileStem(item.originalFilename)}_${item.id}$ext';
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
    }

    final zipBytes = ZipEncoder().encode(archive)!;
    await File(path).writeAsBytes(zipBytes);
    await db.logEvent(
      area: 'export',
      action: 'project_bundle_exported',
      entityType: 'project',
      entityId: projectId,
      outputJson: jsonEncode({
        'path': path,
        'includeFiles': includeFiles,
        'atlasRecords': preview.atlasRecordCount,
        'copiedFiles': preview.copiedFileCount,
        'warnings': preview.warnings,
      }),
    );
    return payload.length;
  }

  // ---------------------------------------------------------------------------
  // Telegram
  // ---------------------------------------------------------------------------

  Future<TelegramService?> _buildTelegram() async {
    final token = await getSetting(AppDb.kTelegramBotToken);
    final chatId = await getSetting(AppDb.kTelegramChatId);
    if (token == null || token.isEmpty || chatId == null || chatId.isEmpty) {
      return null;
    }
    return TelegramService(botToken: token, chatId: chatId);
  }

  Future<(bool, String?)> sendTodayToTelegram() async {
    final svc = await _buildTelegram();
    if (svc == null) {
      return (
        false,
        'Telegram not configured. Add bot token and chat ID in Settings.',
      );
    }

    final items = await getTodayItems();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Resolve project labels via DB (not string-prefix hacks)
    Future<String> projectLabel(WorkItem item) async {
      final stage = await (db.select(
        db.stages,
      )..where((t) => t.id.equals(item.stageId))).getSingleOrNull();
      if (stage == null) return item.stageId;
      final proj = await (db.select(
        db.projects,
      )..where((t) => t.id.equals(stage.projectId))).getSingleOrNull();
      return proj?.title ?? stage.projectId;
    }

    String fmtDate(DateTime? dt) => dt == null ? '' : '${dt.month}/${dt.day}';

    final doingItems =
        <
          ({
            String title,
            String project,
            String stage,
            String? dueDate,
            String priority,
          })
        >[];
    final overdueItems =
        <
          ({
            String title,
            String project,
            String stage,
            String? dueDate,
            String priority,
          })
        >[];
    final dueTodayItems =
        <
          ({
            String title,
            String project,
            String stage,
            String? dueDate,
            String priority,
          })
        >[];
    final phoneItems =
        <({String title, String project, String stage, String priority})>[];
    final blockedItems = <({String title, String blockedReason})>[];

    for (final i in items) {
      final label = await projectLabel(i);
      final rec = (
        title: i.title,
        project: label,
        stage: i.stageId,
        dueDate: fmtDate(i.dueAt),
        priority: i.priority,
      );

      if (i.status == 'doing') {
        doingItems.add(rec);
      } else if (i.dueAt != null && i.dueAt!.isBefore(today)) {
        overdueItems.add(rec);
      } else if (i.dueAt != null &&
          i.dueAt!.isBefore(today.add(const Duration(days: 1)))) {
        dueTodayItems.add(rec);
      } else if (i.phoneQueue) {
        phoneItems.add((
          title: i.title,
          project: label,
          stage: i.stageId,
          priority: i.priority,
        ));
      }
      if (i.blockedReason != null) {
        blockedItems.add((title: i.title, blockedReason: i.blockedReason!));
      }
    }

    final message = TelegramService.formatTodayList(
      date: '${now.month}/${now.day}/${now.year}',
      doingItems: doingItems,
      overdueItems: overdueItems,
      dueTodayItems: dueTodayItems,
      blockedItems: blockedItems,
      phoneQueueItems: phoneItems,
    );

    // Record in outbox BEFORE sending so we have a trace even if send fails
    final outboxId = await db.addOutboxMessage(
      channel: 'telegram',
      title: "Today's Task List",
      body: message,
    );

    final (ok, err) = await svc.sendMessage(message);

    if (ok) {
      await db.markOutboxSent(outboxId);
    } else {
      await db.markOutboxFailed(outboxId, err ?? 'Unknown error');
    }

    return (ok, err);
  }

  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _summaryRefreshTimer?.cancel();
    _localProjectRefreshTimer?.cancel();
    _activeProjectSub.cancel();
    hasActiveProject.dispose();
    super.dispose();
  }
}

class ContactResponsibilities {
  final List<Project> ownedProjects;
  final List<Project> contributingProjects;
  final List<ProjectPerson> projectPeople;
  final List<WorkItem> workItems;

  const ContactResponsibilities({
    required this.ownedProjects,
    required this.contributingProjects,
    required this.projectPeople,
    required this.workItems,
  });
}
