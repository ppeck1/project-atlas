import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../db/app_db.dart';
import '../../services/github_remote_metadata_service.dart';
import '../../services/local_git_visibility_service.dart';
import '../../services/local_project_refresh_service.dart';
import '../../services/project_runtime_service.dart' as runtime;
import '../../services/project_summary_models.dart';
import '../../services/shopify_seo_analyzer.dart';
import '../../services/shopify_seo_review_service.dart';
import '../../shared/models/app_state.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/models/project_metadata.dart';
import '../../shared/widgets/contact_picker.dart';
import '../../shared/widgets/create_work_item_dialog.dart';
import 'project_metadata_dialog.dart';
import '../today/work_item_detail_sheet.dart';
import '../work/status_priority_helpers.dart';

// ─── Design tokens ─────────────────────────────────────────────────────────
const _kPrimary = Color(0xFF79A7FF);
const _kPanel = Color(0xFF151A22);
const _kLine = Color(0xFF273044);

const _kPhaseColors = <String, Color>{
  'idea': Color(0xFF9C27B0),
  'design': Color(0xFF2196F3),
  'build': Color(0xFFFFC107),
  'test': Color(0xFFFF9800),
  'ship': Color(0xFF4CAF50),
  'stabilize': Color(0xFF607D8B),
};
const _kPriorityColors = <String, Color>{
  'high': Color(0xFFFF9800),
  'urgent': Color(0xFFF44336),
  'low': Color(0xFF607D8B),
};

Color _pc(String? p) => _kPhaseColors[p] ?? const Color(0x61FFFFFF);
Color _prc(String? p) => _kPriorityColors[p] ?? const Color(0x61FFFFFF);
String _shortSha(String sha) => sha.length <= 8 ? sha : sha.substring(0, 8);
String _compactDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
String _compactDateTime(DateTime? value) {
  if (value == null) return 'n/a';
  return '${_compactDate(value)} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

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

Map<String, Object?> _tryParseJsonObject(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String, Object?>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }
  } catch (_) {}
  return const <String, Object?>{};
}

String _libraryRouteForProject(
  String projectId, {
  String? entryType,
  String? entryId,
}) {
  final queryParameters = <String, String>{'projectId': projectId};
  if (entryType != null) queryParameters['entryType'] = entryType;
  if (entryId != null) queryParameters['entryId'] = entryId;
  return Uri(path: '/library', queryParameters: queryParameters).toString();
}

String _workboardRouteForProject(String projectId) {
  return Uri(
    path: '/work',
    queryParameters: {'projectId': projectId, 'scope': 'project'},
  ).toString();
}

Color _tagColor(Tag tag) {
  final raw = tag.color;
  if (raw != null && raw.startsWith('#') && raw.length == 7) {
    final parsed = int.tryParse(raw.substring(1), radix: 16);
    if (parsed != null) return Color(0xFF000000 | parsed);
  }
  return _kPrimary;
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

  List<WorkItem> _workItems = const [];
  List<LlmTaskQueueItem> _llmQueueItems = const [];
  List<ProjectPerson> _people = const [];
  List<ProjectRisk> _risks = const [];
  List<ProjectDecision> _decisions = const [];
  bool _didLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didLoad) {
      _didLoad = true;
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    final state = AppStateScope.of(context);
    // Each query is independent — a schema mismatch on one table (e.g. a
    // missing column that _ensureProjectCompatibilityColumns hasn't patched
    // yet on this run) must not prevent the others from loading.
    final items = await state.getWorkItemsForProject(widget.projectId);
    List<LlmTaskQueueItem> llmTasks = _llmQueueItems;
    try {
      llmTasks = await state.getLlmTasksForProject(widget.projectId, limit: 50);
    } catch (_) {}
    final people = await state.getProjectPeople(widget.projectId);
    List<ProjectRisk> risks = _risks;
    try {
      risks = await state.getProjectRisks(widget.projectId);
    } catch (_) {}
    List<ProjectDecision> decisions = _decisions;
    try {
      decisions = await state.getProjectDecisions(widget.projectId);
    } catch (_) {}
    final summarySettings = await state.loadProjectAiSummarySettings();

    Draft? cachedDraft;
    if (summarySettings.enabled) {
      try {
        cachedDraft = await state.getLatestProjectSummaryDraft(
          widget.projectId,
        );
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _workItems = items;
      _llmQueueItems = llmTasks;
      _people = people;
      _risks = risks;
      _decisions = decisions;
      _includeLibrary = summarySettings.includeLibrary;
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
    final state = AppStateScope.of(context);
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
    } catch (_) {
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

  Future<void> _addProjectTask(BuildContext context) async {
    final state = AppStateScope.of(context);
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
    final state = AppStateScope.of(context);
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
    final state = AppStateScope.of(context);
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
                        '${item.status} - ${item.priority} - updated ${_compactDateTime(item.updatedAt)}',
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
    final state = AppStateScope.of(context);
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
                        _MiniPill('Status', item.status),
                        _MiniPill('Attempts', '${item.attempts}'),
                        if (item.leasedBy != null)
                          _MiniPill('Leased', item.leasedBy!),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Created ${_compactDateTime(item.createdAt)} by ${item.createdBy}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                    if (item.completedAt != null)
                      Text(
                        '$terminalLabel ${_compactDateTime(item.completedAt)}',
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
      stream: state.watchProject(widget.projectId),
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
                tooltip: 'Open work board',
                icon: const Icon(Icons.view_kanban_outlined, size: 20),
                onPressed: () async {
                  await state.setActiveById(project.id);
                  if (context.mounted) {
                    context.go(_workboardRouteForProject(project.id));
                  }
                },
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
              _ProjectCommandToolbar(
                projectId: widget.projectId,
                onOpenWorkboard: () async {
                  await state.setActiveById(project.id);
                  if (context.mounted) {
                    context.go(_workboardRouteForProject(project.id));
                  }
                },
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
                onOpenWorkboard: () => _toggleSection('work'),
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
              _QuickBar(
                project: project,
                activeCount: active.length,
                blockedCount: blockedCount,
                overdueCount: overdueCount,
                urgentCount: urgentCount,
                onEditMeta: () => _showMetaDialog(context, project),
              ),
              const SizedBox(height: 8),

              // Expandable sections
              _Section(
                id: 'tags',
                title: 'Tags',
                subtitle: 'Separate home, work, personal, and other contexts',
                expanded: _expandedSection == 'tags',
                onTap: () => _toggleSection('tags'),
                child: _TagsSection(
                  projectId: widget.projectId,
                  onEdit: () => _showTagsDialog(context),
                ),
              ),
              _Section(
                id: 'identity',
                title: 'Project Identity',
                subtitle: 'Purpose, outcome, success criteria, scope',
                expanded: _expandedSection == 'identity',
                onTap: () => _toggleSection('identity'),
                child: _IdentitySection(
                  projectId: widget.projectId,
                  project: project,
                  onEdit: () => _showIdentityDialog(context, project),
                  onReplaceGithub: () => _replaceGithubMetadata(context),
                  onForgetGithub: () => _forgetGithubMetadata(context),
                ),
              ),
              _Section(
                id: 'shopify_seo',
                title: 'Shopify SEO',
                subtitle: 'Product review table and product-level batches',
                expanded: _expandedSection == 'shopify_seo',
                onTap: () => _toggleSection('shopify_seo'),
                child: _ShopifySeoSection(projectId: widget.projectId),
              ),
              _Section(
                id: 'local_repo',
                title: 'Local Repo',
                subtitle: 'Refresh from reviewed local project files',
                expanded: _expandedSection == 'local_repo',
                onTap: () => _toggleSection('local_repo'),
                child: _LocalRepoSection(
                  projectId: widget.projectId,
                  onChooseLocalRepo: () => _replaceLocalRepoLink(context),
                  onAssociateFile: () => _associateLocalFile(context),
                  onAssociateFolder: () => _associateLocalFolder(context),
                  onPreviewRefresh: () => _showLocalRefreshDialog(context),
                  onExportBundle: () =>
                      _showProjectBundleExportDialog(context, project.title),
                  onInspectGit: () => _showGitVisibilityDialog(context),
                  onRefreshGithub: () => _refreshGithubMetadata(context),
                ),
              ),
              _Section(
                id: 'runtime',
                title: 'Runtime',
                subtitle: 'Launch, tests, and capsule checks',
                expanded: _expandedSection == 'runtime',
                onTap: () => _toggleSection('runtime'),
                child: _ProjectRuntimeSection(
                  projectId: widget.projectId,
                  onEdit: () => _showMetaDialog(context, project),
                ),
              ),
              _Section(
                id: 'people',
                title: 'People & Roles',
                subtitle: 'Who is involved and what do they own?',
                expanded: _expandedSection == 'people',
                onTap: () => _toggleSection('people'),
                child: _PeopleSection(
                  people: _people,
                  onAdd: () => _showAddPersonDialog(context),
                  onEdit: (p) => _showEditPersonDialog(context, p),
                  onDelete: (p) async {
                    await state.deleteProjectPerson(p.id);
                    await _loadAll();
                  },
                ),
              ),
              _Section(
                id: 'work',
                title: 'Project Workboard',
                subtitle: 'Project-scoped tasks, grouped by status',
                expanded: _expandedSection == 'work',
                onTap: () => _toggleSection('work'),
                child: _ProjectWorkSection(
                  projectId: widget.projectId,
                  items: _workItems,
                  onChanged: _loadAll,
                  onAddProjectTask: () => _addProjectTask(context),
                ),
              ),
              _Section(
                id: 'risks',
                title: 'Risks & Issues',
                subtitle: 'What might break, what is already broken?',
                expanded: _expandedSection == 'risks',
                onTap: () => _toggleSection('risks'),
                child: _RisksSection(
                  risks: _risks,
                  onAdd: () => _showAddRiskDialog(context),
                  onDelete: (r) async {
                    await state.deleteProjectRisk(r.id);
                    await _loadAll();
                  },
                ),
              ),
              _Section(
                id: 'decisions',
                title: 'Decision Log',
                subtitle: 'What was decided, why, and by whom?',
                expanded: _expandedSection == 'decisions',
                onTap: () => _toggleSection('decisions'),
                child: _DecisionsSection(
                  decisions: _decisions,
                  onAdd: () => _showAddDecisionDialog(context),
                  onDelete: (d) async {
                    await state.deleteProjectDecision(d.id);
                    await _loadAll();
                  },
                ),
              ),
              _Section(
                id: 'change_log',
                title: 'Change Log',
                subtitle: 'Who changed what, and when',
                expanded: _expandedSection == 'change_log',
                onTap: () => _toggleSection('change_log'),
                child: _ProjectChangeLogSection(projectId: widget.projectId),
              ),
              _Section(
                id: 'media',
                title: 'Media & Documents',
                subtitle: 'Images, reference files, and project evidence',
                expanded: _expandedSection == 'media',
                onTap: () => _toggleSection('media'),
                child: _MediaSection(
                  projectId: widget.projectId,
                  onImportMedia: () => _showImportMediaDialog(context),
                ),
              ),
              _Section(
                id: 'closure',
                title: 'Closure',
                subtitle:
                    normalizeProjectStatusValue(project.status) == 'completed'
                    ? 'Completed'
                    : 'Open project',
                expanded: _expandedSection == 'closure',
                onTap: () => _toggleSection('closure'),
                child: _ClosureSection(
                  project: project,
                  onEdit: () => _showClosureDialog(context, project),
                  onComplete: () => state.updateProjectMeta(widget.projectId, {
                    'status': 'completed',
                  }),
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

  Future<void> _showLocalRefreshDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    LocalProjectRefreshPreview preview;
    try {
      preview = await state.previewLocalProjectRefresh(widget.projectId);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Refresh preview failed: $error')));
      return;
    }
    if (!context.mounted) return;
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
          title: const Text('Preview local repo refresh'),
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
                    _MiniPill('Profile', preview.profile),
                    if ((preview.branch ?? '').isNotEmpty)
                      _MiniPill('Branch', preview.branch!),
                    if ((preview.headSha ?? '').isNotEmpty)
                      _MiniPill('SHA', _shortSha(preview.headSha!)),
                    if (preview.dirtyCount != null)
                      _MiniPill('Dirty', '${preview.dirtyCount}'),
                  ],
                ),
                if (preview.warnings.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    preview.warnings.join('\n'),
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
              label: const Text('Apply selected'),
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
            'Refresh applied: ${result.created} created, ${result.updated} updated, ${result.unchanged} unchanged.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Refresh apply failed: $error')));
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
      builder: (ctx) => _GitVisibilityDialog(report: report),
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
                              _MiniPill(
                                'Atlas records',
                                '${preview.atlasRecordCount}',
                              ),
                              _MiniPill('Documents', '${preview.documents}'),
                              _MiniPill(
                                'Copied files',
                                '${preview.copiedFileCount}',
                              ),
                              _MiniPill('Work', '${preview.workItems}'),
                              _MiniPill('Risks', '${preview.risks}'),
                              _MiniPill('Decisions', '${preview.decisions}'),
                              _MiniPill(
                                'Observations',
                                '${preview.observations}',
                              ),
                              _MiniPill(
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
        return _DeleteDialog(
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

class _ShopifySeoSection extends StatefulWidget {
  final String projectId;

  const _ShopifySeoSection({required this.projectId});

  @override
  State<_ShopifySeoSection> createState() => _ShopifySeoSectionState();
}

class _ShopifySeoSectionState extends State<_ShopifySeoSection> {
  ShopifySeoReviewSnapshot? _snapshot;
  final Set<String> _selected = {};
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String _filter = 'all';
  String _sort = 'lowest_score';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await AppStateScope.of(
        context,
      ).getLatestShopifySeoReview(widget.projectId);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selected
          ..clear()
          ..addAll(defaultShopifySeoProductSelection(snapshot));
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _seed() async {
    setState(() => _busy = true);
    try {
      final snapshot = await AppStateScope.of(
        context,
      ).seedSinternetCultShopifySeoReview(widget.projectId);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selected
          ..clear()
          ..addAll(defaultShopifySeoProductSelection(snapshot));
      });
    } catch (error) {
      _showSnack('Shopify SEO seed failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importJson() async {
    final state = AppStateScope.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final raw = await File(path).readAsString();
      final snapshot = ShopifySeoReviewSnapshot.decode(raw);
      await state.saveShopifySeoReviewSnapshot(
        projectId: widget.projectId,
        snapshot: snapshot,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selected
          ..clear()
          ..addAll(defaultShopifySeoProductSelection(snapshot));
      });
    } catch (error) {
      _showSnack('Shopify SEO import failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _queueSelected() async {
    final snapshot = _snapshot;
    if (snapshot == null || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final count = await AppStateScope.of(context)
          .queueShopifySeoProductBatches(
            projectId: widget.projectId,
            snapshot: snapshot,
            productIds: Set<String>.of(_selected),
          );
      await _load();
      _showSnack(
        'Queued $count Shopify SEO product batch${count == 1 ? '' : 'es'}.',
      );
    } catch (error) {
      _showSnack('Queue failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(String format) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final export = ShopifySeoAnalyzer.buildExport(snapshot);
    final extension = switch (format) {
      'json' => 'json',
      'csv' => 'csv',
      _ => 'md',
    };
    final text = switch (format) {
      'json' => export.json,
      'csv' => export.csv,
      _ => export.markdown,
    };
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Shopify SEO review',
      fileName: 'shopify-seo-review-${snapshot.shopDomain}.$extension',
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (path == null) return;
    await File(path).writeAsString(text);
    _showSnack('Exported Shopify SEO review $extension.');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _ShopifySeoEmptyState(
        message: 'Could not load Shopify SEO review data.',
        detail: _error!,
        busy: _busy,
        onSeed: _seed,
        onImport: _importJson,
      );
    }
    if (snapshot == null) {
      return _ShopifySeoEmptyState(
        message: 'No Shopify SEO review snapshot yet.',
        detail:
            'Seed a plug-and-play Sinternet Cult snapshot or import a JSON product export. Admin API sync can feed this same review table later.',
        busy: _busy,
        onSeed: _seed,
        onImport: _importJson,
      );
    }

    final analyses = ShopifySeoAnalyzer.analyzeSnapshot(snapshot);
    final products = _filteredProducts(snapshot.products, analyses);
    final selectableIds = snapshot.products
        .where((product) => product.status != 'queued')
        .map((product) => product.id)
        .toSet();
    final allSelected =
        selectableIds.isNotEmpty && selectableIds.every(_selected.contains);
    final avgScore = analyses.isEmpty
        ? 0
        : (analyses.values.map((a) => a.score).reduce((a, b) => a + b) /
                  analyses.length)
              .round();
    final critical = analyses.values.fold<int>(
      0,
      (sum, analysis) => sum + analysis.criticalCount,
    );
    final warnings = analyses.values.fold<int>(
      0,
      (sum, analysis) => sum + analysis.warningCount,
    );
    final missingMeta = analyses.values
        .where(
          (analysis) => analysis.issues.any(
            (issue) => issue.id == 'missing_meta_description',
          ),
        )
        .length;
    final missingAlt = snapshot.products.fold<int>(
      0,
      (sum, product) =>
          sum +
          product.images
              .where((image) => (image.alt ?? '').trim().isEmpty)
              .length,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _MiniPill('Shop', snapshot.shopDomain),
            _MiniPill('Products', '${snapshot.products.length}'),
            _MiniPill('Avg score', '$avgScore'),
            _MiniPill('Critical', '$critical'),
            _MiniPill('Warnings', '$warnings'),
            _MiniPill('Missing meta', '$missingMeta'),
            _MiniPill('Missing alt', '$missingAlt'),
            _MiniPill('Queued', '${snapshot.queuedCount}'),
            _MiniPill('Synced', _compactDateTime(snapshot.syncedAt)),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _seed,
              icon: const Icon(Icons.inventory_2_outlined, size: 16),
              label: const Text('Seed sample'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _importJson,
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('Import JSON'),
            ),
            PopupMenuButton<String>(
              tooltip: 'Export review',
              onSelected: _busy ? null : _export,
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'json', child: Text('Export JSON')),
                PopupMenuItem(value: 'csv', child: Text('Export CSV')),
                PopupMenuItem(
                  value: 'markdown',
                  child: Text('Export Markdown'),
                ),
              ],
              child: OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Export'),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy || selectableIds.isEmpty
                  ? null
                  : () {
                      setState(() {
                        if (allSelected) {
                          _selected.removeAll(selectableIds);
                        } else {
                          _selected.addAll(selectableIds);
                        }
                      });
                    },
              icon: Icon(
                allSelected ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
              ),
              label: Text(allSelected ? 'Clear products' : 'Select products'),
            ),
            FilledButton.icon(
              onPressed: _busy || _selected.isEmpty ? null : _queueSelected,
              icon: const Icon(Icons.playlist_add_check, size: 16),
              label: Text('Queue ${_selected.length} product batches'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
              value: _filter,
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All')),
                DropdownMenuItem(value: 'critical', child: Text('Critical')),
                DropdownMenuItem(
                  value: 'missing_meta',
                  child: Text('Missing title/meta'),
                ),
                DropdownMenuItem(
                  value: 'missing_alt',
                  child: Text('Missing alt text'),
                ),
                DropdownMenuItem(
                  value: 'thin',
                  child: Text('Thin description'),
                ),
                DropdownMenuItem(value: 'low_score', child: Text('Low score')),
                DropdownMenuItem(
                  value: 'not_queued',
                  child: Text('Not queued'),
                ),
                DropdownMenuItem(value: 'queued', child: Text('Queued')),
              ],
              onChanged: (value) => setState(() => _filter = value ?? 'all'),
            ),
            DropdownButton<String>(
              value: _sort,
              items: const [
                DropdownMenuItem(
                  value: 'lowest_score',
                  child: Text('Lowest score'),
                ),
                DropdownMenuItem(
                  value: 'critical_first',
                  child: Text('Most critical'),
                ),
                DropdownMenuItem(value: 'title', child: Text('Product title')),
                DropdownMenuItem(
                  value: 'updated',
                  child: Text('Recently updated'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _sort = value ?? 'lowest_score'),
            ),
            TextButton(
              onPressed: () => _selectMatching(
                snapshot.products,
                analyses,
                (product, analysis) => analysis.criticalCount > 0,
              ),
              child: const Text('Select critical'),
            ),
            TextButton(
              onPressed: () => _selectMatching(
                snapshot.products,
                analyses,
                (product, analysis) => analysis.issues.any(
                  (issue) =>
                      issue.id == 'missing_meta_description' ||
                      issue.id == 'missing_seo_title',
                ),
              ),
              child: const Text('Select missing meta'),
            ),
            TextButton(
              onPressed: () => _selectMatching(
                snapshot.products,
                analyses,
                (product, analysis) => product.images.any(
                  (image) => (image.alt ?? '').trim().isEmpty,
                ),
              ),
              child: const Text('Select missing alt'),
            ),
            TextButton(
              onPressed: () => _selectMatching(
                snapshot.products,
                analyses,
                (product, analysis) => analysis.score < 70,
              ),
              child: const Text('Select low score'),
            ),
            TextButton(
              onPressed: () => setState(_selected.clear),
              child: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final product in products) ...[
          _ShopifySeoProductCard(
            product: product,
            analysis: analyses[product.id]!,
            proposalSeed: ShopifySeoAnalyzer.generateProposalSeed(
              product,
              analysis: analyses[product.id],
              shopDomain: snapshot.shopDomain,
              brandName: snapshot.resolvedBrandName,
            ),
            selected: _selected.contains(product.id),
            selectable: product.status != 'queued',
            onSelected: (value) {
              setState(() {
                if (value) {
                  _selected.add(product.id);
                } else {
                  _selected.remove(product.id);
                }
              });
            },
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  void _selectMatching(
    List<ShopifySeoProduct> products,
    Map<String, ShopifySeoAnalysis> analyses,
    bool Function(ShopifySeoProduct product, ShopifySeoAnalysis analysis) match,
  ) {
    setState(() {
      _selected
        ..clear()
        ..addAll(
          products
              .where((product) => product.status != 'queued')
              .where((product) => match(product, analyses[product.id]!))
              .map((product) => product.id),
        );
    });
  }

  List<ShopifySeoProduct> _filteredProducts(
    List<ShopifySeoProduct> products,
    Map<String, ShopifySeoAnalysis> analyses,
  ) {
    final filtered = products.where((product) {
      final analysis = analyses[product.id]!;
      return switch (_filter) {
        'critical' => analysis.criticalCount > 0,
        'missing_meta' => analysis.issues.any(
          (issue) =>
              issue.id == 'missing_meta_description' ||
              issue.id == 'missing_seo_title',
        ),
        'missing_alt' => product.images.any(
          (image) => (image.alt ?? '').trim().isEmpty,
        ),
        'thin' => analysis.issues.any(
          (issue) => issue.id == 'thin_description',
        ),
        'low_score' => analysis.score < 70,
        'not_queued' => product.status != 'queued',
        'queued' => product.status == 'queued',
        _ => true,
      };
    }).toList();
    filtered.sort((a, b) {
      final aa = analyses[a.id]!;
      final bb = analyses[b.id]!;
      return switch (_sort) {
        'critical_first' => bb.criticalCount.compareTo(aa.criticalCount),
        'title' => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        'updated' => (b.updatedAt ?? '').compareTo(a.updatedAt ?? ''),
        _ => aa.score.compareTo(bb.score),
      };
    });
    return filtered;
  }
}

class _ShopifySeoEmptyState extends StatelessWidget {
  final String message;
  final String detail;
  final bool busy;
  final VoidCallback onSeed;
  final VoidCallback onImport;

  const _ShopifySeoEmptyState({
    required this.message,
    required this.detail,
    required this.busy,
    required this.onSeed,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            detail,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : onSeed,
                icon: const Icon(Icons.inventory_2_outlined, size: 16),
                label: const Text('Seed sample'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onImport,
                icon: const Icon(Icons.upload_file, size: 16),
                label: const Text('Import JSON'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShopifySeoProductCard extends StatelessWidget {
  final ShopifySeoProduct product;
  final ShopifySeoAnalysis analysis;
  final ShopifySeoProposalSeed proposalSeed;
  final bool selected;
  final bool selectable;
  final ValueChanged<bool> onSelected;

  const _ShopifySeoProductCard({
    required this.product,
    required this.analysis,
    required this.proposalSeed,
    required this.selected,
    required this.selectable,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x33151A22),
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: selected,
            onChanged: selectable
                ? (value) => onSelected(value ?? false)
                : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      product.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    _MiniPill('Status', product.status.replaceAll('_', ' ')),
                    _MiniPill('Score', '${analysis.score}/100'),
                    _MiniPill('Critical', '${analysis.criticalCount}'),
                    _MiniPill('Warnings', '${analysis.warningCount}'),
                    if ((product.productType ?? '').isNotEmpty)
                      _MiniPill('Type', product.productType!),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '/products/${product.handle}',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 10),
                _SeoFieldRow(
                  label: 'Current title',
                  value: product.currentSeoTitle,
                  fallback: 'Missing',
                  showCount: true,
                ),
                _SeoFieldRow(
                  label: 'Current meta',
                  value: product.currentMetaDescription,
                  fallback: 'Missing',
                  showCount: true,
                ),
                _SeoFieldRow(
                  label: 'Proposed title',
                  value:
                      product.proposedSeoTitle ?? proposalSeed.proposedSeoTitle,
                  fallback: 'Not staged yet',
                  showCount: true,
                ),
                _SeoFieldRow(
                  label: 'Proposed meta',
                  value:
                      product.proposedMetaDescription ??
                      proposalSeed.proposedMetaDescription,
                  fallback: 'Not staged yet',
                  showCount: true,
                ),
                if (analysis.issues.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final issue in analysis.issues.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '${issue.severity}: ${issue.message}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
                Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: const Text(
                      'Details',
                      style: TextStyle(fontSize: 13),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _MiniPill(
                              'Snippet',
                              '${analysis.breakdown.searchSnippet}/35',
                            ),
                            _MiniPill(
                              'Content',
                              '${analysis.breakdown.content}/25',
                            ),
                            _MiniPill(
                              'Images',
                              '${analysis.breakdown.imageAltText}/15',
                            ),
                            _MiniPill(
                              'URL/tax',
                              '${analysis.breakdown.urlAndTaxonomy}/10',
                            ),
                            _MiniPill(
                              'Merchant',
                              '${analysis.breakdown.merchantDataReadiness}/15',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final issue in analysis.issues)
                        _ShopifyIssueRow(issue: issue),
                      if (proposalSeed.warnings.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        for (final warning in proposalSeed.warnings)
                          Text(
                            'Risk note: $warning',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFFFCC80),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeoFieldRow extends StatelessWidget {
  final String label;
  final String? value;
  final String fallback;
  final bool showCount;

  const _SeoFieldRow({
    required this.label,
    required this.value,
    required this.fallback,
    this.showCount = false,
  });

  @override
  Widget build(BuildContext context) {
    final raw = value?.trim();
    final text = raw?.isNotEmpty == true ? raw! : fallback;
    final muted = value?.trim().isNotEmpty != true;
    final display = showCount && !muted ? '$text (${text.length})' : text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
          Expanded(
            child: Text(
              display,
              style: TextStyle(
                fontSize: 12,
                color: muted ? const Color(0x99FFFFFF) : Colors.white70,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShopifyIssueRow extends StatelessWidget {
  final ShopifySeoIssue issue;

  const _ShopifyIssueRow({required this.issue});

  @override
  Widget build(BuildContext context) {
    final color = switch (issue.severity) {
      'critical' => const Color(0xFFFF8A80),
      'warning' => const Color(0xFFFFCC80),
      _ => Colors.white60,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${issue.severity.toUpperCase()} · ${issue.field}',
            style: TextStyle(fontSize: 11, color: color),
          ),
          Text(
            issue.message,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          Text(
            issue.suggestedAction,
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
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

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final String? tooltip;
  const _Pill({required this.label, required this.color, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(34),
        border: Border.all(color: color.withAlpha(68)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}

class _ProjectBundleExportRequest {
  final String path;
  final bool includeFiles;

  const _ProjectBundleExportRequest({
    required this.path,
    required this.includeFiles,
  });
}

class _MiniPill extends StatelessWidget {
  final String label;
  final String value;
  const _MiniPill(this.label, this.value);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withAlpha(8),
      border: Border.all(color: _kLine),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      '$label: $value',
      style: const TextStyle(fontSize: 11, color: Colors.white70),
    ),
  );
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

class _GitVisibilityDialog extends StatelessWidget {
  final LocalGitVisibilityReport report;

  const _GitVisibilityDialog({required this.report});

  @override
  Widget build(BuildContext context) {
    final sha = report.headSha;
    final shortSha = sha == null
        ? null
        : sha.length <= 8
        ? sha
        : sha.substring(0, 8);
    return AlertDialog(
      backgroundColor: _kPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _kLine),
      ),
      title: const Text('Git visibility'),
      content: SizedBox(
        width: 780,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              report.gitRoot ?? report.requestedPath,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniPill('Branch', report.branch ?? 'unknown'),
                _MiniPill('HEAD', shortSha ?? 'unknown'),
                _MiniPill('Compare', report.comparisonRef ?? 'none'),
                _MiniPill(
                  'Remote',
                  report.remoteUrl == null ? 'none' : 'origin',
                ),
                _MiniPill('Tracked', '${report.localTrackedCount}'),
                _MiniPill('Remote files', '${report.remoteTrackedCount}'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _GitMetric(
                  label: 'Local only',
                  value: report.localOnlyTrackedCount,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 8),
                _GitMetric(
                  label: 'Remote only',
                  value: report.remoteOnlyTrackedCount,
                  color: Colors.lightBlueAccent,
                ),
                const SizedBox(width: 8),
                _GitMetric(
                  label: 'Changed',
                  value: report.changedTrackedCount,
                  color: Colors.amber,
                ),
                const SizedBox(width: 8),
                _GitMetric(
                  label: 'Untracked',
                  value: report.untrackedCount,
                  color: Colors.purpleAccent,
                ),
                const SizedBox(width: 8),
                _GitMetric(
                  label: 'Ignored',
                  value: report.ignoredCount,
                  color: Colors.greenAccent,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  _GitPathGroup(
                    title: 'Local tracked not in compare ref',
                    paths: report.localOnlyTrackedPaths,
                  ),
                  _GitPathGroup(
                    title: 'Compare ref not in local tracked tree',
                    paths: report.remoteOnlyTrackedPaths,
                  ),
                  _GitPathGroup(
                    title: 'Changed tracked files',
                    paths: report.changedTrackedPaths,
                  ),
                  _GitPathGroup(
                    title: 'Untracked files',
                    paths: report.untrackedPaths,
                  ),
                  _GitPathGroup(
                    title: 'Ignored files',
                    paths: report.ignoredPaths,
                  ),
                  _GitPathGroup(
                    title: 'Suggested .gitignore entries',
                    paths: report.suggestedIgnoreEntries,
                  ),
                  if (report.warnings.isNotEmpty)
                    _GitPathGroup(title: 'Warnings', paths: report.warnings),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _GitMetric extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _GitMetric({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(18),
          border: Border.all(color: color.withAlpha(58)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const Spacer(),
            Text(
              '$value',
              style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GitPathGroup extends StatelessWidget {
  final String title;
  final List<String> paths;

  const _GitPathGroup({required this.title, required this.paths});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Text(title, style: const TextStyle(fontSize: 13)),
          trailing: _MiniPill('Count', '${paths.length}'),
          initiallyExpanded: paths.isNotEmpty && paths.length <= 8,
          children: [
            if (paths.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'None',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              )
            else
              for (final path in paths.take(80))
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    path,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
            if (paths.length > 80)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${paths.length - 80} more',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _MetricCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1115),
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: value > 0 ? color : Colors.white24,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    ),
  );
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
                  _MiniPill('Project', '${active.length}'),
                  const SizedBox(width: 6),
                  _MiniPill('LLM', '${pendingQueue.length}'),
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
            _SummaryRunProvenance(projectId: projectId),
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
                    _MiniPill(
                      'Docs',
                      '${currentPacket.includedDocumentCount}/${currentPacket.suppliedDocumentCount}',
                    ),
                    _MiniPill(
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

class _ProjectChangeLogSection extends StatefulWidget {
  final String projectId;

  const _ProjectChangeLogSection({required this.projectId});

  @override
  State<_ProjectChangeLogSection> createState() =>
      _ProjectChangeLogSectionState();
}

class _ProjectChangeLogSectionState extends State<_ProjectChangeLogSection> {
  String _window = '30';
  String _sort = 'newest';
  Future<List<ProjectChangeLogEntry>>? _future;
  String? _changeSummary;
  DateTime? _changeSummaryAt;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) {
      _future = _load();
      _loadLatestChangeSummary();
    }
  }

  @override
  void didUpdateWidget(covariant _ProjectChangeLogSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) {
      _future = _load();
      _changeSummary = null;
      _changeSummaryAt = null;
      _loadLatestChangeSummary();
    }
  }

  DateTime? get _since {
    final days = switch (_window) {
      '7' => 7,
      '30' => 30,
      '90' => 90,
      _ => null,
    };
    return days == null ? null : DateTime.now().subtract(Duration(days: days));
  }

  Future<List<ProjectChangeLogEntry>> _load() =>
      AppStateScope.of(context).getProjectChangeLog(
        widget.projectId,
        since: _since,
        limit: 80,
        newestFirst: _sort == 'newest',
      );

  void _loadLatestChangeSummary() {
    final projectId = widget.projectId;
    unawaited(() async {
      final draft = await AppStateScope.of(
        context,
      ).getLatestProjectChangeSummaryDraft(projectId);
      if (!mounted || widget.projectId != projectId || draft == null) return;
      setState(() {
        _changeSummary = draft.body;
        _changeSummaryAt = draft.createdAt;
      });
    }());
  }

  void _refresh() {
    setState(() => _future = _load());
  }

  Future<void> _copyJson(List<ProjectChangeLogEntry> rows) async {
    final data = rows.map((entry) => entry.toJson()).toList();
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${rows.length} project change(s).')),
    );
  }

  Future<void> _copySummary() async {
    final text = _changeSummary;
    if (text == null || text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied change summary.')));
  }

  void _summarizeChanges() {
    final projectId = widget.projectId;
    final future = AppStateScope.of(
      context,
    ).startProjectChangeSummary(projectId, since: _since, limit: 80);
    unawaited(() async {
      try {
        final result = await future;
        if (!mounted) return;
        if (widget.projectId != projectId) return;
        if (result.isSuccess) {
          _loadLatestChangeSummary();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Change summary draft saved.')),
          );
        }
      } catch (error) {
        if (!mounted) return;
        if (widget.projectId != projectId) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Change summary failed: $error')),
        );
      }
    }());
  }

  Color _levelColor(String level) => switch (level) {
    'error' => const Color(0xFFFF8A80),
    'warn' => Colors.amber,
    'debug' => Colors.white38,
    _ => _kPrimary,
  };

  String _formatValue(Object? value) {
    if (value == null) return 'blank';
    final text = '$value'.trim();
    if (text.isEmpty) return 'blank';
    return text.length <= 90 ? text : '${text.substring(0, 90)}...';
  }

  Widget _changedFieldsView(ProjectChangeLogEntry entry) {
    if (entry.changedFields.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: entry.changedFields.entries.map((field) {
          final value = field.value;
          Object? from;
          Object? to;
          if (value is Map) {
            from = value['from'];
            to = value['to'];
          }
          final detail = value is Map
              ? '${_formatValue(from)} -> ${_formatValue(to)}'
              : _formatValue(value);
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${field.key}: $detail',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _mapBlock(String label, Map<String, Object?> value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return _rawBlock(label, const JsonEncoder.withIndent('  ').convert(value));
  }

  Widget _rawBlock(String label, String? value) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(40),
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText(
        '$label:\n$value',
        style: const TextStyle(fontSize: 11, color: Colors.white70),
      ),
    );
  }

  Color _actorTypeColor(String actorType) => switch (actorType) {
    'ai_model' => const Color(0xFFCE93D8),
    'system' => const Color(0xFF90CAF9),
    'mcp' => const Color(0xFFFFCC80),
    'import' => const Color(0xFFA5D6A7),
    _ => _kPrimary,
  };

  Widget _changeRow(ProjectChangeLogEntry entry) {
    final color = _levelColor(entry.level);
    final actorColor = _actorTypeColor(entry.actorType);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(Icons.history, color: color, size: 18),
          title: Text(
            entry.summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${entry.actor} - ${_compactDateTime(entry.timestamp)} - ${entry.area}.${entry.action}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
          trailing: _Pill(label: entry.level, color: color),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Pill(label: entry.actorType, color: actorColor),
                _MiniPill('Source event', entry.sourceEventId),
                if ((entry.entityType ?? '').isNotEmpty)
                  _MiniPill('Entity', '${entry.entityType}:${entry.entityId}'),
                if ((entry.correlationId ?? '').isNotEmpty)
                  _MiniPill('Correlation', entry.correlationId!),
              ],
            ),
            const SizedBox(height: 8),
            _changedFieldsView(entry),
            _mapBlock('Before', entry.beforeJson),
            _mapBlock('After', entry.afterJson),
            _mapBlock('Input', entry.input),
            _mapBlock('Output', entry.output),
            _rawBlock('Error', entry.error),
            _rawBlock('Stack', entry.stackTrace),
          ],
        ),
      ),
    );
  }

  Widget _changeSummaryPanel(ProjectChangeSummaryRunStatus? runStatus) {
    final running = runStatus?.isRunning == true;
    final error = running ? null : runStatus?.error;
    final summary = _changeSummary;
    if (!running &&
        (summary == null || summary.trim().isEmpty) &&
        (error == null || error.trim().isEmpty)) {
      return const SizedBox.shrink();
    }
    final hasSummary = summary != null && summary.trim().isNotEmpty;
    final showError = !running && !hasSummary && error != null;
    final title = running
        ? 'AI change summary running'
        : hasSummary
        ? 'Latest AI change summary'
        : 'Summary failed';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(
          color: showError ? Colors.redAccent.withAlpha(120) : _kLine,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                running || hasSummary
                    ? Icons.auto_awesome_outlined
                    : Icons.error_outline,
                color: running || hasSummary ? _kPrimary : Colors.redAccent,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_changeSummaryAt != null)
                _MiniPill('Updated', _compactDateTime(_changeSummaryAt!)),
              if (hasSummary) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Copy summary',
                  onPressed: _copySummary,
                  icon: const Icon(Icons.copy, size: 16),
                ),
              ],
            ],
          ),
          if (running) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 8),
            const Text(
              'Still running in the background. You can leave this screen; a successful result will be saved to the project.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ] else ...[
            const SizedBox(height: 8),
            SelectableText(
              hasSummary ? summary : (error ?? ''),
              style: TextStyle(
                fontSize: 12,
                color: showError ? Colors.redAccent : Colors.white70,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final runStatus = state.getProjectChangeSummaryRunStatus(widget.projectId);
    final summaryRunning = runStatus?.isRunning == true;
    return FutureBuilder<List<ProjectChangeLogEntry>>(
      future: _future,
      builder: (context, snap) {
        final rows = snap.data ?? const <ProjectChangeLogEntry>[];
        final loading = snap.connectionState != ConnectionState.done;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _MiniPill('Changes', '${rows.length}'),
                DropdownButton<String>(
                  value: _window,
                  items: const [
                    DropdownMenuItem(value: '7', child: Text('Last 7 days')),
                    DropdownMenuItem(value: '30', child: Text('Last 30 days')),
                    DropdownMenuItem(value: '90', child: Text('Last 90 days')),
                    DropdownMenuItem(value: 'all', child: Text('All recent')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _window = value;
                      _future = _load();
                    });
                  },
                ),
                DropdownButton<String>(
                  value: _sort,
                  items: const [
                    DropdownMenuItem(
                      value: 'newest',
                      child: Text('Newest first'),
                    ),
                    DropdownMenuItem(
                      value: 'oldest',
                      child: Text('Oldest first'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _sort = value;
                      _future = _load();
                    });
                  },
                ),
                OutlinedButton.icon(
                  onPressed: loading ? null : _refresh,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                ),
                OutlinedButton.icon(
                  onPressed: rows.isEmpty ? null : () => _copyJson(rows),
                  icon: const Icon(Icons.data_object, size: 16),
                  label: const Text('Copy JSON'),
                ),
                if (state.projectAiSummariesEnabled)
                  OutlinedButton.icon(
                    onPressed: rows.isEmpty || loading || summaryRunning
                        ? null
                        : _summarizeChanges,
                    icon: summaryRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_outlined, size: 16),
                    label: Text(
                      summaryRunning ? 'Summarizing' : 'Summarize changes',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _changeSummaryPanel(runStatus),
            if (snap.hasError)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(18),
                  border: Border.all(color: Colors.red.withAlpha(80)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Change log failed to load: ${snap.error}',
                  style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                ),
              )
            else if (loading)
              const LinearProgressIndicator(minHeight: 2)
            else if (rows.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(6),
                  border: Border.all(color: _kLine),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'No project changes in this window.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              )
            else
              ...rows.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _changeRow(entry),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SummaryRunProvenance extends StatelessWidget {
  final String projectId;

  const _SummaryRunProvenance({required this.projectId});

  Object? _field(Map<String, Object?> map, String key) => map[key];

  Map<String, Object?> _nestedMap(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is Map) return value.map((k, v) => MapEntry('$k', v));
    return const <String, Object?>{};
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<EventLogData>>(
      stream: state.watchRecentEvents(),
      builder: (context, snap) {
        final rows = (snap.data ?? const <EventLogData>[])
            .where(
              (event) =>
                  event.area == 'ai' &&
                  event.entityType == 'project_summary' &&
                  event.entityId == projectId &&
                  const {
                    'project_summary_draft_saved',
                    'project_summary_failed',
                  }.contains(event.action),
            )
            .take(3)
            .toList(growable: false);
        if (rows.isEmpty) return const SizedBox.shrink();

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
              const Row(
                children: [
                  Icon(Icons.history, size: 15, color: _kPrimary),
                  SizedBox(width: 6),
                  Text(
                    'Recent summary runs',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...rows.map((event) {
                final data = _tryParseJsonObject(event.outputJson);
                final evidence = _nestedMap(data, 'evidence');
                final success = data['success'] == true;
                final model = (_field(data, 'model') ?? 'model n/a').toString();
                final trigger = (_field(data, 'trigger') ?? 'manual')
                    .toString();
                final docs = (_field(evidence, 'includedDocumentCount') ?? '-')
                    .toString();
                final chars = (_field(evidence, 'totalExcerptChars') ?? '0')
                    .toString();
                final codes = data['validationIssueCodes'];
                final codeText = codes is List && codes.isNotEmpty
                    ? codes.map((code) => '$code').join(', ')
                    : null;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        success
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 14,
                        color: success
                            ? const Color(0xFF4CAF50)
                            : const Color(0xFFFF8A80),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${success ? 'Saved' : 'Failed'} - $model - $trigger',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                            ),
                            Text(
                              '${_compactDateTime(event.timestamp)} - docs $docs - chars $chars${codeText == null ? '' : ' - $codeText'}',
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
              }),
            ],
          ),
        );
      },
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
                                  _libraryRouteForProject(
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

class _QuickBar extends StatelessWidget {
  final Project project;
  final int activeCount, blockedCount, overdueCount, urgentCount;
  final VoidCallback onEditMeta;

  const _QuickBar({
    required this.project,
    required this.activeCount,
    required this.blockedCount,
    required this.overdueCount,
    required this.urgentCount,
    required this.onEditMeta,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kPanel,
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Pill(
                label: projectStatusLabel(project.status),
                color: projectStatusColor(project.status),
                tooltip:
                    '${projectStatusDescriptor(project.status)}: '
                    '${projectStatusDescription(project.status)}',
              ),
              if (normalizeProjectCategory(project.category) != null) ...[
                const SizedBox(width: 6),
                _Pill(
                  label: projectCategoryLabel(project.category),
                  color: const Color(0xFF00BCD4),
                ),
              ],
              if ((project.phase ?? '').isNotEmpty) ...[
                const SizedBox(width: 6),
                _Pill(label: project.phase!, color: _pc(project.phase)),
              ],
              if ((project.priority ?? '').isNotEmpty &&
                  project.priority != 'normal') ...[
                const SizedBox(width: 6),
                _Pill(label: project.priority!, color: _prc(project.priority)),
              ],
              if ((project.owner ?? '').isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  'Owner: ${project.owner}',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ],
              const Spacer(),
              TextButton(
                onPressed: onEditMeta,
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFF79A7FF).withAlpha(26),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0x3379A7FF)),
                  ),
                ),
                child: const Text(
                  'Edit metadata',
                  style: TextStyle(fontSize: 11, color: _kPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _MetricCard(
                label: 'Open',
                value: activeCount,
                color: const Color(0xFF448AFF),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Blocked',
                value: blockedCount,
                color: const Color(0xFF9C27B0),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Overdue',
                value: overdueCount,
                color: const Color(0xFFF44336),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Urgent',
                value: urgentCount,
                color: const Color(0xFFFF6D00),
              ),
            ],
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

class _FieldRow extends StatelessWidget {
  final String label;
  final String? value;
  final String placeholder;
  final VoidCallback? onEdit;

  const _FieldRow({
    required this.label,
    required this.value,
    required this.placeholder,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value?.trim().isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onEdit,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      hasValue ? value! : placeholder,
                      style: TextStyle(
                        fontSize: 13,
                        color: hasValue
                            ? const Color(0xDEFFFFFF)
                            : Colors.white24,
                        height: 1.5,
                      ),
                    ),
                  ),
                  if (onEdit != null) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.edit_outlined,
                      size: 13,
                      color: Colors.white24,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentitySection extends StatelessWidget {
  final String projectId;
  final Project project;
  final VoidCallback onEdit;
  final VoidCallback onReplaceGithub;
  final VoidCallback onForgetGithub;
  const _IdentitySection({
    required this.projectId,
    required this.project,
    required this.onEdit,
    required this.onReplaceGithub,
    required this.onForgetGithub,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _FieldRow(
          label: 'Purpose',
          value: project.description,
          placeholder: 'Not recorded — click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Desired outcome',
          value: project.desiredOutcome,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Success criteria',
          value: project.successCriteria,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Scope included',
          value: project.scopeIncluded,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Scope excluded',
          value: project.scopeExcluded,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _GithubIdentityRow(
          projectId: projectId,
          onReplaceGithub: onReplaceGithub,
          onForgetGithub: onForgetGithub,
        ),
      ],
    );
  }
}

class _GithubIdentityRow extends StatelessWidget {
  final String projectId;
  final VoidCallback onReplaceGithub;
  final VoidCallback onForgetGithub;

  const _GithubIdentityRow({
    required this.projectId,
    required this.onReplaceGithub,
    required this.onForgetGithub,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return FutureBuilder<ProjectGitRemoteStatus?>(
      future: state.getLatestProjectGitRemoteStatus(projectId),
      builder: (context, remoteSnap) {
        final remote = remoteSnap.data;
        if (remote != null) {
          final details = [
            'Cached: ${remote.htmlUrl ?? remote.remoteUrl}',
            if ((remote.visibility ?? '').isNotEmpty) remote.visibility!,
            if (remote.hasError) 'warning saved',
          ];
          return _GithubRepositoryControls(
            value: details.join(' - '),
            onReplaceGithub: onReplaceGithub,
            onForgetGithub: onForgetGithub,
            canForget: true,
          );
        }
        if (remoteSnap.connectionState == ConnectionState.waiting) {
          return const _FieldRow(
            label: 'GitHub repository',
            value: 'Loading...',
            placeholder: '',
          );
        }
        return FutureBuilder<ProjectObservation?>(
          future: state.getLatestLocalProjectObservation(projectId),
          builder: (context, observationSnap) {
            final identity = GithubRemoteMetadataService.parseGithubRemoteUrl(
              observationSnap.data?.remoteUrl,
            );
            if (identity != null) {
              return _GithubRepositoryControls(
                value: 'Observed origin: ${identity.htmlUrl}',
                onReplaceGithub: onReplaceGithub,
                onForgetGithub: onForgetGithub,
                canForget: false,
              );
            }
            if (observationSnap.connectionState == ConnectionState.waiting) {
              return const _FieldRow(
                label: 'GitHub repository',
                value: 'Loading...',
                placeholder: '',
              );
            }
            return _GithubRepositoryControls(
              value: null,
              onReplaceGithub: onReplaceGithub,
              onForgetGithub: onForgetGithub,
              canForget: false,
            );
          },
        );
      },
    );
  }
}

class _GithubRepositoryControls extends StatelessWidget {
  final String? value;
  final VoidCallback onReplaceGithub;
  final VoidCallback onForgetGithub;
  final bool canForget;

  const _GithubRepositoryControls({
    required this.value,
    required this.onReplaceGithub,
    required this.onForgetGithub,
    required this.canForget,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldRow(
          label: 'GitHub repository',
          value: value,
          placeholder: 'No GitHub repository recorded',
        ),
        Padding(
          padding: const EdgeInsets.only(left: 140, bottom: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onReplaceGithub,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Replace GitHub'),
              ),
              OutlinedButton.icon(
                onPressed: canForget ? onForgetGithub : null,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Forget cached'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProjectCommandToolbar extends StatefulWidget {
  final String projectId;
  final Future<void> Function() onOpenWorkboard;
  final VoidCallback onEditMeta;
  final VoidCallback onExportBundle;

  const _ProjectCommandToolbar({
    required this.projectId,
    required this.onOpenWorkboard,
    required this.onEditMeta,
    required this.onExportBundle,
  });

  @override
  State<_ProjectCommandToolbar> createState() => _ProjectCommandToolbarState();
}

class _ProjectCommandToolbarState extends State<_ProjectCommandToolbar> {
  bool _openingWorkboard = false;
  bool _launching = false;
  bool _testing = false;
  bool _checkingCapsule = false;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF10151D),
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: StreamBuilder<ProjectRuntimeProfile?>(
        stream: state.watchProjectRuntimeProfile(widget.projectId),
        builder: (context, profileSnap) {
          final profile = profileSnap.data;
          final runtimeReady = profile != null && profile.enabled;
          final tests = profile == null
              ? const <String>[]
              : runtime.decodeStringList(profile.testCommandsJson);
          final capsuleEnabled = profile?.capsuleEnabled ?? false;
          return StreamBuilder<List<ProjectRuntimeRun>>(
            stream: state.watchProjectRuntimeRuns(widget.projectId, limit: 5),
            builder: (context, runSnap) {
              final runs = runSnap.data ?? const <ProjectRuntimeRun>[];
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _ProjectToolbarButton(
                    tooltip: 'Open work board',
                    icon: Icons.view_kanban_outlined,
                    label: 'Work board',
                    busy: _openingWorkboard,
                    onPressed: () async {
                      if (_openingWorkboard) return;
                      setState(() => _openingWorkboard = true);
                      try {
                        await widget.onOpenWorkboard();
                      } finally {
                        if (mounted) {
                          setState(() => _openingWorkboard = false);
                        }
                      }
                    },
                  ),
                  _ProjectToolbarButton(
                    tooltip: 'Edit metadata',
                    icon: Icons.edit_note_outlined,
                    label: 'Metadata',
                    onPressed: widget.onEditMeta,
                  ),
                  _ProjectToolbarButton(
                    tooltip: 'Export project bundle',
                    icon: Icons.archive_outlined,
                    label: 'Export',
                    onPressed: widget.onExportBundle,
                  ),
                  _ProjectToolbarButton(
                    tooltip: runtimeReady
                        ? 'Launch project'
                        : 'No runtime profile configured',
                    icon: Icons.rocket_launch_outlined,
                    label: 'Launch',
                    busy: _launching,
                    color: _latestRuntimeRunColor(runs, 'launch'),
                    onPressed: runtimeReady
                        ? () => _runRuntimeAction(
                            action: 'launch',
                            body: () =>
                                state.launchProjectRuntime(widget.projectId),
                          )
                        : null,
                  ),
                  _ProjectToolbarButton(
                    tooltip: runtimeReady
                        ? (tests.isEmpty ? 'No test command' : 'Run tests')
                        : 'No runtime profile configured',
                    icon: Icons.fact_check_outlined,
                    label: 'Tests',
                    busy: _testing,
                    color: _latestRuntimeRunColor(runs, 'test'),
                    onPressed: runtimeReady && tests.isNotEmpty
                        ? () => _runRuntimeAction(
                            action: 'test',
                            body: () =>
                                state.runProjectRuntimeTest(widget.projectId),
                            showResult: true,
                          )
                        : null,
                  ),
                  _ProjectToolbarButton(
                    tooltip: runtimeReady
                        ? (capsuleEnabled
                              ? 'Run capsule check'
                              : 'Capsule disabled')
                        : 'No runtime profile configured',
                    icon: Icons.health_and_safety_outlined,
                    label: 'Capsule',
                    busy: _checkingCapsule,
                    color: _latestRuntimeRunColor(runs, 'capsule'),
                    onPressed: runtimeReady && capsuleEnabled
                        ? () => _runRuntimeAction(
                            action: 'capsule',
                            body: () => state.runProjectRuntimeCapsule(
                              widget.projectId,
                            ),
                            showResult: true,
                          )
                        : null,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _runRuntimeAction({
    required String action,
    required Future<ProjectRuntimeRun> Function() body,
    bool showResult = false,
  }) async {
    if (_isBusy(action)) return;
    final label = _runtimeActionLabel(action);
    setState(() => _setBusy(action, true));
    try {
      final run = await body();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_runtimeRunMessage(label, run))));
      if (showResult && mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => _RuntimeRunDialog(run: run, label: label),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label failed: $error')));
    } finally {
      if (mounted) setState(() => _setBusy(action, false));
    }
  }

  bool _isBusy(String action) => switch (action) {
    'launch' => _launching,
    'test' => _testing,
    'capsule' => _checkingCapsule,
    _ => false,
  };

  void _setBusy(String action, bool value) {
    switch (action) {
      case 'launch':
        _launching = value;
        break;
      case 'test':
        _testing = value;
        break;
      case 'capsule':
        _checkingCapsule = value;
        break;
    }
  }
}

class _ProjectToolbarButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final String label;
  final bool busy;
  final Color? color;
  final VoidCallback? onPressed;

  const _ProjectToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.label,
    this.busy = false,
    this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final effectiveColor = enabled ? color : Colors.white24;
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 16, color: effectiveColor),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: const Size(0, 36),
        ),
      ),
    );
  }
}

class _ProjectRuntimeSection extends StatefulWidget {
  final String projectId;
  final VoidCallback onEdit;

  const _ProjectRuntimeSection({required this.projectId, required this.onEdit});

  @override
  State<_ProjectRuntimeSection> createState() => _ProjectRuntimeSectionState();
}

class _ProjectRuntimeSectionState extends State<_ProjectRuntimeSection> {
  bool _launching = false;
  String? _testingCommand;
  bool _checkingCapsule = false;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<ProjectRuntimeProfile?>(
      stream: state.watchProjectRuntimeProfile(widget.projectId),
      builder: (context, profileSnap) {
        final profile = profileSnap.data;
        if (profileSnap.connectionState == ConnectionState.waiting) {
          return const LinearProgressIndicator(minHeight: 2);
        }
        if (profile == null || !profile.enabled) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'No runtime profile configured.',
                style: TextStyle(fontSize: 13, color: Colors.white38),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: widget.onEdit,
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: const Text('Configure runtime'),
              ),
            ],
          );
        }
        final tests = runtime.decodeStringList(profile.testCommandsJson);
        final ports = runtime.decodeIntList(profile.portsJson);
        final urls = runtime.decodeRuntimeUrls(profile.urlsJson);
        final healthUrls = runtime.decodeStringList(profile.healthUrlsJson);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniPill('Mode', profile.enabled ? 'enabled' : 'off'),
                if (profile.capsuleEnabled)
                  _MiniPill('Capsule', profile.capsuleMode)
                else
                  const _MiniPill('Capsule', 'off'),
                if (profile.autostart) const _MiniPill('Autostart', 'yes'),
                if (ports.isNotEmpty) _MiniPill('Ports', ports.join(', ')),
              ],
            ),
            const SizedBox(height: 10),
            _FieldRow(
              label: 'Working directory',
              value: profile.workingDirectory,
              placeholder: 'Not configured',
              onEdit: widget.onEdit,
            ),
            const Divider(height: 1, color: Color(0x44273044)),
            _FieldRow(
              label: 'Launch command',
              value: profile.launchCommand,
              placeholder: 'Not configured',
              onEdit: widget.onEdit,
            ),
            const Divider(height: 1, color: Color(0x44273044)),
            _FieldRow(
              label: 'Stop command',
              value: profile.stopCommand,
              placeholder: 'Not configured',
              onEdit: widget.onEdit,
            ),
            if (urls.isNotEmpty) ...[
              const Divider(height: 1, color: Color(0x44273044)),
              _FieldRow(
                label: 'URLs',
                value: urls.map((url) => '${url.label}: ${url.url}').join('\n'),
                placeholder: '',
              ),
            ],
            if (healthUrls.isNotEmpty) ...[
              const Divider(height: 1, color: Color(0x44273044)),
              _FieldRow(
                label: 'Health URLs',
                value: healthUrls.join('\n'),
                placeholder: '',
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _launching
                      ? null
                      : () => _runRuntimeAction(
                          label: 'Launch',
                          busy: 'launch',
                          body: () =>
                              state.launchProjectRuntime(widget.projectId),
                        ),
                  icon: _launching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.rocket_launch_outlined, size: 16),
                  label: const Text('Launch'),
                ),
                OutlinedButton.icon(
                  onPressed: profile.capsuleEnabled && !_checkingCapsule
                      ? () => _runRuntimeAction(
                          label: 'Capsule',
                          busy: 'capsule',
                          body: () =>
                              state.runProjectRuntimeCapsule(widget.projectId),
                          showResult: true,
                        )
                      : null,
                  icon: _checkingCapsule
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.health_and_safety_outlined, size: 16),
                  label: const Text('Capsule'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit_note_outlined, size: 16),
                  label: const Text('Edit'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (tests.isEmpty)
              const Text(
                'No test commands configured.',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              )
            else ...[
              const Text(
                'Tests',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              ...tests.map(
                (command) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          command,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _testingCommand == null
                            ? () => _runRuntimeAction(
                                label: 'Test',
                                busy: 'test',
                                command: command,
                                body: () => state.runProjectRuntimeTest(
                                  widget.projectId,
                                  command: command,
                                ),
                                showResult: true,
                              )
                            : null,
                        icon: _testingCommand == command
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.fact_check_outlined, size: 16),
                        label: const Text('Run'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _RuntimeRunHistory(projectId: widget.projectId),
          ],
        );
      },
    );
  }

  Future<void> _runRuntimeAction({
    required String label,
    required String busy,
    required Future<ProjectRuntimeRun> Function() body,
    String? command,
    bool showResult = false,
  }) async {
    setState(() {
      if (busy == 'launch') _launching = true;
      if (busy == 'capsule') _checkingCapsule = true;
      if (busy == 'test') _testingCommand = command ?? '';
    });
    try {
      final run = await body();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_runtimeRunMessage(label, run))));
      if (showResult && mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => _RuntimeRunDialog(run: run, label: label),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label failed: $error')));
    } finally {
      if (mounted) {
        setState(() {
          if (busy == 'launch') _launching = false;
          if (busy == 'capsule') _checkingCapsule = false;
          if (busy == 'test') _testingCommand = null;
        });
      }
    }
  }
}

class _RuntimeRunHistory extends StatelessWidget {
  final String projectId;

  const _RuntimeRunHistory({required this.projectId});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<ProjectRuntimeRun>>(
      stream: state.watchProjectRuntimeRuns(projectId, limit: 8),
      builder: (context, snap) {
        final runs = snap.data ?? const <ProjectRuntimeRun>[];
        if (runs.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recent runtime runs',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            ...runs.map(
              (run) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _runtimeRunIcon(run),
                  size: 18,
                  color: _runtimeRunColor(run),
                ),
                title: Text(
                  '${run.action} - ${run.status}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_compactDateTime(run.startedAt)}'
                  '${run.capsuleStatus == null ? '' : ' - capsule ${run.capsuleStatus}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right, size: 16),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => _RuntimeRunDialog(
                    run: run,
                    label: _runtimeActionLabel(run.action),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RuntimeRunDialog extends StatelessWidget {
  final ProjectRuntimeRun run;
  final String label;

  const _RuntimeRunDialog({required this.run, required this.label});

  @override
  Widget build(BuildContext context) {
    final text = [
      'Status: ${run.status}',
      'Started: ${_compactDateTime(run.startedAt)}',
      if (run.completedAt != null)
        'Completed: ${_compactDateTime(run.completedAt)}',
      if ((run.capsuleStatus ?? '').isNotEmpty) 'Capsule: ${run.capsuleStatus}',
      if ((run.command ?? '').isNotEmpty) 'Command: ${run.command}',
      if (run.exitCode != null) 'Exit code: ${run.exitCode}',
      if ((run.outputText ?? '').isNotEmpty) '\nOutput:\n${run.outputText}',
      if ((run.errorText ?? '').isNotEmpty) '\nError:\n${run.errorText}',
      if ((run.capsuleOutputText ?? '').isNotEmpty)
        '\nCapsule output:\n${run.capsuleOutputText}',
    ].join('\n');
    return AlertDialog(
      title: Text('$label result'),
      content: SizedBox(
        width: 760,
        height: 480,
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

IconData _runtimeRunIcon(ProjectRuntimeRun run) => switch (run.action) {
  'launch' => Icons.rocket_launch_outlined,
  'test' => Icons.fact_check_outlined,
  'capsule' => Icons.health_and_safety_outlined,
  _ => Icons.terminal_outlined,
};

Color _runtimeRunColor(ProjectRuntimeRun run) => switch (run.status) {
  'succeeded' || 'started' => const Color(0xFF4CAF50),
  'running' => _kPrimary,
  'failed' => const Color(0xFFFF8A80),
  _ => Colors.white54,
};

Color _latestRuntimeRunColor(List<ProjectRuntimeRun> runs, String action) {
  for (final run in runs) {
    if (run.action == action) return _runtimeRunColor(run);
  }
  return Colors.white54;
}

String _runtimeActionLabel(String action) => switch (action) {
  'launch' => 'Launch',
  'test' => 'Test',
  'capsule' => 'Capsule',
  _ => action,
};

String _runtimeRunMessage(String label, ProjectRuntimeRun run) {
  final capsule = (run.capsuleStatus ?? '').isEmpty
      ? ''
      : ' Capsule: ${run.capsuleStatus}.';
  if (run.status == 'started') return '$label started.$capsule';
  if (run.status == 'succeeded') return '$label succeeded.$capsule';
  return '$label ${run.status}.$capsule';
}

class _LocalRepoSection extends StatelessWidget {
  final String projectId;
  final VoidCallback onChooseLocalRepo;
  final VoidCallback onAssociateFile;
  final VoidCallback onAssociateFolder;
  final VoidCallback onPreviewRefresh;
  final VoidCallback onExportBundle;
  final VoidCallback onInspectGit;
  final VoidCallback onRefreshGithub;

  const _LocalRepoSection({
    required this.projectId,
    required this.onChooseLocalRepo,
    required this.onAssociateFile,
    required this.onAssociateFolder,
    required this.onPreviewRefresh,
    required this.onExportBundle,
    required this.onInspectGit,
    required this.onRefreshGithub,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return FutureBuilder<ProjectLocalRepoSummary?>(
      future: state.getProjectLocalRepoSummary(projectId),
      builder: (context, registrySnap) {
        final summary = registrySnap.data;
        if (registrySnap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        if (summary == null) {
          return const SizedBox.shrink();
        }
        final registry = summary.registry;
        if (registry == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This Atlas project is not linked to a local repo folder.',
                style: TextStyle(fontSize: 13, color: Colors.white38),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: onChooseLocalRepo,
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('Add folder'),
              ),
              const SizedBox(height: 12),
              _LocalRepoAssociatedFiles(summary: summary),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: onAssociateFile,
                    icon: const Icon(Icons.attach_file, size: 16),
                    label: const Text('Associate file'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onAssociateFolder,
                    icon: const Icon(Icons.folder_copy_outlined, size: 16),
                    label: const Text('Associate folder'),
                  ),
                ],
              ),
            ],
          );
        }
        final observation = summary.observation;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _FieldRow(
              label: 'Repo root',
              value: summary.repoRoot,
              placeholder: '',
            ),
            if (summary.repoRoot != registry.localPath) ...[
              const Divider(height: 1, color: Color(0x44273044)),
              _FieldRow(
                label: 'Selected folder',
                value: registry.localPath,
                placeholder: '',
              ),
            ],
            const Divider(height: 1, color: Color(0x44273044)),
            _FieldRow(
              label: 'Registry state',
              value: '${registry.classification} - ${registry.reviewState}',
              placeholder: '',
            ),
            if (observation != null) ...[
              const Divider(height: 1, color: Color(0x44273044)),
              _FieldRow(
                label: 'Last observation',
                value: [
                  if ((observation.branch ?? '').isNotEmpty)
                    'branch ${observation.branch}',
                  if ((observation.headSha ?? '').isNotEmpty)
                    'sha ${_shortSha(observation.headSha!)}',
                  if (observation.dirtyCount != null)
                    '${observation.dirtyCount} dirty',
                ].join(' - '),
                placeholder: 'No git facts recorded',
              ),
            ],
            const Divider(height: 1, color: Color(0x44273044)),
            FutureBuilder<ProjectGitRemoteStatus?>(
              future: state.getLatestProjectGitRemoteStatus(projectId),
              builder: (context, remoteSnap) {
                final remote = remoteSnap.data;
                if (remoteSnap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  );
                }
                if (remote == null) {
                  return const _FieldRow(
                    label: 'GitHub',
                    value: 'No cached GitHub metadata',
                    placeholder: '',
                  );
                }
                final visibility = remote.visibility ?? 'unknown';
                final warning = remote.hasError ? ' - warning saved' : '';
                return Column(
                  children: [
                    _FieldRow(
                      label: 'GitHub',
                      value: '${remote.fullName} - $visibility$warning',
                      placeholder: '',
                    ),
                    const Divider(height: 1, color: Color(0x44273044)),
                    _FieldRow(
                      label: 'Remote check',
                      value: [
                        if ((remote.defaultBranch ?? '').isNotEmpty)
                          'default ${remote.defaultBranch}',
                        if ((remote.onlineHeadSha ?? '').isNotEmpty)
                          'head ${_shortSha(remote.onlineHeadSha!)}',
                        'checked ${_compactDate(remote.checkedAt)}',
                      ].join(' - '),
                      placeholder: '',
                    ),
                    if (remote.hasError) ...[
                      const Divider(height: 1, color: Color(0x44273044)),
                      _FieldRow(
                        label: 'GitHub warning',
                        value: remote.error,
                        placeholder: '',
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            _LocalRepoAssociatedFiles(summary: summary),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onPreviewRefresh,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Preview refresh'),
                ),
                OutlinedButton.icon(
                  onPressed: onChooseLocalRepo,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('Replace folder'),
                ),
                OutlinedButton.icon(
                  onPressed: onAssociateFile,
                  icon: const Icon(Icons.attach_file, size: 16),
                  label: const Text('Associate file'),
                ),
                OutlinedButton.icon(
                  onPressed: onAssociateFolder,
                  icon: const Icon(Icons.folder_copy_outlined, size: 16),
                  label: const Text('Associate folder'),
                ),
                OutlinedButton.icon(
                  onPressed: onInspectGit,
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                  label: const Text('Inspect git'),
                ),
                OutlinedButton.icon(
                  onPressed: onRefreshGithub,
                  icon: const Icon(Icons.cloud_sync_outlined, size: 16),
                  label: const Text('Refresh GitHub'),
                ),
                OutlinedButton.icon(
                  onPressed: onExportBundle,
                  icon: const Icon(Icons.archive_outlined, size: 16),
                  label: const Text('Export bundle'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _LocalRepoAssociatedFiles extends StatelessWidget {
  final ProjectLocalRepoSummary summary;

  const _LocalRepoAssociatedFiles({required this.summary});

  @override
  Widget build(BuildContext context) {
    final rows = <_AssociatedFileRow>[
      for (final item in summary.refreshItems)
        _AssociatedFileRow(
          icon: _sourceKindIcon(item.sourceKind),
          title: item.sourceKey,
          detail: '${_sourceKindLabel(item.sourceKind)} - ${item.targetType}',
        ),
      for (final doc in summary.documents)
        _AssociatedFileRow(
          icon: Icons.description_outlined,
          title: doc.originalFilename,
          detail: doc.source ?? 'Project document',
        ),
      for (final media in summary.media)
        _AssociatedFileRow(
          icon: _mediaIcon(media.mediaType),
          title: media.originalFilename,
          detail: media.source ?? media.mediaType,
        ),
    ];
    final distinct = <String, _AssociatedFileRow>{};
    for (final row in rows) {
      distinct.putIfAbsent('${row.detail}::${row.title}', () => row);
    }
    final visibleRows = distinct.values.take(8).toList(growable: false);
    final hiddenCount = distinct.length - visibleRows.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MiniPill('Documents', '${summary.documents.length}'),
            _MiniPill('Media', '${summary.media.length}'),
            _MiniPill('Source files', '${summary.sourceFileCount}'),
            _MiniPill('Cards', '${summary.cardCount}'),
          ],
        ),
        const SizedBox(height: 8),
        if (visibleRows.isEmpty)
          const Text(
            'No imported or refresh-tracked files yet.',
            style: TextStyle(fontSize: 13, color: Colors.white38),
          )
        else
          ...visibleRows.map(
            (row) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(row.icon, size: 15, color: Colors.white38),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          row.detail,
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
            ),
          ),
        if (hiddenCount > 0)
          Text(
            '+$hiddenCount more associated file(s)',
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
      ],
    );
  }

  IconData _sourceKindIcon(String sourceKind) {
    return switch (sourceKind) {
      'source_file' => Icons.code,
      'media' => Icons.image_outlined,
      'atlas_card' => Icons.style_outlined,
      'document' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  IconData _mediaIcon(String mediaType) {
    return switch (mediaType) {
      'image' => Icons.image_outlined,
      'video' => Icons.movie_outlined,
      'audio' => Icons.audiotrack_outlined,
      'folder' => Icons.folder_outlined,
      _ => Icons.attach_file,
    };
  }

  String _sourceKindLabel(String sourceKind) {
    return switch (sourceKind) {
      'source_file' => 'Source file',
      'atlas_card' => 'Atlas card',
      'project_meta' => 'Project metadata',
      'work_item' => 'Work item',
      _ => sourceKind.replaceAll('_', ' '),
    };
  }
}

class _AssociatedFileRow {
  final IconData icon;
  final String title;
  final String detail;

  const _AssociatedFileRow({
    required this.icon,
    required this.title,
    required this.detail,
  });
}

class _PeopleSection extends StatelessWidget {
  final List<ProjectPerson> people;
  final VoidCallback onAdd;
  final ValueChanged<ProjectPerson> onEdit;
  final ValueChanged<ProjectPerson> onDelete;

  const _PeopleSection({
    required this.people,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (people.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No people records yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...people.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.person_outline,
                  size: 16,
                  color: Colors.white38,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        [
                          if ((p.role ?? '').isNotEmpty) p.role!,
                          if ((p.authority ?? '').isNotEmpty) p.authority!,
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: Colors.white24,
                  ),
                  onPressed: () => onEdit(p),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0x80F44336),
                  ),
                  onPressed: () => onDelete(p),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.person_add_outlined, size: 16),
          label: const Text('Add person'),
        ),
      ],
    );
  }
}

class _RisksSection extends StatelessWidget {
  final List<ProjectRisk> risks;
  final VoidCallback onAdd;
  final ValueChanged<ProjectRisk> onDelete;

  const _RisksSection({
    required this.risks,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (risks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No risks recorded yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...risks.map(
          (r) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((r.desc ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            r.desc!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                              height: 1.4,
                            ),
                          ),
                        ),
                      Text(
                        'Severity: ${r.severity}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0x80F44336),
                  ),
                  onPressed: () => onDelete(r),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add risk'),
        ),
      ],
    );
  }
}

class _DecisionsSection extends StatelessWidget {
  final List<ProjectDecision> decisions;
  final VoidCallback onAdd;
  final ValueChanged<ProjectDecision> onDelete;

  const _DecisionsSection({
    required this.decisions,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (decisions.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No decisions recorded yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...decisions.map(
          (d) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((d.ctx ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            d.ctx!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                              height: 1.4,
                            ),
                          ),
                        ),
                      if ((d.decider ?? '').isNotEmpty)
                        Text(
                          'By: ${d.decider}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white38,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0x80F44336),
                  ),
                  onPressed: () => onDelete(d),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Log decision'),
        ),
      ],
    );
  }
}

class _ProjectWorkSection extends StatelessWidget {
  final String projectId;
  final List<WorkItem> items;
  final Future<void> Function() onChanged;
  final Future<void> Function() onAddProjectTask;

  const _ProjectWorkSection({
    required this.projectId,
    required this.items,
    required this.onChanged,
    required this.onAddProjectTask,
  });

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<WorkItem>>{
      for (final status in ['inbox', 'next', 'doing', 'waiting', 'done'])
        status: [],
    };
    for (final item in items) {
      final key = normalizeStatusValue(item.status);
      grouped.putIfAbsent(key, () => <WorkItem>[]).add(item);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Tasks here are scoped to this project. Click any task to open the full detail sheet.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ),
            FilledButton.icon(
              onPressed: onAddProjectTask,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add project task'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const Text(
            'No tasks in this project yet.',
            style: TextStyle(color: Colors.white24),
          )
        else
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.start,
            spacing: 12,
            runSpacing: 12,
            children: grouped.entries
                .where((entry) => entry.value.isNotEmpty)
                .map(
                  (entry) => _ProjectStatusColumn(
                    status: entry.key,
                    items: entry.value,
                    onChanged: onChanged,
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

class _ProjectStatusColumn extends StatelessWidget {
  final String status;
  final List<WorkItem> items;
  final Future<void> Function() onChanged;

  const _ProjectStatusColumn({
    required this.status,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final opt = statusFor(status);
    return SizedBox(
      width: 260,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(opt.icon, size: 14, color: opt.color),
                const SizedBox(width: 6),
                Text(
                  opt.label,
                  style: TextStyle(
                    color: opt.color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${items.length}',
                  style: const TextStyle(color: Colors.white38),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      normalizePriorityValue(item.priority),
                      if ((item.owner ?? '').isNotEmpty) item.owner!,
                      if (item.dueAt != null)
                        '${item.dueAt!.month}/${item.dueAt!.day}',
                    ].join(' - '),
                  ),
                  onTap: () async {
                    await showWorkItemDetailSheet(context, item.id);
                    await onChanged();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TagsSection extends StatelessWidget {
  final String projectId;
  final VoidCallback onEdit;

  const _TagsSection({required this.projectId, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<Tag>>(
      stream: state.watchTagsForProject(projectId),
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(
            'Error loading tags: ${snap.error}',
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          );
        }
        final tags = snap.data ?? const <Tag>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tags.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  'No tags assigned yet.',
                  style: TextStyle(fontSize: 13, color: Colors.white38),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in tags)
                      _Pill(label: '#${tag.name}', color: _tagColor(tag)),
                  ],
                ),
              ),
            OutlinedButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.sell_outlined, size: 16),
              label: const Text('Edit tags'),
            ),
          ],
        );
      },
    );
  }
}

class _MediaSection extends StatelessWidget {
  final String projectId;
  final VoidCallback onImportMedia;

  const _MediaSection({required this.projectId, required this.onImportMedia});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<ProjectMediaItem>>(
      stream: state.watchProjectMedia(projectId),
      builder: (context, mediaSnap) {
        final media = mediaSnap.data ?? const <ProjectMediaItem>[];
        final cover = media.where((item) => item.isCover).firstOrNull;
        return StreamBuilder<List<Document>>(
          stream: state.watchDocumentsForProject(projectId),
          builder: (context, docSnap) {
            final docs = docSnap.data ?? const <Document>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cover != null && cover.mediaType == 'image') ...[
                  _CoverImage(item: cover),
                  const SizedBox(height: 12),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onImportMedia,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 16,
                      ),
                      label: const Text('Add image/file'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          context.go(_libraryRouteForProject(projectId)),
                      icon: const Icon(Icons.library_books_outlined, size: 16),
                      label: const Text('Open Library'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (media.isEmpty && docs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'No media or documents linked to this project yet.',
                      style: TextStyle(fontSize: 13, color: Colors.white38),
                    ),
                  ),
                if (media.isNotEmpty) ...[
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 190,
                          mainAxisExtent: 190,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: media.length,
                    itemBuilder: (context, i) => _MediaTile(
                      item: media[i],
                      onSetCover: () =>
                          state.setProjectCoverMedia(projectId, media[i].id),
                      onDelete: () => state.deleteProjectMedia(media[i].id),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (docs.isNotEmpty)
                  ...docs.map(
                    (d) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: () => context.go(
                          _libraryRouteForProject(
                            projectId,
                            entryType: 'document',
                            entryId: d.id,
                          ),
                        ),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.description_outlined,
                                size: 16,
                                color: _kPrimary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      d.title,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      d.originalFilename,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right,
                                size: 16,
                                color: Colors.white24,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _CoverImage extends StatelessWidget {
  final ProjectMediaItem item;

  const _CoverImage({required this.item});

  @override
  Widget build(BuildContext context) {
    final file = File(item.storedPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 16 / 7,
        child: file.existsSync()
            ? Image.file(file, fit: BoxFit.cover)
            : Container(
                color: const Color(0xFF0F1115),
                alignment: Alignment.center,
                child: const Text(
                  'Cover file is missing',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  final ProjectMediaItem item;
  final VoidCallback onSetCover;
  final VoidCallback onDelete;

  const _MediaTile({
    required this.item,
    required this.onSetCover,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final file = File(item.storedPath);
    final isImage = item.mediaType == 'image';
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F1115),
        border: Border.all(color: item.isCover ? _kPrimary : _kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF10151E),
              child: isImage && file.existsSync()
                  ? Image.file(file, fit: BoxFit.cover)
                  : Icon(
                      isImage
                          ? Icons.broken_image_outlined
                          : item.mediaType == 'folder'
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                      color: Colors.white38,
                      size: 32,
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ((item.caption ?? '').isNotEmpty)
                  Text(
                    item.caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                Row(
                  children: [
                    if (!item.isCover)
                      IconButton(
                        tooltip: 'Use as cover',
                        onPressed: isImage ? onSetCover : null,
                        icon: const Icon(Icons.wallpaper, size: 16),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Remove media',
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 16),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosureSection extends StatelessWidget {
  final Project project;
  final VoidCallback onEdit, onComplete, onArchive;

  const _ClosureSection({
    required this.project,
    required this.onEdit,
    required this.onComplete,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldRow(
          label: 'Outcome summary',
          value: project.outcomeSummary,
          placeholder: 'Not closed yet',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Lessons learned',
          value: project.lessonsLearned,
          placeholder: 'Not recorded',
          onEdit: onEdit,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: onComplete,
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Complete project'),
            ),
            OutlinedButton.icon(
              onPressed: onArchive,
              icon: const Icon(Icons.archive_outlined, size: 16),
              label: const Text('Archive'),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Delete dialog ────────────────────────────────────────────────────────────

class _DeleteDialog extends StatefulWidget {
  final String projectTitle;
  final ValueChanged<String> onConfirm;
  final VoidCallback onClose;

  const _DeleteDialog({
    required this.projectTitle,
    required this.onConfirm,
    required this.onClose,
  });

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  final _ctrl = TextEditingController();
  bool _attempted = false;
  int _charCount = 0;

  bool get _valid => _charCount >= 20;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(
      () => setState(() => _charCount = _ctrl.text.trim().length),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _kLine),
      ),
      title: const Text(
        'Delete project permanently?',
        style: TextStyle(color: Color(0xFFF44336), fontSize: 16),
      ),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently remove "${widget.projectTitle}" from Project Atlas. '
              'Your deletion reason will be saved locally. Project documents are detached, not deleted.',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white70,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText:
                    'Deletion reason (min 20 characters — $_charCount/20)',
                hintText: 'Describe why this project is being deleted…',
              ),
            ),
            if (_attempted && !_valid) ...[
              const SizedBox(height: 6),
              const Text(
                'Please enter at least 20 characters before deleting.',
                style: TextStyle(fontSize: 12, color: Color(0xFFF44336)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: widget.onClose, child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            setState(() => _attempted = true);
            if (_valid) widget.onConfirm(_ctrl.text.trim());
          },
          style: FilledButton.styleFrom(
            backgroundColor: _valid
                ? const Color(0xFFF44336)
                : const Color(0x4DF44336),
            foregroundColor: _valid ? Colors.white : const Color(0x80FFFFFF),
          ),
          child: const Text('Delete permanently'),
        ),
      ],
    );
  }
}
