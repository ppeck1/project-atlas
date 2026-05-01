import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../db/app_db.dart';
import '../../services/ollama_service.dart';
import '../../services/telegram_service.dart';

/// App-wide state wrapper around [AppDb].
class AppState extends ChangeNotifier {
  final AppDb db;

  AppState(this.db) {
    _activeProjectSub = db.watchActiveProject().listen((p) {
      _activeProject = p;
      hasActiveProject.value = p != null;
      notifyListeners();
    });
  }

  late final StreamSubscription<Project?> _activeProjectSub;
  Project? _activeProject;

  Project? get activeProject => _activeProject;
  final ValueNotifier<bool> hasActiveProject = ValueNotifier<bool>(false);

  // ---------------------------------------------------------------------------
  // Projects
  // ---------------------------------------------------------------------------

  Stream<List<Project>> watchProjects() => db.watchProjects();
  Stream<Project?> watchActiveProject() => db.watchActiveProject();

  Future<void> createProject(String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await db.createProject(id, t, DateTime.now());
    await db.logEvent(area: 'ui', action: 'create_project', entityType: 'project', entityId: id, inputJson: t);
    notifyListeners();
  }

  Future<void> setActiveById(String id) async {
    await db.setActiveProjectId(id);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Stages
  // ---------------------------------------------------------------------------

  Stream<List<Stage>> watchStagesForProject(String projectId) =>
      db.watchStagesForProject(projectId);

  Stream<Stage?> watchActiveStageForProject(String projectId) =>
      db.watchActiveStageForProject(projectId);

  Future<void> setActiveStageForProject(
      String projectId, String stageId) async {
    await db.setActiveStageIdForProject(projectId, stageId);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Work items
  // ---------------------------------------------------------------------------

  Stream<List<WorkItem>> watchWorkItemsForStage(String stageId) =>
      db.watchWorkItemsForStage(stageId);

  Stream<List<WorkItem>> watchTodayItems() => db.watchTodayItems();

  Future<void> addWorkItem(
    String stageId,
    String title, {
    String? description,
    String? owner,
    String status = 'next',
    String priority = 'normal',
    DateTime? dueAt,
    String? source,
  }) async {
    await db.logEvent(area: 'ui', action: 'create_task_request', entityType: 'stage', entityId: stageId, inputJson: title);
    await db.addWorkItem(
      stageId: stageId,
      title: title,
      description: description,
      owner: owner,
      status: status,
      priority: priority,
      dueAt: dueAt,
      source: source,
    );
    await db.logEvent(area: 'ui', action: 'create_task_success', entityType: 'stage', entityId: stageId, inputJson: title);
    notifyListeners();
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
    await db.logEvent(area: 'ui', action: 'update_task_request', entityType: 'work_item', entityId: id);
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
    await db.logEvent(area: 'ui', action: 'update_task_success', entityType: 'work_item', entityId: id);
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

  Future<void> saveDraft({
    required String kind,
    required String title,
    required String body,
    String? inputJson,
    String? projectId,
    String? workItemId,
  }) async {
    await db.saveDraft(
        kind: kind,
        title: title,
        body: body,
        inputJson: inputJson,
        projectId: projectId,
        workItemId: workItemId);
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
        model: model?.trim().isNotEmpty == true ? model!.trim() : 'mistral',
      );

  Future<OllamaResult> summarizeProject(String projectId) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final proj = await (db.select(db.projects)
          ..where((t) => t.id.equals(projectId)))
        .getSingleOrNull();

    // Resolve items by querying stages that belong to this project
    final projectStages = await db.getStagesForProject(projectId);
    final stageIds = projectStages.map((s) => s.id).toSet();

    final all = await db.getAllActiveWorkItems();
    final projectItems =
        all.where((i) => stageIds.contains(i.stageId)).toList();

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
      doingItems:
          items.where((i) => i.status == 'doing').map((i) => i.title).toList(),
      overdueItems: items
          .where((i) =>
              i.dueAt != null && i.dueAt!.isBefore(today) && i.status != 'doing')
          .map((i) => i.title)
          .toList(),
      dueTodayItems: items
          .where((i) =>
              i.dueAt != null &&
              !i.dueAt!.isBefore(today) &&
              i.dueAt!.isBefore(today.add(const Duration(days: 1))))
          .map((i) => i.title)
          .toList(),
      blockedItems: items
          .where((i) => i.blockedReason != null)
          .map((i) => '${i.title} ��������� ${i.blockedReason}')
          .toList(),
    );
  }

  Future<OllamaResult> draftEmailForTask(
      String workItemId, String instruction) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final item = await getWorkItem(workItemId);
    if (item == null) {
      return OllamaResult(
          input: instruction,
          output: null,
          kind: 'email_draft',
          title: 'Email Draft');
    }

    return svc.draftEmail(
      taskTitle: item.title,
      taskDescription: item.description,
      blockedReason: item.blockedReason,
      instruction: instruction,
    );
  }

  Future<OllamaResult> extractTasksFromNote(
      String projectId, String rawNote) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);

    final proj = await (db.select(db.projects)
          ..where((t) => t.id.equals(projectId)))
        .getSingleOrNull();

    return svc.extractTasksFromNote(
      rawNote: rawNote,
      projectTitle: proj?.title ?? projectId,
    );
  }


  // ---------------------------------------------------------------------------
  // Documents
  // ---------------------------------------------------------------------------

  Stream<List<Document>> watchDocuments() => db.watchDocuments();

  Future<void> importDocumentFromPath(String path, {String? projectId}) async {
    try {
      await db.logEvent(area: 'documents', action: 'import_request', inputJson: path);
      await db.importDocumentFromPath(path, projectId: projectId ?? activeProject?.id);
      notifyListeners();
    } catch (e, st) {
      await db.logError(area: 'documents', action: 'import_failed', error: e, stackTrace: st, inputJson: path);
      rethrow;
    }
  }

  Stream<List<EventLogData>> watchRecentEvents() => db.watchRecentEvents();
  Future<List<EventLogData>> getRecentEvents() => db.getRecentEvents();
  Future<void> clearEventLog() => db.clearEventLog();

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
        'Telegram not configured. Add bot token and chat ID in Settings.'
      );
    }

    final items = await getTodayItems();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Resolve project labels via DB (not string-prefix hacks)
    Future<String> projectLabel(WorkItem item) async {
      final stage = await (db.select(db.stages)
            ..where((t) => t.id.equals(item.stageId)))
          .getSingleOrNull();
      if (stage == null) return item.stageId;
      final proj = await (db.select(db.projects)
            ..where((t) => t.id.equals(stage.projectId)))
          .getSingleOrNull();
      return proj?.title ?? stage.projectId;
    }

    String fmtDate(DateTime? dt) =>
        dt == null ? '' : '${dt.month}/${dt.day}';

    final doingItems = <({String title, String project, String stage, String? dueDate, String priority})>[];
    final overdueItems = <({String title, String project, String stage, String? dueDate, String priority})>[];
    final dueTodayItems = <({String title, String project, String stage, String? dueDate, String priority})>[];
    final phoneItems = <({String title, String project, String stage, String priority})>[];
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
    _activeProjectSub.cancel();
    hasActiveProject.dispose();
    super.dispose();
  }
}
