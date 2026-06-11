import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    db.ensureDefaultStagesForProjects();
  }

  late final StreamSubscription<Project?> _activeProjectSub;
  Project? _activeProject;

  Project? get activeProject => _activeProject;
  final ValueNotifier<bool> hasActiveProject = ValueNotifier<bool>(false);

  // ---------------------------------------------------------------------------
  // Projects
  // ---------------------------------------------------------------------------

  Stream<List<Project>> watchProjects() => db.watchProjects();
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
      workItemId: workItemId,
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

  // Documents for project
  Stream<List<Document>> watchDocumentsForProject(String projectId) =>
      db.watchDocumentsForProject(projectId);

  // Project AI summary (with optional library context)
  Future<OllamaResult> summarizeProjectFull(
    String projectId, {
    bool includeLibrary = false,
  }) async {
    final host = await getSetting(AppDb.kOllamaHost);
    final model = await getSetting(AppDb.kOllamaModel);
    final svc = _buildOllama(host, model);
    final proj = await getProjectFull(projectId);
    final items = await getWorkItemsForProject(projectId);
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

    String? docContext;
    if (includeLibrary) {
      final docs = await (db.select(
        db.documents,
      )..where((t) => t.projectId.equals(projectId))).get();
      if (docs.isNotEmpty) {
        docContext = docs
            .map(
              (d) =>
                  '### ${d.title}\n${d.extractedText ?? d.renderedMarkdown ?? ''}',
            )
            .join('\n\n');
      }
    }

    final extraContext = [
      if (proj?.description != null) 'Purpose: ${proj!.description}',
      if (proj?.desiredOutcome != null)
        'Desired outcome: ${proj!.desiredOutcome}',
      if (proj?.successCriteria != null)
        'Success criteria: ${proj!.successCriteria}',
      if (docContext != null) 'Library documents:\n$docContext',
    ].join('\n');
    if (extraContext.isNotEmpty) active.insert(0, extraContext);

    return svc.summarizeProject(
      projectTitle: proj?.title ?? projectId,
      activeItems: active,
      blockedItems: blocked,
      completedRecently: done,
    );
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
            text: d.renderedMarkdown ?? d.extractedText ?? '',
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
