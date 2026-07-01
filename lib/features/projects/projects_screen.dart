import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';

import '../../db/app_db.dart';
import '../../services/local_operations_scanner.dart';
import '../../services/local_project_refresh_service.dart';
import '../../shared/models/app_state.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/models/project_metadata.dart';
import '../../shared/widgets/create_project_dialog.dart';
import 'project_metadata_dialog.dart';
import '../work/status_priority_helpers.dart';

const _kPanel = Color(0xFF151A22);
const _kLine = Color(0xFF273044);
const _kPrimary = Color(0xFF79A7FF);
const _projectsTabCategorySortKey = 'projects_tab::category_sort';
const _projectsTabProjectSortKey = 'projects_tab::project_sort';
const _projectsTabPinnedCategoriesKey = 'projects_tab::pinned_categories';
const _projectsTabPinnedProjectsKey = 'projects_tab::pinned_projects';
const _defaultCategorySort = 'name_az';
const _defaultProjectSort = 'name_az';

const _kPhaseColors = <String, Color>{
  'idea': Color(0xFF9C27B0),
  'design': Color(0xFF2196F3),
  'build': Color(0xFFFFC107),
  'test': Color(0xFFFF9800),
  'ship': Color(0xFF4CAF50),
  'stabilize': Color(0xFF607D8B),
};
const _kPriorityColors = <String, Color>{
  'low': Color(0xFF607D8B),
  'normal': Color(0x8AFFFFFF),
  'high': Color(0xFFFF9800),
  'urgent': Color(0xFFF44336),
};

Color _phaseColor(String? p) => _kPhaseColors[p] ?? const Color(0x61FFFFFF);
Color _priorityColor(String? p) =>
    _kPriorityColors[normalizePriorityValue(p)] ?? const Color(0x61FFFFFF);

class _SortOption {
  final String value;
  final String label;

  const _SortOption({required this.value, required this.label});
}

const _categorySortOptions = <_SortOption>[
  _SortOption(value: 'name_az', label: 'Categories: A-Z'),
  _SortOption(value: 'name_za', label: 'Categories: Z-A'),
  _SortOption(value: 'recent_update', label: 'Categories: Recent'),
  _SortOption(value: 'project_count_desc', label: 'Categories: Most projects'),
  _SortOption(value: 'newest_project', label: 'Categories: Newest'),
  _SortOption(value: 'oldest_project', label: 'Categories: Oldest'),
];

const _projectSortOptions = <_SortOption>[
  _SortOption(value: 'name_az', label: 'Projects: A-Z'),
  _SortOption(value: 'name_za', label: 'Projects: Z-A'),
  _SortOption(value: 'recent_update', label: 'Projects: Recent'),
  _SortOption(value: 'newest', label: 'Projects: Newest'),
  _SortOption(value: 'oldest', label: 'Projects: Oldest'),
  _SortOption(value: 'priority', label: 'Projects: Priority'),
  _SortOption(value: 'attention', label: 'Projects: Attention'),
  _SortOption(value: 'owner_az', label: 'Projects: Owner'),
];

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  String? _tagFilterId;
  String? _statusFilter;
  String? _phaseFilter;
  String? _priorityFilter;
  bool _refreshingSummaries = false;
  bool _uploadingProject = false;
  String? _projectUploadProgress;
  String _categorySort = _defaultCategorySort;
  String _projectSort = _defaultProjectSort;
  final Set<String> _collapsedCategories = <String>{};
  final Set<String> _pinnedCategories = <String>{};
  final Set<String> _pinnedProjects = <String>{};
  bool _loadedOrderingPreferences = false;

  bool get _hasFilters =>
      _tagFilterId != null ||
      _statusFilter != null ||
      _phaseFilter != null ||
      _priorityFilter != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedOrderingPreferences) return;
    _loadedOrderingPreferences = true;
    unawaited(_loadOrderingPreferences());
  }

  Future<void> _loadOrderingPreferences() async {
    final state = AppStateScope.of(context);
    final values = await Future.wait<String?>([
      state.getSetting(_projectsTabCategorySortKey),
      state.getSetting(_projectsTabProjectSortKey),
      state.getSetting(_projectsTabPinnedCategoriesKey),
      state.getSetting(_projectsTabPinnedProjectsKey),
    ]);
    if (!mounted) return;
    setState(() {
      _categorySort = _normalizeSortSetting(
        values[0],
        _categorySortOptions,
        _defaultCategorySort,
      );
      _projectSort = _normalizeSortSetting(
        values[1],
        _projectSortOptions,
        _defaultProjectSort,
      );
      _pinnedCategories
        ..clear()
        ..addAll(_decodeStringSetSetting(values[2]));
      _pinnedProjects
        ..clear()
        ..addAll(_decodeStringSetSetting(values[3]));
    });
  }

  Future<void> _setCategorySort(String? value) async {
    if (value == null) return;
    final normalized = _normalizeSortSetting(
      value,
      _categorySortOptions,
      _defaultCategorySort,
    );
    if (_categorySort == normalized) return;
    setState(() => _categorySort = normalized);
    await AppStateScope.of(
      context,
    ).setSetting(_projectsTabCategorySortKey, normalized);
  }

  Future<void> _setProjectSort(String? value) async {
    if (value == null) return;
    final normalized = _normalizeSortSetting(
      value,
      _projectSortOptions,
      _defaultProjectSort,
    );
    if (_projectSort == normalized) return;
    setState(() => _projectSort = normalized);
    await AppStateScope.of(
      context,
    ).setSetting(_projectsTabProjectSortKey, normalized);
  }

  Future<void> _toggleCategoryPin(String category) async {
    setState(() {
      if (!_pinnedCategories.add(category)) {
        _pinnedCategories.remove(category);
      }
    });
    await _saveStringSetSetting(
      _projectsTabPinnedCategoriesKey,
      _pinnedCategories,
    );
  }

  Future<void> _toggleProjectPin(String projectId) async {
    setState(() {
      if (!_pinnedProjects.add(projectId)) {
        _pinnedProjects.remove(projectId);
      }
    });
    await _saveStringSetSetting(_projectsTabPinnedProjectsKey, _pinnedProjects);
  }

  Future<void> _saveStringSetSetting(String key, Set<String> values) async {
    final sorted = values.toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await AppStateScope.of(
      context,
    ).setSetting(key, sorted.isEmpty ? null : jsonEncode(sorted));
  }

  Future<void> _exportProjectBundle(Project project) async {
    final state = AppStateScope.of(context);
    try {
      final preview = await state.previewProjectBundleExport(project.id);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Export project bundle'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Pill(
                      label: '${preview.atlasRecordCount} Atlas records',
                      color: _kPrimary,
                    ),
                    _Pill(
                      label: '${preview.copiedFileCount} copied files',
                      color: Colors.green,
                    ),
                    _Pill(
                      label: '${preview.documents} documents',
                      color: Colors.cyan,
                    ),
                    _Pill(
                      label: '${preview.workItems} work items',
                      color: Colors.amber,
                    ),
                    _Pill(
                      label: '${preview.decisions} decisions',
                      color: Colors.purpleAccent,
                    ),
                  ],
                ),
                if (preview.warnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ...preview.warnings
                      .take(4)
                      .map(
                        (warning) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            warning,
                            style: const TextStyle(
                              color: Colors.orangeAccent,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(ctx).pop(true),
              icon: const Icon(Icons.archive_outlined, size: 16),
              label: const Text('Choose ZIP path'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final safeTitle = project.title
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export project bundle',
        fileName: '${safeTitle}_project_bundle.zip',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (path == null || path.trim().isEmpty) return;
      final outputPath = path.toLowerCase().endsWith('.zip')
          ? path
          : '$path.zip';
      await state.exportProjectBundleToZip(project.id, outputPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Project bundle exported: $outputPath')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
    }
  }

  Future<void> _refreshAiSummaries() async {
    if (_refreshingSummaries) return;
    final state = AppStateScope.of(context);
    setState(() => _refreshingSummaries = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('AI summary refresh started.')),
    );
    try {
      final result = await state.refreshMissingProjectSummaries(
        force: true,
        betweenProjects: Duration.zero,
      );
      if (!mounted) return;
      final message = _summaryRefreshMessage(result);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('AI refresh failed: $error')));
    } finally {
      if (mounted) setState(() => _refreshingSummaries = false);
    }
  }

  String _summaryRefreshMessage(ProjectSummaryRefreshResult result) {
    if (result.alreadyRunning) {
      return 'AI summary refresh is already running.';
    }
    if (result.aiUnavailable) {
      return 'AI summary refresh skipped: Ollama is unavailable.';
    }
    if (result.considered == 0) {
      return 'AI summary refresh found no open or review-ready projects.';
    }
    final skipped = result.skipped == 0 ? '' : ', ${result.skipped} skipped';
    return 'AI summaries: ${result.refreshed} refreshed$skipped, ${result.failed} failed across ${result.considered} projects.';
  }

  Future<void> _uploadOrUpdateProject() async {
    if (_uploadingProject) return;
    final state = AppStateScope.of(context);
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Upload or update a Project Atlas project',
    );
    if (path == null || path.trim().isEmpty) return;
    final rootPath = path.trim();
    if (isUnsafeOperationsScanRoot(rootPath)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose a project folder, not a drive root.'),
        ),
      );
      return;
    }

    setState(() => _uploadingProject = true);
    try {
      _setProjectUploadProgress('Scanning selected project folder...');
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [rootPath], maxDepth: 0),
      );
      _setProjectUploadProgress('Reading detected project markers...');
      final observations = await state.db.getProjectObservationsForScanRun(
        runId,
      );
      if (!mounted) return;
      if (observations.isEmpty) {
        _setProjectUploadProgress(null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No project markers found in that folder.'),
          ),
        );
        return;
      }
      final observation = _chooseProjectUploadObservation(
        rootPath,
        observations,
      );
      _setProjectUploadProgress('Matching local project to Atlas...');
      final registry = await state.db.getProjectRegistryByPath(
        observation.observedPath,
      );
      final projects = await state.getProjectsFull();
      if (!mounted) return;
      _setProjectUploadProgress(null);
      final choice = await showDialog<_ProjectUploadChoice>(
        context: context,
        builder: (_) => _ProjectUploadDialog(
          observation: observation,
          registry: registry,
          projects: projects,
        ),
      );
      if (choice == null || !mounted) return;
      switch (choice.mode) {
        case _ProjectUploadMode.openLinked:
          final linkedId = registry?.atlasProjectId;
          if (linkedId != null && linkedId.isNotEmpty) {
            context.go('/projects/$linkedId');
          }
          return;
        case _ProjectUploadMode.refreshLinked:
          final linkedId = registry?.atlasProjectId;
          if (registry == null || linkedId == null || linkedId.isEmpty) {
            throw StateError('Project is not linked yet.');
          }
          final result = await _previewAndApplyProjectUploadRefresh(
            state,
            registryId: registry.id,
            projectId: linkedId,
          );
          if (result == null || !mounted) return;
          _queueProjectSummaryRefresh(state, linkedId);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Project refreshed: ${result.created} created, ${result.updated} updated, ${result.unchanged} unchanged.',
              ),
            ),
          );
          context.go('/projects/$linkedId');
          return;
        case _ProjectUploadMode.createNew:
          _setProjectUploadProgress('Creating Atlas project shell...');
          final registryId = await _ensureRegistryForUpload(
            state,
            observation,
            registry,
          );
          final projectId = await state.importProjectRegistryEntryAsProject(
            registryId,
            refresh: false,
          );
          final result = await _previewAndApplyProjectUploadRefresh(
            state,
            registryId: registryId,
            projectId: projectId,
          );
          if (result == null) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Project created; local refresh was canceled.'),
              ),
            );
          } else {
            _queueProjectSummaryRefresh(state, projectId);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_projectRefreshResultMessage(result))),
            );
          }
          if (!mounted) return;
          context.go('/projects/$projectId');
          return;
        case _ProjectUploadMode.updateExisting:
          final projectId = choice.projectId;
          if (projectId == null || projectId.isEmpty) return;
          _setProjectUploadProgress('Linking selected Atlas project...');
          final registryId = await _ensureRegistryForUpload(
            state,
            observation,
            registry,
            atlasProjectId: projectId,
          );
          final updatedProjectId = await state
              .updateExistingProjectFromRegistryEntry(
                registryId,
                projectId,
                refresh: false,
              );
          final result = await _previewAndApplyProjectUploadRefresh(
            state,
            registryId: registryId,
            projectId: updatedProjectId,
          );
          if (result == null) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Project linked; local refresh was canceled.'),
              ),
            );
          } else {
            _queueProjectSummaryRefresh(state, updatedProjectId);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_projectRefreshResultMessage(result))),
            );
          }
          if (!mounted) return;
          context.go('/projects/$updatedProjectId');
          return;
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Project upload failed: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _uploadingProject = false;
          _projectUploadProgress = null;
        });
      }
    }
  }

  void _setProjectUploadProgress(String? message) {
    if (!mounted) return;
    setState(() => _projectUploadProgress = message);
  }

  Future<LocalProjectRefreshApplyResult?> _previewAndApplyProjectUploadRefresh(
    AppState state, {
    required String registryId,
    required String projectId,
  }) async {
    _setProjectUploadProgress('Preparing local project refresh preview...');
    final preview = await state.previewLocalProjectRefreshForRegistryEntry(
      registryId,
      projectId,
    );
    if (!mounted) return null;
    _setProjectUploadProgress(null);
    final selectedActionIds = await _showProjectUploadRefreshDialog(preview);
    if (selectedActionIds == null) return null;
    if (selectedActionIds.isEmpty) {
      return LocalProjectRefreshApplyResult(
        created: 0,
        updated: 0,
        unchanged: preview.entries
            .where((entry) => entry.status == 'unchanged')
            .length,
        skipped: preview.entries
            .where((entry) => entry.status != 'unchanged')
            .length,
        warnings: preview.warnings,
      );
    }
    _setProjectUploadProgress('Applying selected local project updates...');
    final result = await state.applyLocalProjectRefreshForRegistryEntry(
      registryId,
      projectId,
      selectedActionIds: selectedActionIds,
    );
    _setProjectUploadProgress(null);
    return result;
  }

  Future<Set<String>?> _showProjectUploadRefreshDialog(
    LocalProjectRefreshPreview preview,
  ) async {
    final selected = preview.entries
        .where((entry) => entry.shouldApplyByDefault)
        .map((entry) => entry.action.id)
        .toSet();
    if (!mounted) return null;
    return showDialog<Set<String>>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final newCount = preview.entries
              .where((entry) => entry.status == 'new')
              .length;
          final changedCount = preview.entries
              .where((entry) => entry.status == 'changed')
              .length;
          final unchangedCount = preview.entries
              .where((entry) => entry.status == 'unchanged')
              .length;
          return AlertDialog(
            backgroundColor: _kPanel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: _kLine),
            ),
            title: const Text('Preview project update'),
            content: SizedBox(
              width: 760,
              height: 560,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    preview.localPath,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _MiniPill('Profile', preview.profile),
                      _MiniPill('New', '$newCount'),
                      _MiniPill('Changed', '$changedCount'),
                      _MiniPill('Unchanged', '$unchangedCount'),
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
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0x22FF9800),
                        border: Border.all(color: const Color(0x55FF9800)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        preview.warnings.take(6).join('\n'),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.amber,
                        ),
                      ),
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
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).maybePop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).maybePop(<String>{}),
                child: const Text('Skip refresh'),
              ),
              FilledButton.icon(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.of(
                        ctx,
                        rootNavigator: true,
                      ).maybePop(Set<String>.from(selected)),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Apply selected'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _queueProjectSummaryRefresh(AppState state, String projectId) {
    unawaited(
      (() async {
        try {
          await state.summarizeProjectFull(projectId, includeLibrary: true);
        } catch (error) {
          try {
            await state.db.logEvent(
              level: 'warn',
              area: 'ai',
              action: 'upload_project_summary_refresh_failed',
              entityType: 'project',
              entityId: projectId,
              error: error.toString(),
            );
          } catch (_) {}
        }
      })(),
    );
  }

  String _projectRefreshResultMessage(LocalProjectRefreshApplyResult result) {
    final warnings = result.warnings.isEmpty
        ? ''
        : ', ${result.warnings.length} warnings';
    return 'Project updated: ${result.created} created, ${result.updated} updated, ${result.unchanged} unchanged, ${result.skipped} skipped$warnings.';
  }

  ProjectObservation _chooseProjectUploadObservation(
    String rootPath,
    List<ProjectObservation> observations,
  ) {
    final normalizedRoot = _pathKey(rootPath);
    return observations.firstWhere(
      (observation) => _pathKey(observation.observedPath) == normalizedRoot,
      orElse: () => observations.first,
    );
  }

  Future<String> _ensureRegistryForUpload(
    AppState state,
    ProjectObservation observation,
    ProjectRegistryEntry? existing, {
    String? atlasProjectId,
  }) async {
    if (existing != null) {
      return existing.id;
    }
    if (atlasProjectId == null || atlasProjectId.isEmpty) {
      await state.acceptProjectObservation(observation.id);
    } else {
      await state.linkProjectObservation(observation.id, atlasProjectId);
    }
    final registry = await state.db.getProjectRegistryByPath(
      observation.observedPath,
    );
    if (registry == null) {
      throw StateError('Project registry row was not created.');
    }
    return registry.id;
  }

  Future<void> _mergeProject(Project source, List<Project> projects) async {
    final state = AppStateScope.of(context);
    final candidates = projects
        .where((project) => project.id != source.id)
        .toList(growable: false);
    if (candidates.isEmpty) return;
    String targetId = candidates.first.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Merge project'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Source: ${source.title}'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: targetId,
                  decoration: const InputDecoration(
                    labelText: 'Merge into',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final project in candidates)
                      DropdownMenuItem(
                        value: project.id,
                        child: Text(
                          project.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setLocal(() => targetId = value);
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  'Stages, work, documents, media, governance records, tags, drafts, and local registry links move to the target project. The source project is archived as deleted.',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(ctx).pop(true),
              icon: const Icon(Icons.call_merge, size: 16),
              label: const Text('Merge'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      final result = await state.mergeProjects(
        sourceProjectId: source.id,
        targetProjectId: targetId,
      );
      if (!mounted) return;
      final moved = result.values.fold<int>(0, (sum, count) => sum + count);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Merged ${source.title}: $moved records moved.'),
        ),
      );
      context.go('/projects/$targetId');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Merge failed: $error')));
    }
  }

  Future<void> _editProjectMetadata(Project project) async {
    await showProjectMetadataDialog(context, project);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final summaryRefreshBusy =
        _refreshingSummaries || state.isProjectSummaryRefreshRunning;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          IconButton(
            tooltip: summaryRefreshBusy
                ? 'AI summaries are refreshing'
                : 'Refresh AI summaries',
            onPressed: summaryRefreshBusy ? null : _refreshAiSummaries,
            icon: summaryRefreshBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_outlined),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _uploadingProject ? null : _uploadOrUpdateProject,
            icon: _uploadingProject
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file_outlined),
            label: const Text('Upload project'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () async {
              final title = await showCreateProjectDialog(context);
              if (title == null || title.trim().isEmpty) return;
              await state.createProject(title.trim());
              final active = state.activeProject;
              if (context.mounted && active != null) {
                context.go('/projects/${active.id}');
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('New project'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Stack(
        children: [
          StreamBuilder<List<Project>>(
            stream: state.watchProjects(),
            builder: (context, projectSnap) {
              if (projectSnap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (projectSnap.hasError) {
                return _ProjectsLoadError(error: projectSnap.error);
              }
              final projects = projectSnap.data ?? const <Project>[];
              return StreamBuilder<List<Tag>>(
                stream: state.watchTags(),
                builder: (context, tagSnap) {
                  if (tagSnap.hasError) {
                    return _ProjectsLoadError(error: tagSnap.error);
                  }
                  final tags = tagSnap.data ?? const <Tag>[];
                  return FutureBuilder<Map<String, List<Tag>>>(
                    future: _loadTagsForProjects(state, projects),
                    builder: (context, projectTagSnap) {
                      if (projectTagSnap.hasError) {
                        return _ProjectsLoadError(error: projectTagSnap.error);
                      }
                      final projectTags =
                          projectTagSnap.data ?? const <String, List<Tag>>{};
                      final filtered = _filterProjects(projects, projectTags);
                      return StreamBuilder<
                        Map<String, ProjectUpdateAttribution>
                      >(
                        stream: state.watchProjectUpdateAttributions(),
                        builder: (context, projectUpdateSnap) {
                          if (projectUpdateSnap.hasError) {
                            return _ProjectsLoadError(
                              error: projectUpdateSnap.error,
                            );
                          }
                          final projectUpdates =
                              projectUpdateSnap.data ??
                              const <String, ProjectUpdateAttribution>{};
                          return Column(
                            children: [
                              _FilterBar(
                                tags: tags,
                                tagFilterId: _tagFilterId,
                                statusFilter: _statusFilter,
                                phaseFilter: _phaseFilter,
                                priorityFilter: _priorityFilter,
                                categorySort: _categorySort,
                                projectSort: _projectSort,
                                hasFilters: _hasFilters,
                                onTagChanged: (v) =>
                                    setState(() => _tagFilterId = v),
                                onStatusChanged: (v) =>
                                    setState(() => _statusFilter = v),
                                onPhaseChanged: (v) =>
                                    setState(() => _phaseFilter = v),
                                onPriorityChanged: (v) =>
                                    setState(() => _priorityFilter = v),
                                onCategorySortChanged: _setCategorySort,
                                onProjectSortChanged: _setProjectSort,
                                onClear: () => setState(() {
                                  _tagFilterId = null;
                                  _statusFilter = null;
                                  _phaseFilter = null;
                                  _priorityFilter = null;
                                }),
                                totalCount: projects.length,
                                filteredCount: filtered.length,
                              ),
                              const Divider(height: 1, color: _kLine),
                              Expanded(
                                child: projects.isEmpty
                                    ? const _EmptyProjects()
                                    : filtered.isEmpty
                                    ? const Center(
                                        child: Text(
                                          'No projects match the current filters.',
                                          style: TextStyle(
                                            color: Colors.white54,
                                          ),
                                        ),
                                      )
                                    : StreamBuilder<Project?>(
                                        stream: state.watchActiveProject(),
                                        builder: (context, activeSnap) {
                                          if (activeSnap.hasError) {
                                            return _ProjectsLoadError(
                                              error: activeSnap.error,
                                            );
                                          }
                                          final activeId = activeSnap.data?.id;
                                          final grouped = _groupProjects(
                                            filtered,
                                            projectUpdates,
                                          );
                                          return ListView.builder(
                                            padding: const EdgeInsets.all(16),
                                            itemCount: grouped.length,
                                            itemBuilder: (context, i) {
                                              final group = grouped[i];
                                              final collapsed =
                                                  _collapsedCategories.contains(
                                                    group.title,
                                                  );
                                              return _ProjectCategorySection(
                                                title: group.title,
                                                count: group.projects.length,
                                                collapsed: collapsed,
                                                pinned: _pinnedCategories
                                                    .contains(group.title),
                                                onTogglePin: () =>
                                                    _toggleCategoryPin(
                                                      group.title,
                                                    ),
                                                onToggle: () => setState(() {
                                                  if (collapsed) {
                                                    _collapsedCategories.remove(
                                                      group.title,
                                                    );
                                                  } else {
                                                    _collapsedCategories.add(
                                                      group.title,
                                                    );
                                                  }
                                                }),
                                                children: [
                                                  for (final p
                                                      in group.projects)
                                                    _ProjectTile(
                                                      project: p,
                                                      tags:
                                                          projectTags[p.id] ??
                                                          const <Tag>[],
                                                      updateAttribution:
                                                          projectUpdates[p.id],
                                                      isSelected:
                                                          p.id == activeId,
                                                      isPinned: _pinnedProjects
                                                          .contains(p.id),
                                                      onTogglePin: () =>
                                                          _toggleProjectPin(
                                                            p.id,
                                                          ),
                                                      onExport: () =>
                                                          _exportProjectBundle(
                                                            p,
                                                          ),
                                                      onMerge: () =>
                                                          _mergeProject(
                                                            p,
                                                            projects,
                                                          ),
                                                      onEditMeta: () =>
                                                          _editProjectMetadata(
                                                            p,
                                                          ),
                                                      onTap: () async {
                                                        await state
                                                            .setActiveById(
                                                              p.id,
                                                            );
                                                        if (context.mounted) {
                                                          context.go(
                                                            '/projects/${p.id}',
                                                          );
                                                        }
                                                      },
                                                    ),
                                                ],
                                              );
                                            },
                                          );
                                        },
                                      ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
          if (_projectUploadProgress != null)
            Positioned.fill(
              child: _ProjectUploadProgressOverlay(
                message: _projectUploadProgress!,
              ),
            ),
        ],
      ),
    );
  }

  Future<Map<String, List<Tag>>> _loadTagsForProjects(
    AppState state,
    List<Project> projects,
  ) async {
    final entries = await Future.wait(
      projects.map(
        (p) async => MapEntry(p.id, await state.getTagsForProject(p.id)),
      ),
    );
    return Map.fromEntries(entries);
  }

  List<Project> _filterProjects(
    List<Project> projects,
    Map<String, List<Tag>> projectTags,
  ) {
    return projects
        .where((p) {
          if (_tagFilterId != null &&
              !(projectTags[p.id] ?? const <Tag>[]).any(
                (tag) => tag.id == _tagFilterId,
              )) {
            return false;
          }
          if (_statusFilter != null &&
              normalizeProjectStatusValue(p.status) != _statusFilter) {
            return false;
          }
          if (_phaseFilter != null && p.phase != _phaseFilter) return false;
          if (_priorityFilter != null &&
              normalizePriorityValue(p.priority) != _priorityFilter) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  List<_ProjectCategoryGroup> _groupProjects(
    List<Project> projects,
    Map<String, ProjectUpdateAttribution> projectUpdates,
  ) {
    final grouped = <String, List<Project>>{};
    for (final project in projects) {
      final category = projectCategoryLabel(project.category);
      grouped.putIfAbsent(category, () => <Project>[]).add(project);
    }
    final groups =
        grouped.entries
            .map(
              (entry) => _ProjectCategoryGroup(
                title: entry.key,
                projects: entry.value
                  ..sort((a, b) => _compareProjects(a, b, projectUpdates)),
              ),
            )
            .toList(growable: false)
          ..sort((a, b) => _compareCategoryGroups(a, b, projectUpdates));
    return groups;
  }

  int _compareCategoryGroups(
    _ProjectCategoryGroup a,
    _ProjectCategoryGroup b,
    Map<String, ProjectUpdateAttribution> projectUpdates,
  ) {
    final pinned = _comparePinned(
      _pinnedCategories.contains(a.title),
      _pinnedCategories.contains(b.title),
    );
    if (pinned != 0) return pinned;

    final uncategorized = _compareUncategorized(a.title, b.title);
    if (uncategorized != 0) return uncategorized;

    final bySort = switch (_categorySort) {
      'name_za' => _compareTextDesc(a.title, b.title),
      'recent_update' => _compareDateDesc(
        _categoryRecentDate(a, projectUpdates),
        _categoryRecentDate(b, projectUpdates),
      ),
      'project_count_desc' => b.projects.length.compareTo(a.projects.length),
      'newest_project' => _compareDateDesc(
        _categoryNewestProjectDate(a),
        _categoryNewestProjectDate(b),
      ),
      'oldest_project' => _categoryOldestProjectDate(
        a,
      ).compareTo(_categoryOldestProjectDate(b)),
      _ => _compareText(a.title, b.title),
    };
    return bySort == 0 ? _compareText(a.title, b.title) : bySort;
  }

  int _compareProjects(
    Project a,
    Project b,
    Map<String, ProjectUpdateAttribution> projectUpdates,
  ) {
    final pinned = _comparePinned(
      _pinnedProjects.contains(a.id),
      _pinnedProjects.contains(b.id),
    );
    if (pinned != 0) return pinned;

    final bySort = switch (_projectSort) {
      'name_za' => _compareTextDesc(a.title, b.title),
      'recent_update' => _compareDateDesc(
        _projectRecentDate(a, projectUpdates),
        _projectRecentDate(b, projectUpdates),
      ),
      'newest' => _compareDateDesc(a.createdAt, b.createdAt),
      'oldest' => a.createdAt.compareTo(b.createdAt),
      'priority' => _priorityRank(a).compareTo(_priorityRank(b)),
      'attention' => _compareAttentionProjects(a, b, projectUpdates),
      'owner_az' => _compareOptionalText(a.owner, b.owner),
      _ => _compareText(a.title, b.title),
    };
    return bySort == 0 ? _compareText(a.title, b.title) : bySort;
  }

  int _compareAttentionProjects(
    Project a,
    Project b,
    Map<String, ProjectUpdateAttribution> projectUpdates,
  ) {
    final byAttention = _attentionRank(a).compareTo(_attentionRank(b));
    if (byAttention != 0) return byAttention;
    return _compareDateDesc(
      _projectRecentDate(a, projectUpdates),
      _projectRecentDate(b, projectUpdates),
    );
  }

  DateTime _projectRecentDate(
    Project project,
    Map<String, ProjectUpdateAttribution> projectUpdates,
  ) => projectUpdates[project.id]?.updatedAt ?? project.createdAt;

  DateTime _categoryRecentDate(
    _ProjectCategoryGroup group,
    Map<String, ProjectUpdateAttribution> projectUpdates,
  ) {
    var latest = _projectRecentDate(group.projects.first, projectUpdates);
    for (final project in group.projects.skip(1)) {
      final candidate = _projectRecentDate(project, projectUpdates);
      if (candidate.isAfter(latest)) latest = candidate;
    }
    return latest;
  }

  DateTime _categoryNewestProjectDate(_ProjectCategoryGroup group) {
    var newest = group.projects.first.createdAt;
    for (final project in group.projects.skip(1)) {
      if (project.createdAt.isAfter(newest)) newest = project.createdAt;
    }
    return newest;
  }

  DateTime _categoryOldestProjectDate(_ProjectCategoryGroup group) {
    var oldest = group.projects.first.createdAt;
    for (final project in group.projects.skip(1)) {
      if (project.createdAt.isBefore(oldest)) oldest = project.createdAt;
    }
    return oldest;
  }

  int _priorityRank(Project project) {
    return switch (normalizePriorityValue(project.priority)) {
      'urgent' => 0,
      'high' => 1,
      'normal' => 2,
      'low' => 3,
      _ => 2,
    };
  }

  int _attentionRank(Project project) {
    return isAttentionProjectStatus(project.status) ? 0 : 1;
  }
}

class _ProjectCategoryGroup {
  final String title;
  final List<Project> projects;

  const _ProjectCategoryGroup({required this.title, required this.projects});
}

String _normalizeSortSetting(
  String? value,
  List<_SortOption> options,
  String fallback,
) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return fallback;
  return options.any((option) => option.value == raw) ? raw : fallback;
}

Set<String> _decodeStringSetSetting(String? value) {
  if (value == null || value.trim().isEmpty) return <String>{};
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return <String>{};
    final result = <String>{};
    for (final item in decoded) {
      if (item is! String) continue;
      final trimmed = item.trim();
      if (trimmed.isNotEmpty) result.add(trimmed);
    }
    return result;
  } catch (_) {
    return <String>{};
  }
}

int _comparePinned(bool a, bool b) {
  if (a == b) return 0;
  return a ? -1 : 1;
}

int _compareUncategorized(String a, String b) {
  final aUncategorized = a == uncategorizedProjectCategory;
  final bUncategorized = b == uncategorizedProjectCategory;
  if (aUncategorized == bUncategorized) return 0;
  return aUncategorized ? 1 : -1;
}

int _compareText(String a, String b) {
  return a.trim().toLowerCase().compareTo(b.trim().toLowerCase());
}

int _compareTextDesc(String a, String b) => _compareText(b, a);

int _compareOptionalText(String? a, String? b) {
  final left = a?.trim() ?? '';
  final right = b?.trim() ?? '';
  if (left.isEmpty && right.isNotEmpty) return 1;
  if (right.isEmpty && left.isNotEmpty) return -1;
  return _compareText(left, right);
}

int _compareDateDesc(DateTime a, DateTime b) => b.compareTo(a);

enum _ProjectUploadMode { createNew, updateExisting, refreshLinked, openLinked }

class _ProjectUploadChoice {
  final _ProjectUploadMode mode;
  final String? projectId;

  const _ProjectUploadChoice(this.mode, {this.projectId});
}

class _ProjectUploadDialog extends StatefulWidget {
  final ProjectObservation observation;
  final ProjectRegistryEntry? registry;
  final List<ProjectFull> projects;

  const _ProjectUploadDialog({
    required this.observation,
    required this.registry,
    required this.projects,
  });

  @override
  State<_ProjectUploadDialog> createState() => _ProjectUploadDialogState();
}

class _ProjectUploadDialogState extends State<_ProjectUploadDialog> {
  late String? _selectedProjectId = widget.projects.isEmpty
      ? null
      : widget.projects.first.id;

  @override
  Widget build(BuildContext context) {
    final registry = widget.registry;
    final linkedProjectId = registry?.atlasProjectId;
    final isLinked = linkedProjectId != null && linkedProjectId.isNotEmpty;
    final markers = _decodeStringList(widget.observation.markerFilesJson);
    final warnings = _decodeStringList(widget.observation.warningsJson);
    final displayName = _observationDisplayName(widget.observation);

    return AlertDialog(
      title: const Text('Upload / update project'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayName,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              SelectableText(
                widget.observation.observedPath,
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Pill(
                    label: widget.observation.classificationGuess,
                    color: _kPrimary,
                  ),
                  _Pill(
                    label: '${widget.observation.confidence}% confidence',
                    color: Colors.cyan,
                  ),
                  _Pill(
                    label: registry == null
                        ? 'new local project'
                        : registry.reviewState,
                    color: isLinked ? Colors.green : Colors.amber,
                  ),
                  if ((registry?.gitRoot ?? '').isNotEmpty)
                    const _Pill(label: 'local git', color: Colors.lightGreen)
                  else
                    const _Pill(label: 'local only', color: Colors.white54),
                  if ((widget.observation.branch ?? '').isNotEmpty)
                    _Pill(
                      label: 'branch ${widget.observation.branch}',
                      color: Colors.blueAccent,
                    ),
                  if ((widget.observation.dirtyCount ?? 0) > 0)
                    _Pill(
                      label: '${widget.observation.dirtyCount} dirty',
                      color: Colors.orange,
                    ),
                ],
              ),
              if (markers.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Detected markers',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final marker in markers)
                      _Pill(label: marker, color: Colors.white70),
                  ],
                ),
              ],
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x22FF9800),
                    border: Border.all(color: const Color(0x55FF9800)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    warnings.take(4).join('\n'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ),
              ],
              if (!isLinked) ...[
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  value: _selectedProjectId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Update existing Atlas project',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final project in widget.projects)
                      DropdownMenuItem(
                        value: project.id,
                        child: Text(
                          project.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: widget.projects.isEmpty
                      ? null
                      : (value) => setState(() => _selectedProjectId = value),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (isLinked) ...[
          TextButton.icon(
            onPressed: () => Navigator.of(
              context,
            ).pop(const _ProjectUploadChoice(_ProjectUploadMode.openLinked)),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(
              context,
            ).pop(const _ProjectUploadChoice(_ProjectUploadMode.refreshLinked)),
            icon: const Icon(Icons.sync, size: 16),
            label: const Text('Refresh'),
          ),
        ] else ...[
          TextButton.icon(
            onPressed: () => Navigator.of(
              context,
            ).pop(const _ProjectUploadChoice(_ProjectUploadMode.createNew)),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Create new'),
          ),
          FilledButton.icon(
            onPressed: _selectedProjectId == null
                ? null
                : () => Navigator.of(context).pop(
                    _ProjectUploadChoice(
                      _ProjectUploadMode.updateExisting,
                      projectId: _selectedProjectId,
                    ),
                  ),
            icon: const Icon(Icons.link, size: 16),
            label: const Text('Update selected'),
          ),
        ],
      ],
    );
  }
}

class _ProjectUploadProgressOverlay extends StatelessWidget {
  final String message;

  const _ProjectUploadProgressOverlay({required this.message});

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: Container(
        color: Colors.black.withAlpha(150),
        child: Center(
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _kPanel,
              border: Border.all(color: _kLine),
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 18,
                  color: Color(0x88000000),
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final List<Tag> tags;
  final String? tagFilterId;
  final String? statusFilter;
  final String? phaseFilter;
  final String? priorityFilter;
  final String categorySort;
  final String projectSort;
  final bool hasFilters;
  final ValueChanged<String?> onTagChanged;
  final ValueChanged<String?> onStatusChanged;
  final ValueChanged<String?> onPhaseChanged;
  final ValueChanged<String?> onPriorityChanged;
  final ValueChanged<String?> onCategorySortChanged;
  final ValueChanged<String?> onProjectSortChanged;
  final VoidCallback onClear;
  final int totalCount;
  final int filteredCount;

  const _FilterBar({
    required this.tags,
    required this.tagFilterId,
    required this.statusFilter,
    required this.phaseFilter,
    required this.priorityFilter,
    required this.categorySort,
    required this.projectSort,
    required this.hasFilters,
    required this.onTagChanged,
    required this.onStatusChanged,
    required this.onPhaseChanged,
    required this.onPriorityChanged,
    required this.onCategorySortChanged,
    required this.onProjectSortChanged,
    required this.onClear,
    required this.totalCount,
    required this.filteredCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kPanel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _Dropdown<String?>(
            value: tagFilterId,
            width: 150,
            items: [
              const DropdownMenuItem(value: null, child: Text('All tags')),
              ...tags.map(
                (tag) => DropdownMenuItem(
                  value: tag.id,
                  child: Text(tag.name, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged: onTagChanged,
          ),
          _Dropdown<String?>(
            value: statusFilter,
            width: 170,
            items: [
              const DropdownMenuItem(value: null, child: Text('All statuses')),
              for (final option in projectStatusOptions)
                DropdownMenuItem(
                  value: option.value,
                  child: Tooltip(
                    message: '${option.descriptor}: ${option.description}',
                    child: Text(option.label, overflow: TextOverflow.ellipsis),
                  ),
                ),
            ],
            onChanged: onStatusChanged,
          ),
          _Dropdown<String?>(
            value: phaseFilter,
            width: 130,
            items: const [
              DropdownMenuItem(value: null, child: Text('All phases')),
              DropdownMenuItem(value: 'idea', child: Text('idea')),
              DropdownMenuItem(value: 'design', child: Text('design')),
              DropdownMenuItem(value: 'build', child: Text('build')),
              DropdownMenuItem(value: 'test', child: Text('test')),
              DropdownMenuItem(value: 'ship', child: Text('ship')),
              DropdownMenuItem(value: 'stabilize', child: Text('stabilize')),
            ],
            onChanged: onPhaseChanged,
          ),
          _Dropdown<String?>(
            value: priorityFilter,
            width: 140,
            items: const [
              DropdownMenuItem(value: null, child: Text('All priority')),
              DropdownMenuItem(value: 'low', child: Text('low')),
              DropdownMenuItem(value: 'normal', child: Text('normal')),
              DropdownMenuItem(value: 'high', child: Text('high')),
              DropdownMenuItem(value: 'urgent', child: Text('urgent')),
            ],
            onChanged: onPriorityChanged,
          ),
          _Dropdown<String>(
            value: categorySort,
            width: 190,
            items: [
              for (final option in _categorySortOptions)
                DropdownMenuItem(
                  value: option.value,
                  child: Text(option.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onCategorySortChanged,
          ),
          _Dropdown<String>(
            value: projectSort,
            width: 180,
            items: [
              for (final option in _projectSortOptions)
                DropdownMenuItem(
                  value: option.value,
                  child: Text(option.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onProjectSortChanged,
          ),
          Text(
            hasFilters
                ? '$filteredCount / $totalCount'
                : '$totalCount projects',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          if (hasFilters)
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.filter_alt_off, size: 16),
              label: const Text('Clear'),
            ),
        ],
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final Project project;
  final List<Tag> tags;
  final ProjectUpdateAttribution? updateAttribution;
  final bool isSelected;
  final bool isPinned;
  final VoidCallback onTogglePin;
  final VoidCallback onExport;
  final VoidCallback onMerge;
  final VoidCallback onEditMeta;
  final VoidCallback onTap;

  const _ProjectTile({
    required this.project,
    required this.tags,
    required this.updateAttribution,
    required this.isSelected,
    required this.isPinned,
    required this.onTogglePin,
    required this.onExport,
    required this.onMerge,
    required this.onEditMeta,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhase = (project.phase ?? '').isNotEmpty;
    final priority = normalizePriorityValue(project.priority);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _kPanel,
            border: Border.all(
              color: isSelected ? const Color(0x4479A7FF) : _kLine,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0x2679A7FF)
                      : const Color(0x10FFFFFF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isSelected ? Icons.folder_open : Icons.folder_outlined,
                  size: 18,
                  color: isSelected ? _kPrimary : Colors.white38,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            project.title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (isSelected) const _SelectedPill(),
                      ],
                    ),
                    if (updateAttribution != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        _formatProjectUpdateAttribution(updateAttribution!),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if ((project.description ?? '').isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        project.description!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        _Pill(
                          label: projectStatusLabel(project.status),
                          color: projectStatusColor(project.status),
                          tooltip:
                              '${projectStatusDescriptor(project.status)}: '
                              '${projectStatusDescription(project.status)}',
                        ),
                        if (normalizeProjectCategory(project.category) != null)
                          _Pill(
                            label: projectCategoryLabel(project.category),
                            color: Colors.cyan,
                          ),
                        if (hasPhase)
                          _Pill(
                            label: project.phase!,
                            color: _phaseColor(project.phase),
                          ),
                        if (priority != 'normal')
                          _Pill(
                            label: priority,
                            color: _priorityColor(priority),
                          ),
                        ...tags
                            .take(4)
                            .map(
                              (tag) => _Pill(
                                label: '#${tag.name}',
                                color: _tagColor(tag),
                              ),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: isPinned ? 'Unpin project' : 'Pin project',
                onPressed: onTogglePin,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
                padding: EdgeInsets.zero,
                icon: Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 18,
                  color: isPinned ? _kPrimary : Colors.white54,
                ),
              ),
              IconButton(
                tooltip: 'Edit metadata',
                onPressed: onEditMeta,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.edit_note_outlined, size: 18),
              ),
              IconButton(
                tooltip: 'Export project bundle',
                onPressed: onExport,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.archive_outlined, size: 18),
              ),
              IconButton(
                tooltip: 'Merge project',
                onPressed: onMerge,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.call_merge, size: 18),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatProjectUpdateAttribution(ProjectUpdateAttribution attribution) {
  final actor = attribution.updatedBy.trim().isEmpty
      ? 'Atlas'
      : attribution.updatedBy.trim();
  final contact = attribution.contactName?.trim();
  final contactSuffix = contact == null || contact.isEmpty || contact == actor
      ? ''
      : ' | Contact: $contact';
  return 'Updated ${_formatProjectDateTime(attribution.updatedAt.toLocal())} by $actor$contactSuffix';
}

String _formatProjectDateTime(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = months[value.month - 1];
  final hour12 = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  final amPm = value.hour >= 12 ? 'PM' : 'AM';
  return '$month ${value.day}, ${value.year} $hour12:$minute $amPm';
}

class _ProjectCategorySection extends StatelessWidget {
  final String title;
  final int count;
  final bool collapsed;
  final bool pinned;
  final VoidCallback onToggle;
  final VoidCallback onTogglePin;
  final List<Widget> children;

  const _ProjectCategorySection({
    required this.title,
    required this.count,
    required this.collapsed,
    required this.pinned,
    required this.onToggle,
    required this.onTogglePin,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onToggle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF10151D),
                border: Border.all(color: _kLine),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.keyboard_arrow_down,
                    size: 18,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _Pill(label: '$count', color: Colors.white54),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: pinned ? 'Unpin category' : 'Pin category',
                    onPressed: onTogglePin,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      size: 16,
                      color: pinned ? _kPrimary : Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[const SizedBox(height: 8), ...children],
        ],
      ),
    );
  }
}

class _SelectedPill extends StatelessWidget {
  const _SelectedPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x2679A7FF),
        border: Border.all(color: const Color(0x4D79A7FF)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'SELECTED',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: _kPrimary,
        ),
      ),
    );
  }
}

class _EmptyProjects extends StatelessWidget {
  const _EmptyProjects();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 48, color: Colors.white38),
            SizedBox(height: 16),
            Text(
              'No projects yet.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text(
              'Create a project to unlock its detail view, task stage,\nownership map, risks, decisions, and documents.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectsLoadError extends StatelessWidget {
  final Object? error;
  const _ProjectsLoadError({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 44,
              color: Colors.orangeAccent,
            ),
            const SizedBox(height: 12),
            const Text(
              'Projects failed to load.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double width;

  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 38,
      child: DropdownButtonFormField<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        isExpanded: true,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final String? tooltip;
  const _Pill({required this.label, required this.color, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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

String _shortSha(String value) {
  final trimmed = value.trim();
  return trimmed.length <= 8 ? trimmed : trimmed.substring(0, 8);
}

String _pathKey(String value) => value
    .trim()
    .replaceAll('/', r'\')
    .replaceAll(RegExp(r'\\+$'), '')
    .toLowerCase();

List<String> _decodeStringList(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.map((item) => '$item').toList(growable: false);
    }
  } catch (_) {}
  return const [];
}

String _observationDisplayName(ProjectObservation observation) {
  try {
    final decoded = jsonDecode(observation.rawJson);
    if (decoded is Map && decoded['displayName'] is String) {
      final displayName = (decoded['displayName'] as String).trim();
      if (displayName.isNotEmpty) return displayName;
    }
  } catch (_) {}
  final normalized = observation.observedPath.replaceAll('/', r'\');
  final parts = normalized
      .split(r'\')
      .where((part) => part.trim().isNotEmpty)
      .toList(growable: false);
  return parts.isEmpty ? observation.observedPath : parts.last;
}

Color _tagColor(Tag tag) {
  final raw = tag.color;
  if (raw != null && raw.startsWith('#') && raw.length == 7) {
    final parsed = int.tryParse(raw.substring(1), radix: 16);
    if (parsed != null) return Color(0xFF000000 | parsed);
  }
  return _kPrimary;
}
