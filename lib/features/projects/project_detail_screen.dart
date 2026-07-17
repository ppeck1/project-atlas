import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../db/app_db.dart';
import '../../services/local_git_visibility_service.dart';
import '../../services/project_summary_models.dart';
import '../../shared/models/app_state.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/models/project_metadata.dart';
import '../../shared/widgets/contact_picker.dart';
import '../../shared/widgets/create_work_item_dialog.dart';
import 'detail/git_visibility_dialog.dart';
import 'detail/local_repo_section.dart';
import 'detail/project_change_log_section.dart';
import 'detail/project_closure_section.dart';
import 'detail/project_command_toolbar.dart';
import 'detail/project_decisions_section.dart';
import 'detail/project_delete_dialog.dart';
import 'detail/project_detail_atoms.dart';
import 'detail/project_identity_section.dart';
import 'detail/project_media_section.dart';
import 'detail/project_people_section.dart';
import 'detail/project_quick_bar.dart';
import 'detail/project_risks_section.dart';
import 'detail/project_runtime_section.dart';
import 'detail/project_tags_section.dart';
import 'detail/project_work_section.dart';
import 'detail/shopify_seo_section.dart';
import 'detail/summary_run_provenance.dart';
import 'project_metadata_dialog.dart';
import '../today/work_item_detail_sheet.dart';
import '../work/status_priority_helpers.dart';

// ─── Design tokens ─────────────────────────────────────────────────────────
const _kPrimary = Color(0xFF79A7FF);
const _kPanel = Color(0xFF151A22);
const _kLine = Color(0xFF273044);

String _prettyJsonObject(Map<String, Object?> value) =>
    const JsonEncoder.withIndent('  ').convert(value);
Map<String, Object?> _parseJsonObject(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const <String, Object?>{};
  final decoded = jsonDecode(trimmed);
  if (decoded is! Map) {
    throw const FormatException('Context must be a JSON object.');
  }
  return decoded.map((key, value) => MapEntry('$key', value));
}

String _workboardRouteForProject(String projectId) {
  return Uri(
    path: '/work',
    queryParameters: {'projectId': projectId, 'scope': 'project'},
  ).toString();
}

IconData _projectMediaIcon(String mediaType) {
  return switch (mediaType) {
    'image' => Icons.image_outlined,
    'video' => Icons.movie_outlined,
    'audio' => Icons.audiotrack_outlined,
    'folder' => Icons.folder_outlined,
    _ => Icons.attach_file,
  };
}

const _kPriorities = ['low', 'normal', 'high', 'urgent'];

class _LlmTaskEditResult {
  final String action;
  final String projectId;
  final String? workItemId;
  final String title;
  final String objective;
  final String priority;
  final Map<String, Object?> context;
  final String? reason;

  const _LlmTaskEditResult({
    required this.action,
    required this.projectId,
    required this.workItemId,
    required this.title,
    required this.objective,
    required this.priority,
    required this.context,
    this.reason,
  });
}

// ─── Main widget ──────────────────────────────────────────────────────────
class _ProjectDetailSectionDefinition {
  final String id;
  final String title;

  const _ProjectDetailSectionDefinition({
    required this.id,
    required this.title,
  });
}

const _projectDetailSections = <_ProjectDetailSectionDefinition>[
  _ProjectDetailSectionDefinition(id: 'tags', title: 'Tags'),
  _ProjectDetailSectionDefinition(id: 'identity', title: 'Project Identity'),
  _ProjectDetailSectionDefinition(id: 'shopify_seo', title: 'Shopify SEO'),
  _ProjectDetailSectionDefinition(id: 'local_repo', title: 'Local Repo'),
  _ProjectDetailSectionDefinition(id: 'runtime', title: 'Runtime'),
  _ProjectDetailSectionDefinition(id: 'people', title: 'People & Roles'),
  _ProjectDetailSectionDefinition(id: 'work', title: 'Project Workboard'),
  _ProjectDetailSectionDefinition(id: 'risks', title: 'Risks & Issues'),
  _ProjectDetailSectionDefinition(id: 'decisions', title: 'Decision Log'),
  _ProjectDetailSectionDefinition(id: 'change_log', title: 'Change Log'),
  _ProjectDetailSectionDefinition(id: 'media', title: 'Media & Documents'),
  _ProjectDetailSectionDefinition(id: 'closure', title: 'Closure'),
];

const _projectDetailDefaultSectionIds = <String>[
  'tags',
  'identity',
  'shopify_seo',
  'local_repo',
  'runtime',
  'people',
  'work',
  'risks',
  'decisions',
  'change_log',
  'media',
  'closure',
];

class ProjectDetailScreen extends StatefulWidget {
  final String projectId;
  const ProjectDetailScreen({super.key, required this.projectId});

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  String? _expandedSection = 'identity';
  bool _taskHeaderExpanded = true;
  bool _aiExpanded = false;
  bool _includeLibrary = false;
  bool _summaryLoading = false;
  String? _summaryText;
  ProjectSummaryOutcome? _summaryOutcome;
  DateTime? _summaryGeneratedAt;
  ProjectSummaryEvidencePacket? _summaryEvidencePacket;
  bool _summaryEvidenceLoading = false;
  Set<String> _visibleSectionIds = _projectDetailDefaultSectionIds.toSet();

  List<WorkItem> _workItems = const [];
  List<LlmTaskQueueItem> _llmQueueItems = const [];
  List<ProjectPerson> _people = const [];
  List<ProjectRisk> _risks = const [];
  List<ProjectDecision> _decisions = const [];
  bool _didLoad = false;

  Stream<Project?>? _watchProject;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchProject ??= AppStateScope.of(context).watchProject(widget.projectId);
    if (!_didLoad) {
      _didLoad = true;
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    final state = AppStateScope.read(context);
    // Each query is independent — a schema mismatch on one table (e.g. a
    // missing column that _ensureProjectCompatibilityColumns hasn't patched
    // yet on this run) must not prevent the others from loading.
    final items = await state.getWorkItemsForProject(widget.projectId);
    List<LlmTaskQueueItem> llmTasks = _llmQueueItems;
    try {
      llmTasks = await state.getLlmTasksForProject(widget.projectId, limit: 50);
    } catch (e) {
      debugPrint('[Atlas] _loadProjectDetail: getLlmTasksForProject failed (continuing with cached): $e');
    }
    final people = await state.getProjectPeople(widget.projectId);
    List<ProjectRisk> risks = _risks;
    try {
      risks = await state.getProjectRisks(widget.projectId);
    } catch (e) {
      debugPrint('[Atlas] _loadProjectDetail: getProjectRisks failed (continuing with cached): $e');
    }
    List<ProjectDecision> decisions = _decisions;
    try {
      decisions = await state.getProjectDecisions(widget.projectId);
    } catch (e) {
      debugPrint('[Atlas] _loadProjectDetail: getProjectDecisions failed (continuing with cached): $e');
    }
    final summarySettings = await state.loadProjectAiSummarySettings();
    final sectionVisibility = await state.loadProjectDetailSectionVisibility(
      widget.projectId,
      _projectDetailDefaultSectionIds,
    );

    Draft? cachedDraft;
    if (summarySettings.enabled) {
      try {
        cachedDraft = await state.getLatestProjectSummaryDraft(
          widget.projectId,
        );
      } catch (e) {
        debugPrint('[Atlas] _loadProjectDetail: getLatestProjectSummaryDraft failed (continuing without cached draft): $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _workItems = items;
      _llmQueueItems = llmTasks;
      _people = people;
      _risks = risks;
      _decisions = decisions;
      _includeLibrary = summarySettings.includeLibrary;
      _visibleSectionIds = sectionVisibility.visibleSectionIds;
      _summaryEvidenceLoading = summarySettings.enabled;
      if (!summarySettings.enabled) _summaryEvidencePacket = null;
    });

    if (summarySettings.enabled) {
      unawaited(
        _loadSummaryEvidence(includeLibrary: summarySettings.includeLibrary),
      );
    }

    if (cachedDraft != null &&
        _summaryOutcome == null &&
        _summaryText == null) {
      final docPaths = await state.getDocumentPathsForProject(widget.projectId);
      final structured =
          ProjectSummaryResult.tryParse(cachedDraft.body) ??
          ProjectSummaryResult.tryParse(cachedDraft.inputJson);
      if (!mounted) return;
      setState(() {
        _summaryGeneratedAt = cachedDraft!.createdAt;
        _aiExpanded = true;
        if (structured != null) {
          _summaryOutcome = ProjectSummaryOutcome(
            rawOutput: cachedDraft.body,
            inputText: cachedDraft.inputJson,
            structured: structured,
            documentPaths: docPaths,
          );
        } else {
          _summaryText = cachedDraft.body.trim().isEmpty
              ? null
              : cachedDraft.body;
        }
      });
    }
  }

  Future<void> _loadSummaryEvidence({bool? includeLibrary}) async {
    if (!mounted) return;
    final state = AppStateScope.read(context);
    final resolvedIncludeLibrary = includeLibrary ?? _includeLibrary;
    setState(() => _summaryEvidenceLoading = true);
    try {
      final packet = await state.buildProjectSummaryEvidencePacket(
        widget.projectId,
        includeLibrary: resolvedIncludeLibrary,
      );
      if (!mounted) return;
      setState(() {
        _summaryEvidencePacket = packet;
        _summaryEvidenceLoading = false;
      });
    } catch (e) {
      debugPrint('[Atlas] _loadSummaryEvidence: buildProjectSummaryEvidencePacket failed: $e');
      if (!mounted) return;
      setState(() => _summaryEvidenceLoading = false);
    }
  }

  void _setIncludeLibrary(bool value) {
    setState(() => _includeLibrary = value);
    unawaited(_loadSummaryEvidence(includeLibrary: value));
  }

  void _toggleSection(String key) =>
      setState(() => _expandedSection = _expandedSection == key ? null : key);

  bool _sectionVisible(String sectionId) =>
      _visibleSectionIds.contains(sectionId);

  Future<void> _openProjectWorkboard(
    BuildContext context,
    Project project,
  ) async {
    final state = AppStateScope.of(context);
    await state.setActiveById(project.id);
    if (context.mounted) {
      context.go(_workboardRouteForProject(project.id));
    }
  }

  Future<void> _addProjectTask(BuildContext context) async {
    final state = AppStateScope.read(context);
    final draft = await showCreateWorkItemDialog(context);
    if (draft == null) return;
    DateTime? dueAt;
    final rawDate = draft['dueAt'];
    if (rawDate != null && rawDate.isNotEmpty) {
      dueAt = DateTime.tryParse(rawDate);
    }
    await state.addWorkItemToProject(
      widget.projectId,
      draft['title']!,
      description: draft['description'],
      owner: draft['owner'],
      status: normalizeStatusValue(draft['status']),
      priority: normalizePriorityValue(draft['priority']),
      dueAt: dueAt,
      blockedReason: draft['blockedReason'],
      readiness: draft['readiness'] ?? 'ready',
      size: draft['size'] ?? 'medium',
      risk: draft['risk'] ?? 'low_code',
      suggestedActor: draft['suggestedActor'] ?? 'user',
      verificationNeeded: draft['verificationNeeded'] ?? 'none',
      nextAction: draft['nextAction'],
      planningNotes: draft['planningNotes'],
    );
    await _loadAll();
  }

  Future<void> _showCreateLlmTaskDialog(BuildContext context) async {
    final state = AppStateScope.read(context);
    final title = TextEditingController();
    final objective = TextEditingController();
    final contextNotes = TextEditingController();
    final attachmentPaths = <String>[];
    var priority = 'normal';
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Queue LLM task'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title'),
                  autofocus: true,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: objective,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Objective'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: priority,
                  decoration: const InputDecoration(labelText: 'Priority'),
                  items: const ['low', 'normal', 'high', 'urgent']
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setDialogState(() => priority = value);
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: contextNotes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Context'),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final result = await FilePicker.platform.pickFiles(
                        allowMultiple: true,
                        type: FileType.any,
                      );
                      if (result == null) return;
                      final paths = result.files
                          .map((file) => file.path)
                          .whereType<String>()
                          .where((path) => path.trim().isNotEmpty);
                      setDialogState(() => attachmentPaths.addAll(paths));
                    },
                    icon: const Icon(Icons.attach_file, size: 16),
                    label: const Text('Attach media'),
                  ),
                ),
                if (attachmentPaths.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ...attachmentPaths.map(
                    (path) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.perm_media_outlined, size: 18),
                      title: Text(
                        p.basename(path),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () =>
                            setDialogState(() => attachmentPaths.remove(path)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.add_task, size: 16),
              label: const Text('Queue'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true) return;
    final cleanTitle = title.text.trim();
    final cleanObjective = objective.text.trim();
    if (cleanTitle.isEmpty || cleanObjective.isEmpty) return;
    final taskId = await state.enqueueLlmTask(
      projectId: widget.projectId,
      title: cleanTitle,
      objective: cleanObjective,
      priority: priority,
      createdBy: 'ui',
      context: {
        if (contextNotes.text.trim().isNotEmpty)
          'notes': contextNotes.text.trim(),
        'source': 'project_detail_header',
      },
    );
    for (final path in attachmentPaths) {
      await state.importLlmTaskMediaFromPath(taskId, path);
    }
    await _loadAll();
  }

  Future<void> _showLlmQueueManagerDialog(BuildContext context) async {
    final state = AppStateScope.read(context);
    final items = await state.getLlmTasksForProject(
      widget.projectId,
      limit: 100,
    );
    if (!context.mounted) return;
    final selected = await showDialog<LlmTaskQueueItem>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('LLM queue'),
        content: SizedBox(
          width: 620,
          height: 520,
          child: items.isEmpty
              ? const Center(
                  child: Text(
                    'No queued LLM tasks.',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: _kLine),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: Icon(
                        _llmQueueIcon(item.status),
                        color: _llmQueueColor(item.status),
                      ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${item.status} - ${item.priority} - updated ${compactDateTime(item.updatedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(dialogContext).pop(item),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    await _showEditLlmTaskDialog(context, selected);
  }

  Future<void> _showEditLlmTaskDialog(
    BuildContext context,
    LlmTaskQueueItem item,
  ) async {
    final state = AppStateScope.read(context);
    final projects = await state.getVisibleProjects();
    final projectIds = projects.map((project) => project.id).toSet();
    final selectedInitialProjectId = projectIds.contains(item.projectId)
        ? item.projectId
        : widget.projectId;
    var selectedProjectId = selectedInitialProjectId;
    var workItems = await state.getWorkItemsForProject(selectedProjectId);
    var selectedWorkItemId =
        item.workItemId != null &&
            workItems.any((workItem) => workItem.id == item.workItemId)
        ? item.workItemId
        : null;
    if (!context.mounted) return;

    final title = TextEditingController(text: item.title);
    final objective = TextEditingController(text: item.objective);
    final contextJson = TextEditingController(
      text: _prettyJsonObject(item.context),
    );
    final cancelReason = TextEditingController();
    var attachments = await state.getMediaForLlmTask(item.id);
    if (!context.mounted) return;
    var priority = item.priority;
    String? errorText;
    final editable = item.status != 'completed';

    final result = await showDialog<_LlmTaskEditResult>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> switchProject(String projectId) async {
            setDialogState(() {
              selectedProjectId = projectId;
              selectedWorkItemId = null;
              workItems = const [];
            });
            final loaded = await state.getWorkItemsForProject(projectId);
            if (!dialogContext.mounted) return;
            setDialogState(() => workItems = loaded);
          }

          Future<void> attachMedia() async {
            final result = await FilePicker.platform.pickFiles(
              allowMultiple: true,
              type: FileType.any,
            );
            if (result == null) return;
            for (final file in result.files) {
              final path = file.path;
              if (path == null || path.trim().isEmpty) continue;
              await state.importLlmTaskMediaFromPath(item.id, path);
            }
            final loaded = await state.getMediaForLlmTask(item.id);
            if (!dialogContext.mounted) return;
            setDialogState(() => attachments = loaded);
          }

          Future<void> unlinkMedia(ProjectMediaItem media) async {
            await state.unlinkProjectMediaFromLlmTask(item.id, media.id);
            final loaded = await state.getMediaForLlmTask(item.id);
            if (!dialogContext.mounted) return;
            setDialogState(() => attachments = loaded);
          }

          _LlmTaskEditResult? buildSaveResult() {
            final cleanTitle = title.text.trim();
            final cleanObjective = objective.text.trim();
            if (cleanTitle.isEmpty || cleanObjective.isEmpty) {
              setDialogState(
                () => errorText = 'Title and objective are required.',
              );
              return null;
            }
            Map<String, Object?> parsedContext;
            try {
              parsedContext = _parseJsonObject(contextJson.text);
            } on FormatException catch (error) {
              setDialogState(() => errorText = error.message);
              return null;
            } catch (error) {
              setDialogState(
                () => errorText = 'Context JSON is invalid: $error',
              );
              return null;
            }
            setDialogState(() => errorText = null);
            return _LlmTaskEditResult(
              action: 'save',
              projectId: selectedProjectId,
              workItemId: selectedWorkItemId,
              title: cleanTitle,
              objective: cleanObjective,
              priority: priority,
              context: parsedContext,
            );
          }

          final terminalLabel = switch (item.status) {
            'failed' => 'Failed',
            'cancelled' => 'Cancelled',
            _ => 'Completed',
          };

          return AlertDialog(
            title: const Text('LLM task'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        MiniPill('Status', item.status),
                        MiniPill('Attempts', '${item.attempts}'),
                        if (item.leasedBy != null)
                          MiniPill('Leased', item.leasedBy!),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Created ${compactDateTime(item.createdAt)} by ${item.createdBy}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                    if (item.completedAt != null)
                      Text(
                        '$terminalLabel ${compactDateTime(item.completedAt)}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    if (item.error != null && item.error!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          item.error!,
                          style: const TextStyle(
                            color: Color(0xFFFF8A80),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedProjectId,
                      decoration: const InputDecoration(labelText: 'Project'),
                      items: projects
                          .map(
                            (project) => DropdownMenuItem(
                              value: project.id,
                              child: Text(project.title),
                            ),
                          )
                          .toList(),
                      onChanged: editable
                          ? (value) {
                              if (value != null) switchProject(value);
                            }
                          : null,
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String?>(
                      value: selectedWorkItemId,
                      decoration: const InputDecoration(
                        labelText: 'Work item anchor',
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('No linked work item'),
                        ),
                        ...workItems.map(
                          (workItem) => DropdownMenuItem<String?>(
                            value: workItem.id,
                            child: Text(
                              workItem.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: editable
                          ? (value) =>
                                setDialogState(() => selectedWorkItemId = value)
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: title,
                      enabled: editable,
                      decoration: const InputDecoration(labelText: 'Title'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: objective,
                      enabled: editable,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(labelText: 'Objective'),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: _kPriorities.contains(priority)
                          ? priority
                          : 'normal',
                      decoration: const InputDecoration(labelText: 'Priority'),
                      items: _kPriorities
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                      onChanged: editable
                          ? (value) {
                              if (value != null) {
                                setDialogState(() => priority = value);
                              }
                            }
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: contextJson,
                      enabled: editable,
                      minLines: 4,
                      maxLines: 8,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        labelText: 'Context JSON',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Media attachments',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (editable)
                          OutlinedButton.icon(
                            onPressed: attachMedia,
                            icon: const Icon(Icons.attach_file, size: 16),
                            label: const Text('Attach'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (attachments.isEmpty)
                      const Text(
                        'No media attached.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      )
                    else
                      ...attachments.map(
                        (media) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            _projectMediaIcon(media.mediaType),
                            size: 18,
                          ),
                          title: Text(
                            media.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            media.originalFilename,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: editable
                              ? IconButton(
                                  tooltip: 'Unlink media',
                                  icon: const Icon(Icons.link_off, size: 18),
                                  onPressed: () => unlinkMedia(media),
                                )
                              : null,
                        ),
                      ),
                    if (editable) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: cancelReason,
                        minLines: 1,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Cancel reason',
                        ),
                      ),
                    ],
                    if (errorText != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        errorText!,
                        style: const TextStyle(color: Color(0xFFFF8A80)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
              if (editable && item.status != 'cancelled')
                TextButton.icon(
                  onPressed: () => Navigator.of(dialogContext).pop(
                    _LlmTaskEditResult(
                      action: 'cancel',
                      projectId: selectedProjectId,
                      workItemId: selectedWorkItemId,
                      title: title.text,
                      objective: objective.text,
                      priority: priority,
                      context: const {},
                      reason: cancelReason.text.trim(),
                    ),
                  ),
                  icon: const Icon(Icons.cancel_outlined, size: 16),
                  label: const Text('Cancel task'),
                ),
              if ({'failed', 'cancelled'}.contains(item.status))
                TextButton.icon(
                  onPressed: () => Navigator.of(dialogContext).pop(
                    _LlmTaskEditResult(
                      action: 'requeue',
                      projectId: selectedProjectId,
                      workItemId: selectedWorkItemId,
                      title: title.text,
                      objective: objective.text,
                      priority: priority,
                      context: const {},
                    ),
                  ),
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('Requeue'),
                ),
              if (editable)
                FilledButton.icon(
                  onPressed: () {
                    final saveResult = buildSaveResult();
                    if (saveResult != null) {
                      Navigator.of(dialogContext).pop(saveResult);
                    }
                  },
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Save'),
                ),
            ],
          );
        },
      ),
    );
    if (result == null) return;

    try {
      switch (result.action) {
        case 'save':
          await state.updateLlmTask(
            taskId: item.id,
            projectId: result.projectId,
            workItemId: result.workItemId,
            title: result.title,
            objective: result.objective,
            priority: result.priority,
            context: result.context,
          );
          break;
        case 'cancel':
          await state.cancelLlmTask(
            item.id,
            reason: result.reason?.trim().isEmpty == true
                ? null
                : result.reason,
          );
          break;
        case 'requeue':
          await state.requeueLlmTask(item.id);
          break;
      }
      await _loadAll();
      if (!context.mounted) return;
      final moved =
          result.action == 'save' && result.projectId != widget.projectId;
      final message = switch (result.action) {
        'cancel' => 'LLM task cancelled.',
        'requeue' => 'LLM task requeued.',
        _ => moved ? 'LLM task moved to another project.' : 'LLM task updated.',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('LLM task update failed: $error')));
    }
  }

  Future<void> _generateSummary() async {
    final state = AppStateScope.of(context);
    setState(() {
      _summaryLoading = true;
      _summaryText = null;
      _summaryOutcome = null;
      _summaryGeneratedAt = null;
      _summaryEvidenceLoading = true;
    });
    try {
      final packet = await state.buildProjectSummaryEvidencePacket(
        widget.projectId,
        includeLibrary: _includeLibrary,
      );
      if (!mounted) return;
      setState(() {
        _summaryEvidencePacket = packet;
        _summaryEvidenceLoading = false;
      });
      final outcome = await state.summarizeProjectFull(
        widget.projectId,
        includeLibrary: _includeLibrary,
        evidencePacket: packet,
        trigger: 'manual',
      );
      if (!mounted) return;
      final now = DateTime.now();
      if (outcome.hasStructured) {
        setState(() {
          _summaryOutcome = outcome;
          _summaryGeneratedAt = now;
        });
      } else {
        final rawText = outcome.rawOutput?.trim().isEmpty == true
            ? 'No output from model.'
            : (outcome.rawOutput ?? 'No output from model.');
        final text = outcome.hasValidationIssues
            ? [
                'Validation failed:',
                for (final issue in outcome.validationIssues)
                  '- ${issue.code}: ${issue.message}',
                '',
                'Raw output:',
                rawText,
              ].join('\n')
            : rawText;
        setState(() {
          _summaryText = text;
          _summaryGeneratedAt = now;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _summaryText = 'Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _summaryLoading = false;
          _summaryEvidenceLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<Project?>(
      stream: _watchProject,
      builder: (context, snap) {
        if (snap.data == null &&
            snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final project = snap.data;
        if (project == null) {
          return Scaffold(
            appBar: AppBar(
              leading: _BackBtn(onTap: () => context.go('/projects')),
              leadingWidth: 110,
              title: const Text('Project not found'),
            ),
            body: Center(
              child: TextButton.icon(
                onPressed: () => context.go('/projects'),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to projects'),
              ),
            ),
          );
        }

        // Compute metrics from loaded work items
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final active = _workItems
            .where((i) => !['done', 'archived'].contains(i.status))
            .toList();
        final blockedCount = active
            .where((i) => i.blockedReason != null)
            .length;
        final overdueCount = active
            .where((i) => i.dueAt != null && i.dueAt!.isBefore(today))
            .length;
        final urgentCount = active.where((i) => i.priority == 'urgent').length;

        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: _BackBtn(onTap: () => context.go('/projects')),
            leadingWidth: 110,
            title: Text(
              project.title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: 'Project detail display settings',
                icon: const Icon(Icons.settings_outlined, size: 20),
                onPressed: () => _showSectionVisibilityDialog(context),
              ),
              IconButton(
                tooltip: 'Open work board',
                icon: const Icon(Icons.view_kanban_outlined, size: 20),
                onPressed: () => _openProjectWorkboard(context, project),
              ),
              IconButton(
                tooltip: 'Delete project',
                icon: const Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Color(0x99F44336),
                ),
                onPressed: () => _showDeleteDialog(context, project),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ProjectCommandToolbar(
                projectId: widget.projectId,
                onOpenWorkboard: () => _openProjectWorkboard(context, project),
                onEditMeta: () => _showMetaDialog(context, project),
                onExportBundle: () =>
                    _showProjectBundleExportDialog(context, project.title),
              ),
              const SizedBox(height: 8),
              _ProjectTaskHeaderPanel(
                projectId: widget.projectId,
                items: _workItems,
                llmQueueItems: _llmQueueItems,
                expanded: _taskHeaderExpanded,
                onToggle: () =>
                    setState(() => _taskHeaderExpanded = !_taskHeaderExpanded),
                onAddProjectTask: () => _addProjectTask(context),
                onAddLlmTask: () => _showCreateLlmTaskDialog(context),
                onOpenWorkboard: () => _openProjectWorkboard(context, project),
                onRefresh: _loadAll,
                onOpenTask: (item) async {
                  await showWorkItemDetailSheet(context, item.id);
                  await _loadAll();
                },
                onOpenLlmTask: (item) => _showEditLlmTaskDialog(context, item),
                onManageLlmTasks: () => _showLlmQueueManagerDialog(context),
              ),
              const SizedBox(height: 8),

              if (state.projectAiSummariesEnabled) ...[
                _AiPanel(
                  projectId: widget.projectId,
                  expanded: _aiExpanded,
                  includeLibrary: _includeLibrary,
                  summaryLoading: _summaryLoading,
                  summaryText: _summaryText,
                  summaryOutcome: _summaryOutcome,
                  generatedAt: _summaryGeneratedAt,
                  evidencePacket: _summaryEvidencePacket,
                  evidenceLoading: _summaryEvidenceLoading,
                  onToggle: () => setState(() => _aiExpanded = !_aiExpanded),
                  onToggleLibrary: _setIncludeLibrary,
                  onGenerate: _generateSummary,
                ),
                const SizedBox(height: 8),
              ],

              // Status quick bar + metric cards
              ProjectQuickBar(
                project: project,
                activeCount: active.length,
                blockedCount: blockedCount,
                overdueCount: overdueCount,
                urgentCount: urgentCount,
                onEditMeta: () => _showMetaDialog(context, project),
              ),
              const SizedBox(height: 8),

              // Expandable sections
              if (_sectionVisible('tags'))
                _Section(
                  id: 'tags',
                  title: 'Tags',
                  subtitle: 'Separate home, work, personal, and other contexts',
                  expanded: _expandedSection == 'tags',
                  onTap: () => _toggleSection('tags'),
                  child: ProjectTagsSection(
                    projectId: widget.projectId,
                    onEdit: () => _showTagsDialog(context),
                  ),
                ),
              if (_sectionVisible('identity'))
                _Section(
                  id: 'identity',
                  title: 'Project Identity',
                  subtitle: 'Purpose, outcome, success criteria, scope',
                  expanded: _expandedSection == 'identity',
                  onTap: () => _toggleSection('identity'),
                  child: ProjectIdentitySection(
                    projectId: widget.projectId,
                    project: project,
                    onEdit: () => _showIdentityDialog(context, project),
                    onReplaceGithub: () => _replaceGithubMetadata(context),
                    onForgetGithub: () => _forgetGithubMetadata(context),
                  ),
                ),
              if (_sectionVisible('shopify_seo'))
                _Section(
                  id: 'shopify_seo',
                  title: 'Shopify SEO',
                  subtitle: 'Product review table and product-level batches',
                  expanded: _expandedSection == 'shopify_seo',
                  onTap: () => _toggleSection('shopify_seo'),
                  child: ShopifySeoSection(projectId: widget.projectId),
                ),
              if (_sectionVisible('local_repo'))
                _Section(
                  id: 'local_repo',
                  title: 'Local Repo',
                  subtitle: 'Refresh from reviewed local project files',
                  expanded: _expandedSection == 'local_repo',
                  onTap: () => _toggleSection('local_repo'),
                  child: LocalRepoSection(
                    projectId: widget.projectId,
                    onChooseLocalRepo: () => _replaceLocalRepoLink(context),
                    onAssociateFile: () => _associateLocalFile(context),
                    onAssociateFolder: () => _associateLocalFolder(context),
                    onPreviewRefresh: () =>
                        _showProjectReconciliationDialog(context),
                    onExportBundle: () =>
                        _showProjectBundleExportDialog(context, project.title),
                    onInspectGit: () => _showGitVisibilityDialog(context),
                    onRefreshGithub: () => _refreshGithubMetadata(context),
                  ),
                ),
              if (_sectionVisible('runtime'))
                _Section(
                  id: 'runtime',
                  title: 'Runtime',
                  subtitle: 'Launch, tests, and capsule checks',
                  expanded: _expandedSection == 'runtime',
                  onTap: () => _toggleSection('runtime'),
                  child: ProjectRuntimeSection(
                    projectId: widget.projectId,
                    onEdit: () => _showMetaDialog(context, project),
                  ),
                ),
              if (_sectionVisible('people'))
                _Section(
                  id: 'people',
                  title: 'People & Roles',
                  subtitle: 'Who is involved and what do they own?',
                  expanded: _expandedSection == 'people',
                  onTap: () => _toggleSection('people'),
                  child: ProjectPeopleSection(
                    people: _people,
                    onAdd: () => _showAddPersonDialog(context),
                    onEdit: (p) => _showEditPersonDialog(context, p),
                    onDelete: (p) async {
                      await state.deleteProjectPerson(p.id);
                      await _loadAll();
                    },
                  ),
                ),
              if (_sectionVisible('work'))
                _Section(
                  id: 'work',
                  title: 'Project Workboard',
                  subtitle: 'Project-scoped tasks, grouped by status',
                  expanded: _expandedSection == 'work',
                  onTap: () => _toggleSection('work'),
                  child: ProjectWorkSection(
                    projectId: widget.projectId,
                    items: _workItems,
                    onChanged: _loadAll,
                    onAddProjectTask: () => _addProjectTask(context),
                    onOpenWorkboard: () =>
                        _openProjectWorkboard(context, project),
                  ),
                ),
              if (_sectionVisible('risks'))
                _Section(
                  id: 'risks',
                  title: 'Risks & Issues',
                  subtitle: 'What might break, what is already broken?',
                  expanded: _expandedSection == 'risks',
                  onTap: () => _toggleSection('risks'),
                  child: ProjectRisksSection(
                    risks: _risks,
                    onAdd: () => _showAddRiskDialog(context),
                    onDelete: (r) async {
                      await state.deleteProjectRisk(r.id);
                      await _loadAll();
                    },
                  ),
                ),
              if (_sectionVisible('decisions'))
                _Section(
                  id: 'decisions',
                  title: 'Decision Log',
                  subtitle: 'What was decided, why, and by whom?',
                  expanded: _expandedSection == 'decisions',
                  onTap: () => _toggleSection('decisions'),
                  child: ProjectDecisionsSection(
                    decisions: _decisions,
                    onAdd: () => _showAddDecisionDialog(context),
                    onDelete: (d) async {
                      await state.deleteProjectDecision(d.id);
                      await _loadAll();
                    },
                  ),
                ),
              if (_sectionVisible('change_log'))
                _Section(
                  id: 'change_log',
                  title: 'Change Log',
                  subtitle: 'Who changed what, and when',
                  expanded: _expandedSection == 'change_log',
                  onTap: () => _toggleSection('change_log'),
                  child: ProjectChangeLogSection(projectId: widget.projectId),
                ),
              if (_sectionVisible('media'))
                _Section(
                  id: 'media',
                  title: 'Media & Documents',
                  subtitle: 'Images, reference files, and project evidence',
                  expanded: _expandedSection == 'media',
                  onTap: () => _toggleSection('media'),
                  child: ProjectMediaSection(
                    projectId: widget.projectId,
                    onImportMedia: () => _showImportMediaDialog(context),
                  ),
                ),
              if (_sectionVisible('closure'))
                _Section(
                  id: 'closure',
                  title: 'Closure',
                  subtitle:
                      normalizeProjectStatusValue(project.status) == 'completed'
                      ? 'Completed'
                      : 'Open project',
                  expanded: _expandedSection == 'closure',
                  onTap: () => _toggleSection('closure'),
                  child: ProjectClosureSection(
                    project: project,
                    onEdit: () => _showClosureDialog(context, project),
                    onComplete: () => state.updateProjectMeta(
                      widget.projectId,
                      {'status': 'completed'},
                    ),
                    onArchive: () => state.updateProjectMeta(widget.projectId, {
                      'status': 'archived',
                    }),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ── Dialogs ───────────────────────────────────────────────────────────────

  Future<void> _showProjectReconciliationDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    ProjectReconciliationPreview reconciliation;
    try {
      reconciliation = await state.previewProjectReconciliation(
        widget.projectId,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reconcile preview failed: $error')),
      );
      return;
    }
    if (!context.mounted) return;
    final preview = reconciliation.localRefreshPreview;
    if (reconciliation.outcome == 'blocked' || preview == null) {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Project reconciliation'),
          content: SizedBox(
            width: 680,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    MiniPill('Outcome', reconciliation.outcome),
                    MiniPill('Boundary', reconciliation.writeBoundary),
                    MiniPill(
                      'Source repos mutated',
                      reconciliation.sourceReposMutated ? 'yes' : 'no',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (reconciliation.blockers.isNotEmpty) ...[
                  const Text(
                    'Blocked',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  for (final blocker in reconciliation.blockers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        blocker,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.amber,
                        ),
                      ),
                    ),
                ] else
                  const Text(
                    'No local refresh plan is available for this project.',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                const SizedBox(height: 12),
                for (final channel in reconciliation.channels)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      '${channel.name}: ${channel.status} '
                      '(${channel.processed} checked, ${channel.eligible} eligible)',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white60,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx, rootNavigator: true).maybePop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }
    final selected = preview.entries
        .where((entry) => entry.shouldApplyByDefault)
        .map((entry) => entry.action.id)
        .toSet();
    final selectedActionIds = await showDialog<Set<String>>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Preview project reconciliation'),
          content: SizedBox(
            width: 760,
            height: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview.localPath,
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    MiniPill('Outcome', reconciliation.outcome),
                    MiniPill('Boundary', reconciliation.writeBoundary),
                    MiniPill('Profile', preview.profile),
                    if ((preview.branch ?? '').isNotEmpty)
                      MiniPill('Branch', preview.branch!),
                    if ((preview.headSha ?? '').isNotEmpty)
                      MiniPill('SHA', shortSha(preview.headSha!)),
                    if (preview.dirtyCount != null)
                      MiniPill('Dirty', '${preview.dirtyCount}'),
                  ],
                ),
                if (reconciliation.warnings.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    reconciliation.warnings.join('\n'),
                    style: const TextStyle(fontSize: 11, color: Colors.amber),
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: preview.entries.isEmpty
                      ? const Center(
                          child: Text(
                            'No refreshable local project entries found.',
                            style: TextStyle(color: Colors.white38),
                          ),
                        )
                      : ListView.builder(
                          itemCount: preview.entries.length,
                          itemBuilder: (context, index) {
                            final entry = preview.entries[index];
                            final canSelect = entry.status != 'unchanged';
                            return CheckboxListTile(
                              value: selected.contains(entry.action.id),
                              onChanged: canSelect
                                  ? (value) => setLocal(() {
                                      if (value == true) {
                                        selected.add(entry.action.id);
                                      } else {
                                        selected.remove(entry.action.id);
                                      }
                                    })
                                  : null,
                              title: Text(entry.action.title),
                              subtitle: Text(
                                '${entry.action.targetType} - ${entry.status}\n${entry.action.detail}',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              secondary: _StatusDot(status: entry.status),
                              controlAffinity: ListTileControlAffinity.leading,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx, rootNavigator: true).maybePop();
              },
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      Navigator.of(
                        ctx,
                        rootNavigator: true,
                      ).maybePop(Set<String>.from(selected));
                    },
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Apply selected to Atlas'),
            ),
          ],
        ),
      ),
    );
    if (selectedActionIds == null || selectedActionIds.isEmpty) return;
    if (!context.mounted) return;
    try {
      final result = await state.applyLocalProjectRefresh(
        widget.projectId,
        selectedActionIds: selectedActionIds,
      );
      await _loadAll();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Reconcile applied to Atlas: ${result.created} created, ${result.updated} updated, ${result.unchanged} unchanged.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reconcile apply failed: $error')));
    }
  }

  Future<void> _replaceLocalRepoLink(BuildContext context) async {
    final state = AppStateScope.of(context);
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose local project folder',
    );
    if (path == null || path.trim().isEmpty) return;
    try {
      final registry = await state.replaceProjectLocalRepoLink(
        widget.projectId,
        path,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Local repo linked: ${registry.displayName}')),
      );
      setState(() {});
      await _loadAll();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Local repo link failed: $error')));
    }
  }

  Future<void> _associateLocalFile(BuildContext context) async {
    final state = AppStateScope.of(context);
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || path.trim().isEmpty) return;
    try {
      await state.associateProjectFile(widget.projectId, path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Associated file added.')));
      setState(() {});
      await _loadAll();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Associated file failed: $error')));
    }
  }

  Future<void> _associateLocalFolder(BuildContext context) async {
    final state = AppStateScope.of(context);
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose associated folder',
    );
    if (path == null || path.trim().isEmpty) return;
    try {
      await state.associateProjectFolder(widget.projectId, path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Associated folder added.')));
      setState(() {});
      await _loadAll();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Associated folder failed: $error')),
      );
    }
  }

  Future<void> _showGitVisibilityDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    LocalGitVisibilityReport report;
    try {
      report = await state.inspectLocalGitVisibility(widget.projectId);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Git inspection failed: $error')));
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => GitVisibilityDialog(report: report),
    );
  }

  Future<void> _refreshGithubMetadata(BuildContext context) async {
    final state = AppStateScope.of(context);
    try {
      final status = await state.refreshProjectGithubRemoteMetadata(
        widget.projectId,
      );
      if (!context.mounted) return;
      final label = status.hasError
          ? 'GitHub metadata check saved with warning.'
          : 'GitHub metadata refreshed: ${status.fullName} (${status.visibility ?? 'unknown'}).';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(label)));
      setState(() {});
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GitHub metadata refresh failed: $error')),
      );
    }
  }

  Future<void> _replaceGithubMetadata(BuildContext context) async {
    final state = AppStateScope.of(context);
    final existing = await state.getLatestProjectGitRemoteStatus(
      widget.projectId,
    );
    if (!context.mounted) return;
    final ctrl = TextEditingController(
      text: existing?.htmlUrl ?? existing?.remoteUrl ?? '',
    );
    final remoteUrl = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Replace GitHub repository'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'GitHub URL',
            hintText: 'https://github.com/owner/repo',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (remoteUrl == null || remoteUrl.trim().isEmpty) return;
    try {
      final status = await state.saveManualProjectGithubRemoteMetadata(
        widget.projectId,
        remoteUrl,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GitHub repository saved: ${status.fullName}.')),
      );
      setState(() {});
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GitHub repository save failed: $error')),
      );
    }
  }

  Future<void> _forgetGithubMetadata(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Forget cached GitHub repository?'),
        content: const Text(
          'Atlas will remove the cached GitHub metadata for this project. This does not edit the local git remote on disk.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await AppStateScope.of(
        context,
      ).clearProjectGithubRemoteMetadata(widget.projectId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cached GitHub repository forgotten.')),
      );
      setState(() {});
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GitHub repository forget failed: $error')),
      );
    }
  }

  Future<void> _showProjectBundleExportDialog(
    BuildContext context,
    String projectTitle,
  ) async {
    final state = AppStateScope.of(context);
    final safeTitle = projectTitle
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final defaultPath =
        '${Directory.current.path}\\${safeTitle}_project_bundle.zip';
    final pathCtrl = TextEditingController(text: defaultPath);
    var includeFiles = true;
    var previewFuture = state.previewProjectBundleExport(
      widget.projectId,
      includeFiles: includeFiles,
    );
    final request = await showDialog<_ProjectBundleExportRequest>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Export project bundle'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: pathCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ZIP output path',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: includeFiles,
                  onChanged: (value) => setLocal(() {
                    includeFiles = value ?? true;
                    previewFuture = state.previewProjectBundleExport(
                      widget.projectId,
                      includeFiles: includeFiles,
                    );
                  }),
                  title: const Text('Include copied document and media files'),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 8),
                FutureBuilder<ProjectBundleExportPreview>(
                  future: previewFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const LinearProgressIndicator(minHeight: 2);
                    }
                    if (snapshot.hasError) {
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0x22FF9800),
                          border: Border.all(color: const Color(0x66FF9800)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('Preview failed: ${snapshot.error}'),
                      );
                    }
                    final preview = snapshot.data!;
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0x22111622),
                        border: Border.all(color: _kLine),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              MiniPill(
                                'Atlas records',
                                '${preview.atlasRecordCount}',
                              ),
                              MiniPill('Documents', '${preview.documents}'),
                              MiniPill(
                                'Copied files',
                                '${preview.copiedFileCount}',
                              ),
                              MiniPill('Work', '${preview.workItems}'),
                              MiniPill('Risks', '${preview.risks}'),
                              MiniPill('Decisions', '${preview.decisions}'),
                              MiniPill(
                                'Observations',
                                '${preview.observations}',
                              ),
                              MiniPill(
                                'Refresh ledger',
                                '${preview.refreshItems}',
                              ),
                            ],
                          ),
                          if (preview.warnings.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            ...preview.warnings
                                .take(4)
                                .map(
                                  (warning) => Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      warning,
                                      style: const TextStyle(
                                        color: Color(0xFFFFB74D),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () {
                final path = pathCtrl.text.trim();
                if (path.isEmpty) return;
                Navigator.of(ctx).pop(
                  _ProjectBundleExportRequest(
                    path: path,
                    includeFiles: includeFiles,
                  ),
                );
              },
              icon: const Icon(Icons.archive_outlined, size: 16),
              label: const Text('Export bundle'),
            ),
          ],
        ),
      ),
    );
    pathCtrl.dispose();
    if (request == null) return;
    if (!context.mounted) return;
    try {
      await state.exportProjectBundleToZip(
        widget.projectId,
        request.path,
        includeFiles: request.includeFiles,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Project bundle exported: ${request.path}')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
    }
  }

  Future<void> _showSectionVisibilityDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final selected = _visibleSectionIds.toSet();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Project display'),
          content: SizedBox(
            width: 420,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 520),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final section in _projectDetailSections)
                      CheckboxListTile(
                        dense: true,
                        value: selected.contains(section.id),
                        onChanged: (value) => setLocal(() {
                          if (value ?? false) {
                            selected.add(section.id);
                          } else {
                            selected.remove(section.id);
                          }
                        }),
                        title: Text(section.title),
                        contentPadding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(
                ctx,
              ).pop(_projectDetailDefaultSectionIds.toSet()),
              child: const Text('Show all'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(selected),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    await state.saveProjectDetailSectionVisibility(
      widget.projectId,
      result,
      _projectDetailDefaultSectionIds,
    );
    if (!mounted) return;
    setState(() {
      _visibleSectionIds = result;
      if (_expandedSection != null && !result.contains(_expandedSection)) {
        _expandedSection = null;
      }
    });
  }

  Future<void> _showMetaDialog(BuildContext context, Project project) async {
    final saved = await showProjectMetadataDialog(context, project);
    if (saved == true) await _loadAll();
  }

  Future<void> _showIdentityDialog(
    BuildContext context,
    Project project,
  ) async {
    final state = AppStateScope.of(context);
    final desc = TextEditingController(text: project.description ?? '');
    final outcome = TextEditingController(text: project.desiredOutcome ?? '');
    final criteria = TextEditingController(text: project.successCriteria ?? '');
    final included = TextEditingController(text: project.scopeIncluded ?? '');
    final excluded = TextEditingController(text: project.scopeExcluded ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Edit project identity'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _mf(desc, 'Purpose / problem statement', multiline: true),
                _mf(outcome, 'Desired outcome', multiline: true),
                _mf(criteria, 'Success criteria', multiline: true),
                _mf(included, 'Scope included', multiline: true),
                _mf(excluded, 'Scope excluded', multiline: true),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await state.updateProjectMeta(widget.projectId, {
                'description': _nt(desc.text),
                'desiredOutcome': _nt(outcome.text),
                'successCriteria': _nt(criteria.text),
                'scopeIncluded': _nt(included.text),
                'scopeExcluded': _nt(excluded.text),
              });
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    for (final c in [desc, outcome, criteria, included, excluded]) c.dispose();
  }

  Future<void> _showTagsDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final allTags = await state.getTags();
    final selectedTags = await state.getTagsForProject(widget.projectId);
    final selectedIds = selectedTags.map((tag) => tag.id).toSet();
    final newTagCtrl = TextEditingController();

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Edit project tags'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (allTags.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'No tags yet. Add home, work, personal, or anything useful.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tag in allTags)
                          FilterChip(
                            label: Text(tag.name),
                            selected: selectedIds.contains(tag.id),
                            onSelected: (selected) => setLocal(() {
                              if (selected) {
                                selectedIds.add(tag.id);
                              } else {
                                selectedIds.remove(tag.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: _mf(newTagCtrl, 'New tag name')),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: FilledButton.icon(
                          onPressed: () async {
                            final name = _nt(newTagCtrl.text);
                            if (name == null) return;
                            final id = await state.saveTag(name: name);
                            selectedIds.add(id);
                            newTagCtrl.clear();
                            if (ctx.mounted) {
                              Navigator.of(ctx).pop();
                              await _showTagsDialog(context);
                            }
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await state.setProjectTags(widget.projectId, selectedIds);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to save tags: $e')),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    newTagCtrl.dispose();
  }

  Future<void> _showImportMediaDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final defaultTitle = result.files.single.name;

    if (!context.mounted) return; // Fix 1: mounted check after async gap
    final titleCtrl = TextEditingController(text: defaultTitle);
    final captionCtrl =
        TextEditingController(); // Fix 2: restored caption field
    bool makeCover = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add project media'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  defaultTitle,
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Title (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: captionCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Caption / note (optional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: makeCover,
                  onChanged: (v) =>
                      setDialogState(() => makeCover = v ?? false),
                  title: const Text('Set as cover image'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    final titleText = titleCtrl.text.trim();
    final captionText = captionCtrl.text.trim(); // capture before dispose
    titleCtrl.dispose();
    captionCtrl.dispose();
    if (confirmed != true) return;

    try {
      final mediaId = await state.importProjectMediaFromPath(
        widget.projectId,
        path,
        title: titleText.isEmpty ? null : titleText,
        caption: captionText.isEmpty
            ? null
            : captionText, // Fix 2: restored caption param
        isCover: makeCover,
      );
      if (makeCover) {
        await state.setProjectCoverMedia(widget.projectId, mediaId);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Future<void> _showAddPersonDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final name = TextEditingController();
    final role = TextEditingController();
    final auth = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Add person'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ContactOwnerField(
                  controller: name,
                  label: 'Name / contact',
                ),
              ),
              _mf(role, 'Role / responsibility'),
              _mf(auth, 'Decision authority'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Name is required to update a person.'),
                    ),
                  );
                }
                return;
              }
              await state.saveContact(
                name: name.text.trim(),
                title: _nt(role.text),
                notes: _nt(auth.text),
              );
              await state.addProjectPerson(
                widget.projectId,
                name.text.trim(),
                _nt(role.text),
                _nt(auth.text),
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
              await _loadAll();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    for (final c in [name, role, auth]) c.dispose();
  }

  Future<void> _showEditPersonDialog(
    BuildContext context,
    ProjectPerson person,
  ) async {
    final state = AppStateScope.of(context);
    final name = TextEditingController(text: person.name);
    final role = TextEditingController(text: person.role ?? '');
    final auth = TextEditingController(text: person.authority ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Edit person'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ContactOwnerField(
                  controller: name,
                  label: 'Name / contact',
                ),
              ),
              _mf(role, 'Role / responsibility'),
              _mf(auth, 'Decision authority'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Name is required to update a person.'),
                    ),
                  );
                }
                return;
              }
              await state.saveContact(
                name: name.text.trim(),
                title: _nt(role.text),
                notes: _nt(auth.text),
              );
              await state.updateProjectPerson(
                person.id,
                name.text.trim(),
                _nt(role.text),
                _nt(auth.text),
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
              await _loadAll();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    for (final c in [name, role, auth]) c.dispose();
  }

  Future<void> _showAddRiskDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final title = TextEditingController();
    final desc = TextEditingController();
    String severity = 'medium';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Add risk'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _mf(title, 'Risk title'),
                _mf(desc, 'Description / mitigation', multiline: true),
                DropdownButtonFormField<String>(
                  value: severity,
                  items: const ['low', 'medium', 'high', 'critical']
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) => setLocal(() => severity = v ?? 'medium'),
                  decoration: const InputDecoration(labelText: 'Severity'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty) return;
                try {
                  await state.addProjectRisk(
                    widget.projectId,
                    title.text.trim(),
                    _nt(desc.text),
                    severity,
                  );
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  await _loadAll();
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to add risk: $e')),
                    );
                  }
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    desc.dispose();
  }

  Future<void> _showAddDecisionDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final title = TextEditingController();
    final ctx2 = TextEditingController();
    final contacts = await state.getContacts();
    final selectedNames = <String>{};

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Log decision'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _mf(title, 'What was decided?'),
                  _mf(ctx2, 'Context & rationale', multiline: true),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Decided by (select all that apply)',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  ),
                  if (contacts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text(
                        'No contacts loaded — add contacts in Settings → Workforce.',
                        style: TextStyle(fontSize: 12, color: Colors.white38),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final c in contacts)
                          FilterChip(
                            label: Text(c.name),
                            selected: selectedNames.contains(c.name),
                            onSelected: (v) => setLocal(() {
                              if (v) {
                                selectedNames.add(c.name);
                              } else {
                                selectedNames.remove(c.name);
                              }
                            }),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty) return;
                final deciderStr = selectedNames.isEmpty
                    ? null
                    : selectedNames.join(', ');
                try {
                  await state.addProjectDecision(
                    widget.projectId,
                    title.text.trim(),
                    _nt(ctx2.text),
                    deciderStr,
                  );
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  await _loadAll();
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to log decision: $e')),
                    );
                  }
                }
              },
              child: const Text('Log'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    ctx2.dispose();
  }

  Future<void> _showClosureDialog(BuildContext context, Project project) async {
    final state = AppStateScope.of(context);
    final outcome = TextEditingController(text: project.outcomeSummary ?? '');
    final lessons = TextEditingController(text: project.lessonsLearned ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Edit closure'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _mf(outcome, 'Outcome summary', multiline: true),
              _mf(lessons, 'Lessons learned', multiline: true),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await state.updateProjectMeta(widget.projectId, {
                'outcomeSummary': _nt(outcome.text),
                'lessonsLearned': _nt(lessons.text),
              });
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    outcome.dispose();
    lessons.dispose();
  }

  Future<void> _showDeleteDialog(BuildContext context, Project project) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final state = AppStateScope.of(context);
        return ProjectDeleteDialog(
          projectTitle: project.title,
          onConfirm: (reason) async {
            await state.softDeleteProject(project.id, reason);
            if (ctx.mounted) Navigator.of(ctx).pop();
            if (context.mounted) context.go('/projects');
          },
          onClose: () => Navigator.of(ctx).pop(),
        );
      },
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
String? _nt(String s) {
  final t = s.trim();
  return t.isEmpty ? null : t;
}

Widget _mf(TextEditingController ctrl, String label, {bool multiline = false}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: ctrl,
      minLines: multiline ? 2 : 1,
      maxLines: multiline ? 5 : 1,
      decoration: InputDecoration(labelText: label),
    ),
  );
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _BackBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _BackBtn({required this.onTap});

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onTap,
    icon: const Icon(Icons.arrow_back, size: 16, color: _kPrimary),
    label: const Text(
      'Projects',
      style: TextStyle(color: _kPrimary, fontSize: 13),
    ),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
  );
}

class _ProjectBundleExportRequest {
  final String path;
  final bool includeFiles;

  const _ProjectBundleExportRequest({
    required this.path,
    required this.includeFiles,
  });
}

class _StatusDot extends StatelessWidget {
  final String status;
  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'new' => _kPrimary,
      'changed' => Colors.amber,
      'unchanged' => Colors.white30,
      _ => Colors.white54,
    };
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _ProjectTaskHeaderPanel extends StatelessWidget {
  final String projectId;
  final List<WorkItem> items;
  final List<LlmTaskQueueItem> llmQueueItems;
  final bool expanded;
  final VoidCallback onToggle;
  final Future<void> Function() onAddProjectTask;
  final Future<void> Function() onAddLlmTask;
  final VoidCallback onOpenWorkboard;
  final Future<void> Function() onRefresh;
  final Future<void> Function(WorkItem item) onOpenTask;
  final Future<void> Function(LlmTaskQueueItem item) onOpenLlmTask;
  final Future<void> Function() onManageLlmTasks;

  const _ProjectTaskHeaderPanel({
    required this.projectId,
    required this.items,
    required this.llmQueueItems,
    required this.expanded,
    required this.onToggle,
    required this.onAddProjectTask,
    required this.onAddLlmTask,
    required this.onOpenWorkboard,
    required this.onRefresh,
    required this.onOpenTask,
    required this.onOpenLlmTask,
    required this.onManageLlmTasks,
  });

  @override
  Widget build(BuildContext context) {
    final active = items
        .where((item) => !['done', 'archived'].contains(item.status))
        .toList(growable: false);
    final pendingQueue = llmQueueItems
        .where((item) => item.status == 'pending' || item.status == 'leased')
        .toList(growable: false);
    return Container(
      decoration: BoxDecoration(
        color: _kPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kLine),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Tasks',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  MiniPill('Project', '${active.length}'),
                  const SizedBox(width: 6),
                  MiniPill('LLM', '${pendingQueue.length}'),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: onRefresh,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1, color: _kLine),
            Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 760;
                  final sections = [
                    _ProjectTaskHeaderSubsection(
                      title: 'Project tasks',
                      icon: Icons.task_alt,
                      actionIcon: Icons.add,
                      actionLabel: 'Add task',
                      onAction: onAddProjectTask,
                      child: _TaskHeaderProjectList(
                        items: active,
                        onOpenTask: onOpenTask,
                        onOpenWorkboard: onOpenWorkboard,
                      ),
                    ),
                    _ProjectTaskHeaderSubsection(
                      title: 'LLM queue',
                      icon: Icons.memory,
                      actionIcon: Icons.add_task,
                      actionLabel: 'Queue task',
                      onAction: onAddLlmTask,
                      child: _TaskHeaderLlmQueueList(
                        items: llmQueueItems,
                        onOpenTask: onOpenLlmTask,
                        onShowAll: onManageLlmTasks,
                      ),
                    ),
                  ];
                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: sections[0]),
                        const SizedBox(width: 12),
                        Expanded(child: sections[1]),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      sections[0],
                      const SizedBox(height: 12),
                      sections[1],
                    ],
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProjectTaskHeaderSubsection extends StatelessWidget {
  final String title;
  final IconData icon;
  final IconData actionIcon;
  final String actionLabel;
  final Future<void> Function() onAction;
  final Widget child;

  const _ProjectTaskHeaderSubsection({
    required this.title,
    required this.icon,
    required this.actionIcon,
    required this.actionLabel,
    required this.onAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: _kPrimary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon, size: 16),
                label: Text(actionLabel),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _TaskHeaderProjectList extends StatelessWidget {
  final List<WorkItem> items;
  final Future<void> Function(WorkItem item) onOpenTask;
  final VoidCallback onOpenWorkboard;

  const _TaskHeaderProjectList({
    required this.items,
    required this.onOpenTask,
    required this.onOpenWorkboard,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Text(
        'No open project tasks.',
        style: TextStyle(color: Colors.white38),
      );
    }
    final visible = items.take(5).toList(growable: false);
    return Column(
      children: [
        for (final item in visible)
          _TaskHeaderRow(
            icon: statusFor(item.status).icon,
            iconColor: statusFor(item.status).color,
            title: item.title,
            subtitle: [
              normalizeStatusValue(item.status),
              normalizePriorityValue(item.priority),
              if ((item.owner ?? '').trim().isNotEmpty) item.owner!.trim(),
            ].join(' - '),
            onTap: () => onOpenTask(item),
          ),
        if (items.length > visible.length)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onOpenWorkboard,
              icon: const Icon(Icons.view_kanban_outlined, size: 16),
              label: Text('${items.length - visible.length} more'),
            ),
          ),
      ],
    );
  }
}

class _TaskHeaderLlmQueueList extends StatelessWidget {
  final List<LlmTaskQueueItem> items;
  final Future<void> Function(LlmTaskQueueItem item) onOpenTask;
  final Future<void> Function() onShowAll;

  const _TaskHeaderLlmQueueList({
    required this.items,
    required this.onOpenTask,
    required this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Text(
        'No queued LLM tasks.',
        style: TextStyle(color: Colors.white38),
      );
    }
    final visible = items.take(5).toList(growable: false);
    return Column(
      children: [
        for (final item in visible)
          _TaskHeaderRow(
            icon: _llmQueueIcon(item.status),
            iconColor: _llmQueueColor(item.status),
            title: item.title,
            subtitle: '${item.status} - ${item.priority}',
            onTap: () => onOpenTask(item),
          ),
        if (items.length > visible.length)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onShowAll,
              icon: const Icon(Icons.list_alt, size: 16),
              label: Text('${items.length - visible.length} more'),
            ),
          ),
      ],
    );
  }
}

class _TaskHeaderRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Future<void> Function()? onTap;

  const _TaskHeaderRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _llmQueueIcon(String status) => switch (status) {
  'leased' => Icons.play_circle_outline,
  'completed' => Icons.check_circle_outline,
  'failed' => Icons.error_outline,
  'cancelled' => Icons.cancel_outlined,
  _ => Icons.schedule,
};

Color _llmQueueColor(String status) => switch (status) {
  'leased' => const Color(0xFF79A7FF),
  'completed' => const Color(0xFF4CAF50),
  'failed' => const Color(0xFFF44336),
  'cancelled' => const Color(0xFF90A4AE),
  _ => const Color(0xFFFFC107),
};

class _AiPanel extends StatelessWidget {
  final String projectId;
  final bool expanded;
  final bool includeLibrary;
  final bool summaryLoading;
  final String? summaryText;
  final ProjectSummaryOutcome? summaryOutcome;
  final DateTime? generatedAt;
  final ProjectSummaryEvidencePacket? evidencePacket;
  final bool evidenceLoading;
  final VoidCallback onToggle;
  final ValueChanged<bool> onToggleLibrary;
  final VoidCallback onGenerate;

  const _AiPanel({
    required this.projectId,
    required this.expanded,
    required this.includeLibrary,
    required this.summaryLoading,
    required this.summaryText,
    required this.summaryOutcome,
    required this.generatedAt,
    required this.evidencePacket,
    required this.evidenceLoading,
    required this.onToggle,
    required this.onToggleLibrary,
    required this.onGenerate,
  });

  String _formatAge(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final hasContent = summaryOutcome != null || summaryText != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF79A7FF).withAlpha(15),
        border: Border.all(color: const Color(0xFF79A7FF).withAlpha(51)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology, size: 18, color: _kPrimary),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    const Text(
                      'AI Project Assistant',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _kPrimary,
                        fontSize: 14,
                      ),
                    ),
                    if (generatedAt != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        _formatAge(generatedAt!),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white24,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => onToggleLibrary(!includeLibrary),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: includeLibrary,
                            onChanged: (v) => onToggleLibrary(v ?? false),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Include Library',
                          style: TextStyle(fontSize: 11, color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onToggle,
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white38,
                    ),
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 12),
            _EvidencePacketPreview(
              packet: evidencePacket,
              loading: evidenceLoading,
              includeLibrary: includeLibrary,
            ),
            const SizedBox(height: 12),
            if (summaryLoading)
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Generating…',
                    style: TextStyle(fontSize: 13, color: Colors.white54),
                  ),
                ],
              )
            else if (!hasContent)
              FilledButton.icon(
                onPressed: onGenerate,
                icon: const Icon(Icons.psychology, size: 16),
                label: const Text('Generate Summary'),
              )
            else if (summaryOutcome?.hasStructured == true)
              _StructuredSummaryView(
                projectId: projectId,
                result: summaryOutcome!.structured!,
                documentPaths: summaryOutcome!.documentPaths,
                onRegenerate: onGenerate,
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      summaryText ?? summaryOutcome?.rawOutput ?? '',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: onGenerate,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Regenerate'),
                    style: TextButton.styleFrom(
                      foregroundColor: _kPrimary,
                      padding: EdgeInsets.zero,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            SummaryRunProvenance(projectId: projectId),
          ],
        ],
      ),
    );
  }
}

// ─── Structured summary renderer ─────────────────────────────────────────────

class _EvidencePacketPreview extends StatelessWidget {
  final ProjectSummaryEvidencePacket? packet;
  final bool loading;
  final bool includeLibrary;

  const _EvidencePacketPreview({
    required this.packet,
    required this.loading,
    required this.includeLibrary,
  });

  String _chars(int value) {
    if (value >= 10000) return '${(value / 1000).round()}k';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }

  String _categoryLabel(String? value) =>
      (value == null || value.trim().isEmpty)
      ? 'other'
      : value.replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) {
    final currentPacket = packet;
    final docs = currentPacket?.documents ?? const <ProjectSummaryContextDoc>[];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fact_check_outlined, size: 15, color: _kPrimary),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Evidence packet',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (currentPacket != null)
                Wrap(
                  spacing: 6,
                  children: [
                    MiniPill(
                      'Docs',
                      '${currentPacket.includedDocumentCount}/${currentPacket.suppliedDocumentCount}',
                    ),
                    MiniPill(
                      'Excerpt',
                      _chars(currentPacket.totalExcerptChars),
                    ),
                  ],
                ),
            ],
          ),
          if (!loading) ...[
            const SizedBox(height: 8),
            if (currentPacket == null)
              const Text(
                'No packet loaded.',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              )
            else if (!includeLibrary)
              Text(
                'Library disabled (${currentPacket.suppliedDocumentCount} linked document${currentPacket.suppliedDocumentCount == 1 ? '' : 's'} available).',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              )
            else if (docs.isEmpty)
              const Text(
                'No linked Library documents.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              )
            else ...[
              if (currentPacket.warnings.isNotEmpty) ...[
                ...currentPacket.warnings
                    .take(3)
                    .map(
                      (warning) => Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              size: 13,
                              color: Colors.amberAccent,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                warning,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                if (currentPacket.warnings.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      '+${currentPacket.warnings.length - 3} more warning(s)',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white38,
                      ),
                    ),
                  ),
                const SizedBox(height: 2),
              ],
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: docs.take(6).map((doc) {
                  final reason = doc.selectionReason ?? 'linked document';
                  final category = _categoryLabel(doc.evidenceCategory);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 30,
                          child: Text(
                            '#${doc.rank ?? '-'}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                doc.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '$category - $reason - ${_chars(doc.excerptChars)} chars',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white38,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _StructuredSummaryView extends StatelessWidget {
  final String projectId;
  final ProjectSummaryResult result;
  final Map<String, String?> documentPaths;
  final VoidCallback onRegenerate;

  const _StructuredSummaryView({
    required this.projectId,
    required this.result,
    required this.documentPaths,
    required this.onRegenerate,
  });

  static const _head = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: _kPrimary,
    letterSpacing: 0.5,
  );
  static const _body = TextStyle(
    fontSize: 13,
    color: Color(0xDEFFFFFF),
    height: 1.55,
  );
  static const _sub = TextStyle(
    fontSize: 12,
    color: Color(0x8AFFFFFF),
    height: 1.5,
  );

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: _head),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );

  Widget _bullets(List<String> items) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: items
        .map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• ', style: TextStyle(color: Color(0x8AFFFFFF))),
                Expanded(child: Text(t, style: _body)),
              ],
            ),
          ),
        )
        .toList(),
  );

  Widget _numbered(List<String> items) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: List.generate(
      items.length,
      (i) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 20,
              child: Text(
                '${i + 1}.',
                style: const TextStyle(color: Color(0x8AFFFFFF)),
              ),
            ),
            Expanded(child: Text(items[i], style: _body)),
          ],
        ),
      ),
    ),
  );

  Future<void> _openInExplorer(BuildContext context, String path) async {
    try {
      // /select, highlights the file in Explorer on Windows
      await Process.start('explorer.exe', ['/select,', path]);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open Explorer: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = result;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF79A7FF).withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Goal
          if (s.goal.isNotEmpty) _section('Goal', _bullets(s.goal)),

          // Current State
          if (s.currentState.isNotEmpty)
            _section('Current State', Text(s.currentState, style: _body)),

          // Ownership
          if (s.ownership.isNotEmpty)
            _section(
              'Ownership / Active Work',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: s.ownership
                    .map(
                      (o) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              o.person,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xDEFFFFFF),
                              ),
                            ),
                            ...o.work.map(
                              (w) => Padding(
                                padding: const EdgeInsets.only(
                                  left: 12,
                                  top: 2,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '– ',
                                      style: TextStyle(
                                        color: Color(0x8AFFFFFF),
                                      ),
                                    ),
                                    Expanded(child: Text(w, style: _sub)),
                                  ],
                                ),
                              ),
                            ),
                            if (o.basis != null)
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 12,
                                  top: 2,
                                ),
                                child: Text(
                                  'Basis: ${o.basis}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0x61FFFFFF),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),

          // Relevant Library Docs
          if (s.relevantDocuments.isNotEmpty)
            _section(
              'Relevant Library Docs',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: s.relevantDocuments.map((doc) {
                  final storedPath = documentPaths[doc.documentId];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          doc.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xDEFFFFFF),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(doc.reason, style: _sub),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () {
                                context.go(
                                  libraryRouteForProject(
                                    projectId,
                                    entryType: 'document',
                                    entryId: doc.documentId,
                                  ),
                                );
                              },
                              icon: const Icon(Icons.library_books, size: 13),
                              label: const Text('Open in Library'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _kPrimary,
                                side: BorderSide(
                                  color: _kPrimary.withAlpha(80),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                            ),
                            if (storedPath != null && storedPath.isNotEmpty)
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _openInExplorer(context, storedPath),
                                icon: const Icon(Icons.folder_open, size: 13),
                                label: const Text('Show in Explorer'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0x8AFFFFFF),
                                  side: BorderSide(
                                    color: const Color(
                                      0xFF273044,
                                    ).withAlpha(200),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  textStyle: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),

          // Blockers / Risks
          if (s.blockersAndRisks.isNotEmpty)
            _section('Blockers / Risks', _bullets(s.blockersAndRisks)),

          // Next Actions
          if (s.nextActions.isNotEmpty)
            _section('Next Practical Actions', _numbered(s.nextActions)),

          // Confidence / Gaps
          if (s.confidence.isNotEmpty)
            _section(
              'Confidence / Gaps',
              Text(
                s.confidence,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0x61FFFFFF),
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                ),
              ),
            ),

          // Regenerate
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onRegenerate,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Regenerate'),
              style: TextButton.styleFrom(
                foregroundColor: _kPrimary,
                padding: EdgeInsets.zero,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String id, title, subtitle;
  final bool expanded;
  final VoidCallback onTap;
  final Widget child;

  const _Section({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: _kPanel,
          border: Border.all(color: _kLine),
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: Colors.white38,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded) ...[
              const Divider(height: 1, color: _kLine),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: child,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
