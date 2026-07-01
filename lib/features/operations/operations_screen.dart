import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../db/app_db.dart';
import '../../services/local_operations_scanner.dart';
import '../../shared/models/app_state_scope.dart';

const _bg = Color(0xFF0F1115);
const _panel = Color(0xFF151A22);
const _line = Color(0xFF273044);
const _primary = Color(0xFF79A7FF);
const _text87 = Color(0xDEFFFFFF);
const _text54 = Color(0x8AFFFFFF);

class OperationsScreen extends StatefulWidget {
  const OperationsScreen({super.key});

  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends State<OperationsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final List<String> _scanRoots = [defaultOperationsRoot];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureScanFolder());
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _addFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose folder to scan',
    );
    if (path == null || path.trim().isEmpty) return;
    if (isUnsafeOperationsScanRoot(path)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a folder below a drive root.')),
      );
      return;
    }
    final key = _rootKey(path);
    if (_scanRoots.any((root) => _rootKey(root) == key)) return;
    setState(() => _scanRoots.add(path));
  }

  void _removeRoot(String path) {
    if (_scanRoots.length <= 1) return;
    setState(() => _scanRoots.remove(path));
  }

  void _resetRoots() {
    setState(() {
      _scanRoots
        ..clear()
        ..add(defaultOperationsRoot);
    });
  }

  Future<void> _ensureScanFolder() async {
    try {
      await AppStateScope.of(context).ensureOperationsScansFolder();
    } catch (_) {}
  }

  Future<void> _openScanFolder() async {
    try {
      await AppStateScope.of(context).openOperationsScansFolder();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Open folder failed: $error')));
    }
  }

  Future<void> _runScan() async {
    if (_scanning) return;
    final state = AppStateScope.of(context);
    setState(() => _scanning = true);
    try {
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: List.unmodifiable(_scanRoots)),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Scan completed: $runId')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Scan failed: $error')));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: const Text('Operations'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorColor: _primary,
          labelColor: _primary,
          unselectedLabelColor: _text54,
          tabs: const [
            Tab(text: 'Scan Runs'),
            Tab(text: 'Review Candidates'),
            Tab(text: 'Registered Projects'),
            Tab(text: 'Enrichment'),
            Tab(text: 'Warnings'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ScanRunsTab(
            roots: _scanRoots,
            scanning: _scanning,
            onAddFolder: _addFolder,
            onRemoveRoot: _removeRoot,
            onResetRoots: _resetRoots,
            onOpenFolder: _openScanFolder,
            onRunScan: _runScan,
          ),
          const _ReviewCandidatesTab(),
          const _RegistryTab(),
          const _EnrichmentRunsTab(),
          const _WarningsTab(),
        ],
      ),
    );
  }
}

class _ScanRunsTab extends StatelessWidget {
  final List<String> roots;
  final bool scanning;
  final VoidCallback onAddFolder;
  final ValueChanged<String> onRemoveRoot;
  final VoidCallback onResetRoots;
  final VoidCallback onOpenFolder;
  final VoidCallback onRunScan;

  const _ScanRunsTab({
    required this.roots,
    required this.scanning,
    required this.onAddFolder,
    required this.onRemoveRoot,
    required this.onResetRoots,
    required this.onOpenFolder,
    required this.onRunScan,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<ProjectScanRun>>(
      stream: state.watchProjectScanRuns(),
      builder: (context, snap) {
        if (snap.hasError) {
          return _EmptyState(
            icon: Icons.error_outline,
            title: 'Scan runs failed to load.',
            details: '${snap.error}',
          );
        }
        final runs = snap.data ?? const <ProjectScanRun>[];
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: runs.isEmpty ? 2 : runs.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            if (index == 0) {
              return _ScanRootsPanel(
                roots: roots,
                scanning: scanning,
                onAddFolder: onAddFolder,
                onRemoveRoot: onRemoveRoot,
                onResetRoots: onResetRoots,
                onOpenFolder: onOpenFolder,
                onRunScan: onRunScan,
              );
            }
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (runs.isEmpty) {
              return const _EmptyState(
                icon: Icons.radar_outlined,
                title: 'No scans yet.',
              );
            }
            return _ScanRunTile(run: runs[index - 1]);
          },
        );
      },
    );
  }
}

class _ScanRootsPanel extends StatelessWidget {
  final List<String> roots;
  final bool scanning;
  final VoidCallback onAddFolder;
  final ValueChanged<String> onRemoveRoot;
  final VoidCallback onResetRoots;
  final VoidCallback onOpenFolder;
  final VoidCallback onRunScan;

  const _ScanRootsPanel({
    required this.roots,
    required this.scanning,
    required this.onAddFolder,
    required this.onRemoveRoot,
    required this.onResetRoots,
    required this.onOpenFolder,
    required this.onRunScan,
  });

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Scan roots',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              IconButton(
                tooltip: 'Reset roots',
                onPressed: scanning ? null : onResetRoots,
                icon: const Icon(Icons.restart_alt),
              ),
              OutlinedButton.icon(
                onPressed: scanning ? null : onAddFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add folder'),
              ),
              OutlinedButton.icon(
                onPressed: onOpenFolder,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Open scan folder'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: scanning ? null : onRunScan,
                icon: scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar),
                label: Text(scanning ? 'Scanning' : 'Scan selected'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final root in roots)
                InputChip(
                  avatar: const Icon(Icons.folder_outlined, size: 18),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Text(root, overflow: TextOverflow.ellipsis),
                  ),
                  onDeleted: roots.length <= 1 || scanning
                      ? null
                      : () => onRemoveRoot(root),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScanRunTile extends StatelessWidget {
  final ProjectScanRun run;
  const _ScanRunTile({required this.run});

  Future<void> _copyJson(BuildContext context) async {
    final state = AppStateScope.of(context);
    final json = await state.buildProjectScanRunExportJson(run.id);
    await Clipboard.setData(ClipboardData(text: json));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Scan JSON copied.')));
  }

  Future<void> _saveJson(BuildContext context) async {
    final state = AppStateScope.of(context);
    final json = await state.buildProjectScanRunExportJson(run.id);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export scan JSON',
      fileName: '${run.id}_operations_scan.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null || path.trim().isEmpty) return;
    final outputPath = path.toLowerCase().endsWith('.json')
        ? path
        : '$path.json';
    await File(outputPath).writeAsString(json);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Scan JSON exported: $outputPath')));
  }

  Future<void> _saveScanToAppFolder(BuildContext context) async {
    final state = AppStateScope.of(context);
    final path = await state.saveProjectScanRunExportToAppFolder(run.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Scan JSON saved: $path')));
  }

  Future<void> _saveWarningsToAppFolder(BuildContext context) async {
    final state = AppStateScope.of(context);
    final path = await state.saveProjectScanRunWarningsToAppFolder(run.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Warnings JSON saved: $path')));
  }

  Future<void> _openScanFolder(BuildContext context) async {
    await AppStateScope.of(context).openOperationsScansFolder();
  }

  Future<void> _handleMenu(BuildContext context, String value) async {
    try {
      switch (value) {
        case 'copy':
          await _copyJson(context);
          break;
        case 'export':
          await _saveJson(context);
          break;
        case 'save_scan':
          await _saveScanToAppFolder(context);
          break;
        case 'save_warnings':
          await _saveWarningsToAppFolder(context);
          break;
        case 'open_folder':
          await _openScanFolder(context);
          break;
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Scan action failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final roots = _decodeList(run.rootsJson).join(', ');
    return _Panel(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          run.status == 'completed'
              ? Icons.check_circle_outline
              : Icons.error_outline,
          color: run.status == 'completed' ? Colors.green : Colors.orange,
        ),
        title: Text(run.id, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '$roots\n${run.candidates} candidates, ${run.totalSeen} folders seen, ${run.ignored} ignored',
          style: const TextStyle(color: _text54),
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          tooltip: 'Scan actions',
          icon: const Icon(Icons.more_vert),
          onSelected: (value) => _handleMenu(context, value),
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'copy',
              child: ListTile(
                leading: Icon(Icons.copy),
                title: Text('Copy full JSON'),
              ),
            ),
            PopupMenuItem(
              value: 'export',
              child: ListTile(
                leading: Icon(Icons.file_download_outlined),
                title: Text('Export full JSON'),
              ),
            ),
            PopupMenuItem(
              value: 'save_scan',
              child: ListTile(
                leading: Icon(Icons.save_alt),
                title: Text('Save full JSON to app folder'),
              ),
            ),
            PopupMenuItem(
              value: 'save_warnings',
              child: ListTile(
                leading: Icon(Icons.report_outlined),
                title: Text('Save warnings JSON to app folder'),
              ),
            ),
            PopupMenuItem(
              value: 'open_folder',
              child: ListTile(
                leading: Icon(Icons.folder_open_outlined),
                title: Text('Open scan folder'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _CandidateFilter { needsAction, known, ignored, all }

class _ReviewCandidatesTab extends StatefulWidget {
  const _ReviewCandidatesTab();

  @override
  State<_ReviewCandidatesTab> createState() => _ReviewCandidatesTabState();
}

class _ReviewCandidatesTabState extends State<_ReviewCandidatesTab> {
  _CandidateFilter _filter = _CandidateFilter.needsAction;
  final Set<String> _selectedIds = {};

  Future<void> _bulkReview(
    BuildContext context,
    List<ProjectObservation> rows,
    String reviewState,
  ) async {
    final ids = _selectedIds
        .where((id) => rows.any((row) => row.id == id))
        .toList(growable: false);
    if (ids.isEmpty) return;
    final state = AppStateScope.of(context);
    switch (reviewState) {
      case 'accepted':
        await state.acceptProjectObservations(ids);
        break;
      case 'ignored':
        await state.ignoreProjectObservations(ids);
        break;
      case 'needs_review':
        await state.markProjectObservationsNeedsReview(ids);
        break;
    }
    if (!mounted) return;
    setState(() => _selectedIds.removeAll(ids));
  }

  Future<void> _ignoreDescendants(
    BuildContext context,
    List<ProjectObservation> rows,
  ) async {
    final selected = rows
        .where((row) => _selectedIds.contains(row.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final ids = rows
        .where(
          (row) => selected.any(
            (root) =>
                row.id != root.id &&
                _isDescendantPath(row.observedPath, root.observedPath),
          ),
        )
        .map((row) => row.id)
        .toSet();
    if (ids.isEmpty) return;
    await AppStateScope.of(context).ignoreProjectObservations(ids);
    if (!mounted) return;
    setState(() => _selectedIds.removeAll(ids));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<ProjectObservation>>(
      stream: state.watchRecentProjectObservations(),
      builder: (context, observationSnap) {
        if (observationSnap.hasError) {
          return _EmptyState(
            icon: Icons.error_outline,
            title: 'Candidates failed to load.',
            details: '${observationSnap.error}',
          );
        }
        final observations = _latestByPath(
          observationSnap.data ?? const <ProjectObservation>[],
        );
        return StreamBuilder<List<ProjectRegistryEntry>>(
          stream: state.watchProjectRegistry(),
          builder: (context, registrySnap) {
            if (registrySnap.hasError) {
              return _EmptyState(
                icon: Icons.error_outline,
                title: 'Candidates failed to load.',
                details: '${registrySnap.error}',
              );
            }
            final registryByPath = {
              for (final entry
                  in registrySnap.data ?? const <ProjectRegistryEntry>[])
                entry.localPath: entry,
            };
            final rows = _sortCandidateRows(
              observations
                  .where((observation) {
                    final registry = registryByPath[observation.observedPath];
                    return _candidateMatchesFilter(registry, _filter);
                  })
                  .toList(growable: false),
              registryByPath,
            );
            if (observationSnap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (observations.isEmpty) {
              return const _EmptyState(
                icon: Icons.fact_check_outlined,
                title: 'No candidates yet.',
              );
            }
            return Column(
              children: [
                _CandidateQueueToolbar(
                  filter: _filter,
                  selectedCount: _selectedIds.length,
                  visibleCount: rows.length,
                  onFilterChanged: (filter) => setState(() {
                    _filter = filter;
                    _selectedIds.clear();
                  }),
                  onClearSelection: () => setState(_selectedIds.clear),
                  onAcceptSelected: () =>
                      _bulkReview(context, rows, 'accepted'),
                  onIgnoreSelected: () => _bulkReview(context, rows, 'ignored'),
                  onNeedsReviewSelected: () =>
                      _bulkReview(context, rows, 'needs_review'),
                  onIgnoreDescendants: () =>
                      _ignoreDescendants(context, observations),
                ),
                const Divider(height: 1, color: _line),
                Expanded(
                  child: rows.isEmpty
                      ? _EmptyState(
                          icon: Icons.done_all_outlined,
                          title: _filter == _CandidateFilter.needsAction
                              ? 'No candidates need action.'
                              : 'No candidates in this view.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: rows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final observation = rows[index];
                            return _ObservationCard(
                              observation: observation,
                              registry:
                                  registryByPath[observation.observedPath],
                              selected: _selectedIds.contains(observation.id),
                              onSelectedChanged: (selected) => setState(() {
                                if (selected) {
                                  _selectedIds.add(observation.id);
                                } else {
                                  _selectedIds.remove(observation.id);
                                }
                              }),
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
  }
}

class _CandidateQueueToolbar extends StatelessWidget {
  final _CandidateFilter filter;
  final int selectedCount;
  final int visibleCount;
  final ValueChanged<_CandidateFilter> onFilterChanged;
  final VoidCallback onClearSelection;
  final VoidCallback onAcceptSelected;
  final VoidCallback onIgnoreSelected;
  final VoidCallback onNeedsReviewSelected;
  final VoidCallback onIgnoreDescendants;

  const _CandidateQueueToolbar({
    required this.filter,
    required this.selectedCount,
    required this.visibleCount,
    required this.onFilterChanged,
    required this.onClearSelection,
    required this.onAcceptSelected,
    required this.onIgnoreSelected,
    required this.onNeedsReviewSelected,
    required this.onIgnoreDescendants,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _panel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _FilterChipButton(
            label: 'Needs action',
            selected: filter == _CandidateFilter.needsAction,
            onSelected: () => onFilterChanged(_CandidateFilter.needsAction),
          ),
          _FilterChipButton(
            label: 'Known',
            selected: filter == _CandidateFilter.known,
            onSelected: () => onFilterChanged(_CandidateFilter.known),
          ),
          _FilterChipButton(
            label: 'Ignored',
            selected: filter == _CandidateFilter.ignored,
            onSelected: () => onFilterChanged(_CandidateFilter.ignored),
          ),
          _FilterChipButton(
            label: 'All',
            selected: filter == _CandidateFilter.all,
            onSelected: () => onFilterChanged(_CandidateFilter.all),
          ),
          Text(
            '$visibleCount visible',
            style: const TextStyle(fontSize: 12, color: _text54),
          ),
          if (selectedCount > 0) ...[
            Text(
              '$selectedCount selected',
              style: const TextStyle(fontSize: 12, color: _primary),
            ),
            OutlinedButton.icon(
              onPressed: onAcceptSelected,
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Accept selected'),
            ),
            OutlinedButton.icon(
              onPressed: onNeedsReviewSelected,
              icon: const Icon(Icons.flag_outlined, size: 16),
              label: const Text('Needs review'),
            ),
            OutlinedButton.icon(
              onPressed: onIgnoreSelected,
              icon: const Icon(Icons.visibility_off_outlined, size: 16),
              label: const Text('Ignore selected'),
            ),
            TextButton.icon(
              onPressed: onIgnoreDescendants,
              icon: const Icon(Icons.account_tree_outlined, size: 16),
              label: const Text('Ignore descendants'),
            ),
            IconButton(
              tooltip: 'Clear selection',
              onPressed: onClearSelection,
              icon: const Icon(Icons.close, size: 16),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  const _FilterChipButton({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      selectedColor: const Color(0x3379A7FF),
      side: const BorderSide(color: _line),
    );
  }
}

class _ObservationCard extends StatelessWidget {
  final ProjectObservation observation;
  final ProjectRegistryEntry? registry;
  final bool selected;
  final ValueChanged<bool> onSelectedChanged;

  const _ObservationCard({
    required this.observation,
    required this.registry,
    required this.selected,
    required this.onSelectedChanged,
  });

  Future<void> _link(BuildContext context) async {
    final state = AppStateScope.of(context);
    final projects = await state.getProjectsFull();
    if (!context.mounted) return;
    final projectId = await showDialog<String>(
      context: context,
      builder: (_) => _ProjectLinkDialog(projects: projects),
    );
    if (projectId == null || projectId.isEmpty) return;
    await state.linkProjectObservation(observation.id, projectId);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final markers = _decodeList(observation.markerFilesJson);
    final warnings = _decodeList(observation.warningsJson);
    final reviewState = registry?.reviewState ?? 'unreviewed';
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: selected,
                onChanged: (value) => onSelectedChanged(value ?? false),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _displayName(observation),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      observation.observedPath,
                      style: const TextStyle(color: _text54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              _Pill(label: reviewState),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Pill(label: observation.classificationGuess),
              _Pill(label: '${observation.confidence}% confidence'),
              if (observation.branch != null)
                _Pill(label: 'branch ${observation.branch}'),
              if (observation.dirtyCount != null)
                _Pill(label: '${observation.dirtyCount} dirty'),
              if (observation.remoteUrl != null) const _Pill(label: 'remote'),
            ],
          ),
          if (markers.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Markers: ${markers.join(', ')}',
              style: const TextStyle(color: _text54, fontSize: 12),
            ),
          ],
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              warnings.join('\n'),
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Accept'),
                onPressed: () => state.acceptProjectObservation(observation.id),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('Link'),
                onPressed: () => _link(context),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Needs review'),
                onPressed: () =>
                    state.markProjectObservationNeedsReview(observation.id),
              ),
              TextButton.icon(
                icon: const Icon(Icons.visibility_off_outlined),
                label: const Text('Ignore'),
                onPressed: () => state.ignoreProjectObservation(observation.id),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EnrichmentRunsTab extends StatefulWidget {
  const _EnrichmentRunsTab();

  @override
  State<_EnrichmentRunsTab> createState() => _EnrichmentRunsTabState();
}

class _EnrichmentRunsTabState extends State<_EnrichmentRunsTab> {
  bool _running = false;
  Timer? _elapsedTicker;
  Future<List<ProjectEnrichmentRun>>? _runsFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runsFuture ??= AppStateScope.of(
      context,
    ).getProjectEnrichmentRuns(limit: 50);
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    super.dispose();
  }

  void _syncElapsedTicker(bool busy) {
    if (busy && _elapsedTicker == null) {
      _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      return;
    }
    if (!busy && _elapsedTicker != null) {
      _elapsedTicker?.cancel();
      _elapsedTicker = null;
    }
  }

  Future<void> _runEnrichment(BuildContext context) async {
    if (_running) return;
    final options = await showDialog<_EnrichmentRunOptions>(
      context: context,
      builder: (ctx) {
        var refreshSummaries = false;
        var forceSummaries = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Run project enrichment'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Atlas will refresh linked project records, import eligible documents/media/source files/cards, and record findings. Source repositories are not modified.',
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: refreshSummaries,
                  title: const Text('Refresh AI summaries'),
                  subtitle: const Text('Slow; uses Ollama project by project.'),
                  onChanged: (value) => setDialogState(() {
                    refreshSummaries = value ?? false;
                    if (!refreshSummaries) forceSummaries = false;
                  }),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: forceSummaries,
                  enabled: refreshSummaries,
                  title: const Text('Regenerate current summaries'),
                  subtitle: const Text('Slower; skips today by default.'),
                  onChanged: refreshSummaries
                      ? (value) => setDialogState(
                          () => forceSummaries = value ?? false,
                        )
                      : null,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(ctx).pop(
                  _EnrichmentRunOptions(
                    refreshSummaries: refreshSummaries,
                    forceSummaries: forceSummaries,
                  ),
                ),
                icon: const Icon(Icons.auto_fix_high, size: 16),
                label: const Text('Run'),
              ),
            ],
          ),
        );
      },
    );
    if (options == null || !context.mounted) return;
    setState(() => _running = true);
    try {
      final result = await AppStateScope.of(context).runProjectEnrichment(
        refreshLinkedProjects: true,
        includeSourceDocuments: true,
        refreshSummaries: options.refreshSummaries,
        forceSummaries: options.forceSummaries,
        betweenProjects: Duration.zero,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Enrichment ${result.run.status}: ${result.run.openFindings} open findings across ${result.run.linkedProjects} linked projects.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Enrichment failed: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _runsFuture = AppStateScope.of(
            context,
          ).getProjectEnrichmentRuns(limit: 50);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final busy = _running || state.isProjectEnrichmentRunning;
    final startedAt = state.projectEnrichmentStartedAt;
    final elapsed = startedAt == null
        ? null
        : DateTime.now().difference(startedAt);
    _syncElapsedTicker(busy);
    return FutureBuilder<List<ProjectEnrichmentRun>>(
      future: _runsFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          return _EmptyState(
            icon: Icons.error_outline,
            title: 'Enrichment runs failed to load.',
            details: '${snap.error}',
          );
        }
        final runs = snap.data ?? const <ProjectEnrichmentRun>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: runs.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            if (index == 0) {
              return _EnrichmentControlPanel(
                busy: busy,
                runCount: runs.length,
                status: state.projectEnrichmentStatus,
                progress: state.projectEnrichmentProgress,
                progressLabel: state.projectEnrichmentProgressLabel,
                elapsed: elapsed,
                onRun: () => _runEnrichment(context),
              );
            }
            return _EnrichmentRunTile(run: runs[index - 1]);
          },
        );
      },
    );
  }
}

class _EnrichmentRunOptions {
  final bool refreshSummaries;
  final bool forceSummaries;

  const _EnrichmentRunOptions({
    required this.refreshSummaries,
    required this.forceSummaries,
  });
}

class _EnrichmentControlPanel extends StatelessWidget {
  final bool busy;
  final int runCount;
  final String? status;
  final double? progress;
  final String? progressLabel;
  final Duration? elapsed;
  final VoidCallback onRun;

  const _EnrichmentControlPanel({
    required this.busy,
    required this.runCount,
    required this.status,
    required this.progress,
    required this.progressLabel,
    required this.elapsed,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : onRun,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high),
                label: Text(busy ? 'Running' : 'Run enrichment'),
              ),
              _Pill(label: '$runCount runs'),
              const _Pill(label: 'Atlas-only'),
              const _Pill(label: 'No repo mutation'),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(value: progress, minHeight: 4),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.sync, size: 16, color: _text54),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status ?? 'Enrichment is running.',
                    style: const TextStyle(color: _text87),
                  ),
                ),
              ],
            ),
            if (elapsed != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Pill(label: 'elapsed ${_formatDuration(elapsed!)}'),
                  if (progressLabel != null) _Pill(label: progressLabel!),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _EnrichmentRunTile extends StatelessWidget {
  final ProjectEnrichmentRun run;

  const _EnrichmentRunTile({required this.run});

  @override
  Widget build(BuildContext context) {
    final warnings = run.warnings;
    return _Panel(
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        title: Text(
          '${run.status} - ${_formatDateTime(run.startedAt)}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Pill(label: '${run.linkedProjects} linked'),
              _Pill(label: '${run.createdItems} created'),
              _Pill(label: '${run.updatedItems} updated'),
              _Pill(label: '${run.openFindings} open findings'),
              if (run.summaryRefreshed > 0)
                _Pill(label: '${run.summaryRefreshed} summaries'),
              if (run.failedProjects > 0)
                _Pill(label: '${run.failedProjects} failed'),
            ],
          ),
        ),
        children: [
          if (warnings.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x22FF9800),
                border: Border.all(color: const Color(0x55FF9800)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                warnings.take(6).join('\n'),
                style: const TextStyle(color: Colors.amber, fontSize: 12),
              ),
            ),
          _EnrichmentStepsSection(runId: run.id),
          const SizedBox(height: 8),
          _EnrichmentProposalsSection(runId: run.id),
          const SizedBox(height: 8),
          FutureBuilder<List<ProjectEnrichmentFinding>>(
            future: AppStateScope.of(
              context,
            ).getProjectEnrichmentFindingsForRun(run.id),
            builder: (context, snap) {
              if (snap.hasError) {
                return Text(
                  'Findings failed to load: ${snap.error}',
                  style: const TextStyle(color: Colors.orangeAccent),
                );
              }
              final findings = snap.data ?? const <ProjectEnrichmentFinding>[];
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(),
                );
              }
              if (findings.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'No findings recorded.',
                    style: TextStyle(color: _text54),
                  ),
                );
              }
              return _EnrichmentFindingsSection(findings: findings);
            },
          ),
        ],
      ),
    );
  }
}

class _EnrichmentStepsSection extends StatelessWidget {
  final String runId;

  const _EnrichmentStepsSection({required this.runId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ProjectEnrichmentStep>>(
      future: AppStateScope.of(context).getProjectEnrichmentStepsForRun(runId),
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(
            'Worker steps failed to load: ${snap.error}',
            style: const TextStyle(color: Colors.orangeAccent),
          );
        }
        final steps = snap.data ?? const <ProjectEnrichmentStep>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        if (steps.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Worker steps',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final step in steps) _EnrichmentStepRow(step: step),
          ],
        );
      },
    );
  }
}

class _EnrichmentStepRow extends StatelessWidget {
  final ProjectEnrichmentStep step;

  const _EnrichmentStepRow({required this.step});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x101C2434),
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Pill(label: step.worker),
              _Pill(label: step.status),
              if (step.createdItems > 0)
                _Pill(label: '${step.createdItems} created'),
              if (step.updatedItems > 0)
                _Pill(label: '${step.updatedItems} updated'),
              if (step.findings > 0) _Pill(label: '${step.findings} findings'),
              if (step.proposals > 0)
                _Pill(label: '${step.proposals} proposals'),
            ],
          ),
          const SizedBox(height: 6),
          Text(step.title, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _EnrichmentProposalsSection extends StatelessWidget {
  final String runId;

  const _EnrichmentProposalsSection({required this.runId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ProjectEnrichmentProposal>>(
      future: AppStateScope.of(
        context,
      ).getProjectEnrichmentProposalsForRun(runId),
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(
            'Proposals failed to load: ${snap.error}',
            style: const TextStyle(color: Colors.orangeAccent),
          );
        }
        final proposals = snap.data ?? const <ProjectEnrichmentProposal>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        if (proposals.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Correction proposals',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final proposal in proposals.take(25))
              _EnrichmentProposalRow(proposal: proposal),
            if (proposals.length > 25)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${proposals.length - 25} more proposals recorded.',
                  style: const TextStyle(color: _text54, fontSize: 12),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EnrichmentProposalRow extends StatelessWidget {
  final ProjectEnrichmentProposal proposal;

  const _EnrichmentProposalRow({required this.proposal});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x101C2434),
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Pill(label: proposal.proposalType),
              _Pill(label: proposal.status),
              _Pill(label: '${proposal.confidence}% confidence'),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            proposal.title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if ((proposal.detail ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              proposal.detail!,
              style: const TextStyle(color: _text54, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _EnrichmentFindingsSection extends StatelessWidget {
  final List<ProjectEnrichmentFinding> findings;

  const _EnrichmentFindingsSection({required this.findings});

  @override
  Widget build(BuildContext context) {
    final groups = _groupOpenEnrichmentFindings(findings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (groups.isNotEmpty) ...[
          const Text(
            'Open findings summary',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final group in groups.take(12))
            _EnrichmentFindingGroupRow(group: group),
          if (groups.length > 12)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${groups.length - 12} more finding groups recorded.',
                style: const TextStyle(color: _text54, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
        ],
        Text(
          groups.isEmpty ? 'Recorded findings' : 'Individual findings',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        for (final finding in findings.take(80))
          _EnrichmentFindingRow(finding: finding),
        if (findings.length > 80)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${findings.length - 80} more individual findings recorded.',
              style: const TextStyle(color: _text54, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _EnrichmentFindingGroup {
  final String severity;
  final String category;
  final String title;
  final String? detail;
  final List<ProjectEnrichmentFinding> findings;

  const _EnrichmentFindingGroup({
    required this.severity,
    required this.category,
    required this.title,
    required this.detail,
    required this.findings,
  });

  int get count => findings.length;
}

class _EnrichmentFindingGroupRow extends StatelessWidget {
  final _EnrichmentFindingGroup group;

  const _EnrichmentFindingGroupRow({required this.group});

  @override
  Widget build(BuildContext context) {
    final examples = _findingGroupExamples(group.findings);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x1FFF9800),
        border: Border.all(color: const Color(0x44FF9800)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Pill(label: '${group.count} open'),
              _Pill(label: group.severity),
              _Pill(label: group.category),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            group.title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if ((group.detail ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              group.detail!,
              style: const TextStyle(color: _text54, fontSize: 12),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            _findingGroupActionHint(group),
            style: const TextStyle(color: Colors.amber, fontSize: 12),
          ),
          if (examples.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Examples: ${examples.join(' / ')}',
              style: const TextStyle(color: _text54, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _EnrichmentFindingRow extends StatelessWidget {
  final ProjectEnrichmentFinding finding;

  const _EnrichmentFindingRow({required this.finding});

  @override
  Widget build(BuildContext context) {
    final evidence = finding.evidence;
    final projectTitle = evidence['projectTitle']?.toString();
    final localPath = evidence['localPath']?.toString();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x141C2434),
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Pill(label: finding.severity),
              _Pill(label: finding.category),
              if (projectTitle != null && projectTitle.isNotEmpty)
                _Pill(label: projectTitle),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            finding.title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if ((finding.detail ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              finding.detail!,
              style: const TextStyle(color: _text54, fontSize: 12),
            ),
          ],
          if (localPath != null && localPath.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              localPath,
              style: const TextStyle(color: _text54, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

List<_EnrichmentFindingGroup> _groupOpenEnrichmentFindings(
  List<ProjectEnrichmentFinding> findings,
) {
  final grouped = <String, List<ProjectEnrichmentFinding>>{};
  for (final finding in findings.where((row) => row.status == 'open')) {
    final key = jsonEncode([
      finding.severity,
      finding.category,
      finding.title,
      finding.detail ?? '',
    ]);
    grouped.putIfAbsent(key, () => <ProjectEnrichmentFinding>[]).add(finding);
  }

  final groups = grouped.values.map((rows) {
    final first = rows.first;
    return _EnrichmentFindingGroup(
      severity: first.severity,
      category: first.category,
      title: first.title,
      detail: first.detail,
      findings: rows,
    );
  }).toList();

  groups.sort((a, b) {
    final severity = _findingSeverityRank(
      a.severity,
    ).compareTo(_findingSeverityRank(b.severity));
    if (severity != 0) return severity;
    final count = b.count.compareTo(a.count);
    if (count != 0) return count;
    final category = a.category.compareTo(b.category);
    if (category != 0) return category;
    return a.title.compareTo(b.title);
  });
  return groups;
}

int _findingSeverityRank(String severity) {
  switch (severity.toLowerCase()) {
    case 'error':
      return 0;
    case 'warning':
      return 1;
    case 'info':
      return 2;
    default:
      return 3;
  }
}

List<String> _findingGroupExamples(List<ProjectEnrichmentFinding> findings) {
  final examples = <String>[];
  for (final finding in findings) {
    final evidence = finding.evidence;
    final raw =
        evidence['projectTitle'] ??
        evidence['displayName'] ??
        evidence['localPath'];
    final label = _compactFindingExample(raw?.toString());
    if (label == null || examples.contains(label)) continue;
    examples.add(label);
    if (examples.length >= 3) break;
  }
  return examples;
}

String? _compactFindingExample(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final parts = trimmed.split(RegExp(r'[\\/]')).where((part) {
    return part.trim().isNotEmpty;
  }).toList();
  final label = parts.isEmpty ? trimmed : parts.last.trim();
  if (label.length <= 64) return label;
  return '${label.substring(0, 61)}...';
}

String _findingGroupActionHint(_EnrichmentFindingGroup group) {
  final category = group.category.toLowerCase();
  final title = group.title.toLowerCase();
  if (category == 'registry') {
    if (title.contains('not linked to an atlas project')) {
      return 'Link to an existing project, import it as a new project, or mark the candidate ignored.';
    }
    if (title.contains('still needs review')) {
      return 'Use Review Candidates to bulk accept, ignore, or keep needs-review rows.';
    }
    if (title.contains('not linked to a local registry entry')) {
      return 'Run or refresh an Operations scan, then link or upload the matching local project.';
    }
    if (title.contains('multiple local registry entries')) {
      return 'Review duplicate linked registry rows and unlink or ignore duplicates.';
    }
  }
  if (category == 'repository' && title.contains('github remote')) {
    return 'Use Refresh GitHub from Project Detail > Local Repo for the affected projects.';
  }
  if (category == 'library') {
    if (title.contains('no imported documents')) {
      return 'Run linked project refresh or import project documents before summary refresh.';
    }
    if (title.contains('no individual cards imported')) {
      return 'Run linked project refresh and review card parser or source coverage.';
    }
  }
  if (category == 'ai_summary' && title.contains('no cached ai summary')) {
    return 'Run AI summary refresh after documents and media are imported.';
  }
  return group.detail ??
      'Review the grouped findings and address the repeated source.';
}

enum _RegistryFilter { needsAction, linked, ignored, all }

class _RegistryTab extends StatefulWidget {
  const _RegistryTab();

  @override
  State<_RegistryTab> createState() => _RegistryTabState();
}

class _RegistryTabState extends State<_RegistryTab> {
  _RegistryFilter _filter = _RegistryFilter.needsAction;
  bool _refreshingLinked = false;

  Future<void> _refreshLinkedProjects(BuildContext context) async {
    if (_refreshingLinked) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Refresh linked projects'),
        content: const Text(
          'This refreshes every linked local project, including source-code files and atlas/card documents. Large generated/vendor/secret-like files are skipped by the refresh profile.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh linked'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    setState(() => _refreshingLinked = true);
    try {
      final result = await AppStateScope.of(context).refreshLinkedLocalProjects(
        includeSourceDocuments: true,
        betweenProjects: Duration.zero,
      );
      if (!context.mounted) return;
      final message = result.alreadyRunning
          ? 'Linked project refresh is already running.'
          : 'Linked refresh: ${result.created} created, ${result.updated} updated, ${result.failed} failed across ${result.considered} projects.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Linked refresh failed: $error')));
    } finally {
      if (mounted) setState(() => _refreshingLinked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<ProjectRegistryEntry>>(
      stream: state.watchProjectRegistry(),
      builder: (context, snap) {
        if (snap.hasError) {
          return _EmptyState(
            icon: Icons.error_outline,
            title: 'Registered projects failed to load.',
            details: '${snap.error}',
          );
        }
        final entries = snap.data ?? const <ProjectRegistryEntry>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (entries.isEmpty) {
          return const _EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'No registered projects yet.',
          );
        }
        return StreamBuilder<List<ProjectObservation>>(
          stream: state.watchRecentProjectObservations(limit: 1000),
          builder: (context, observationSnap) {
            if (observationSnap.hasError) {
              return _EmptyState(
                icon: Icons.error_outline,
                title: 'Registered projects failed to load.',
                details: '${observationSnap.error}',
              );
            }
            final latestByPath = <String, ProjectObservation>{
              for (final observation in _latestByPath(
                observationSnap.data ?? const <ProjectObservation>[],
              ))
                observation.observedPath: observation,
            };
            final rows = _sortRegistryRows(
              entries
                  .where((entry) => _registryMatchesFilter(entry, _filter))
                  .toList(growable: false),
            );
            return Column(
              children: [
                _RegistryQueueToolbar(
                  filter: _filter,
                  visibleCount: rows.length,
                  refreshingLinked:
                      _refreshingLinked || state.isLocalProjectRefreshRunning,
                  onRefreshLinked: () => _refreshLinkedProjects(context),
                  onFilterChanged: (filter) => setState(() => _filter = filter),
                ),
                const Divider(height: 1, color: _line),
                Expanded(
                  child: rows.isEmpty
                      ? _EmptyState(
                          icon: Icons.done_all_outlined,
                          title: _filter == _RegistryFilter.needsAction
                              ? 'No registered projects need action.'
                              : 'No registered projects in this view.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: rows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) => _RegistryTile(
                            entry: rows[index],
                            observation: latestByPath[rows[index].localPath],
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

class _RegistryQueueToolbar extends StatelessWidget {
  final _RegistryFilter filter;
  final int visibleCount;
  final bool refreshingLinked;
  final VoidCallback onRefreshLinked;
  final ValueChanged<_RegistryFilter> onFilterChanged;

  const _RegistryQueueToolbar({
    required this.filter,
    required this.visibleCount,
    required this.refreshingLinked,
    required this.onRefreshLinked,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _panel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _FilterChipButton(
            label: 'Needs action',
            selected: filter == _RegistryFilter.needsAction,
            onSelected: () => onFilterChanged(_RegistryFilter.needsAction),
          ),
          _FilterChipButton(
            label: 'Linked',
            selected: filter == _RegistryFilter.linked,
            onSelected: () => onFilterChanged(_RegistryFilter.linked),
          ),
          _FilterChipButton(
            label: 'Ignored',
            selected: filter == _RegistryFilter.ignored,
            onSelected: () => onFilterChanged(_RegistryFilter.ignored),
          ),
          _FilterChipButton(
            label: 'All',
            selected: filter == _RegistryFilter.all,
            onSelected: () => onFilterChanged(_RegistryFilter.all),
          ),
          Text(
            '$visibleCount visible',
            style: const TextStyle(fontSize: 12, color: _text54),
          ),
          OutlinedButton.icon(
            onPressed: refreshingLinked ? null : onRefreshLinked,
            icon: refreshingLinked
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync, size: 16),
            label: const Text('Refresh linked'),
          ),
        ],
      ),
    );
  }
}

class _RegistryTile extends StatelessWidget {
  final ProjectRegistryEntry entry;
  final ProjectObservation? observation;
  const _RegistryTile({required this.entry, this.observation});

  Future<void> _updateExisting(BuildContext context) async {
    try {
      final state = AppStateScope.of(context);
      final projects = await state.getProjectsFull();
      if (!context.mounted) return;
      final projectId = await showDialog<String>(
        context: context,
        builder: (_) => _ProjectLinkDialog(projects: projects),
      );
      if (projectId == null || projectId.isEmpty) return;
      final updatedProjectId = await state
          .updateExistingProjectFromRegistryEntry(entry.id, projectId);
      if (!context.mounted) return;
      context.go('/projects/$updatedProjectId');
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Project update failed: $error')));
    }
  }

  Future<void> _importToProject(BuildContext context) async {
    try {
      final projectId = await AppStateScope.of(
        context,
      ).importProjectRegistryEntryAsProject(entry.id);
      if (!context.mounted) return;
      context.go('/projects/$projectId');
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Project import failed: $error')));
    }
  }

  Future<void> _refreshLinkedProject(BuildContext context) async {
    final projectId = entry.atlasProjectId;
    if (projectId == null || projectId.isEmpty) return;
    try {
      final result = await AppStateScope.of(
        context,
      ).applyLocalProjectRefreshForRegistryEntry(entry.id, projectId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Refresh applied: ${result.created} created, ${result.updated} updated, ${result.unchanged} unchanged',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Refresh failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final linkedProjectId = entry.atlasProjectId;
    final canCreateOrUpdate =
        linkedProjectId == null && entry.reviewState == 'accepted';
    return _Panel(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(entry.displayName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${entry.localPath}\n${entry.classification} - ${entry.reviewState}',
              style: const TextStyle(color: _text54),
            ),
            const SizedBox(height: 6),
            _RepositoryStatusPills(entry: entry, observation: observation),
          ],
        ),
        isThreeLine: true,
        trailing: linkedProjectId == null
            ? canCreateOrUpdate
                  ? Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.link),
                          label: const Text('Update existing'),
                          onPressed: () => _updateExisting(context),
                        ),
                        FilledButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Create new'),
                          onPressed: () => _importToProject(context),
                        ),
                      ],
                    )
                  : null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                    onPressed: () => _refreshLinkedProject(context),
                  ),
                  IconButton(
                    tooltip: 'Open Atlas project',
                    icon: const Icon(Icons.open_in_new, color: _primary),
                    onPressed: () => context.go('/projects/$linkedProjectId'),
                  ),
                ],
              ),
      ),
    );
  }
}

class _WarningsTab extends StatelessWidget {
  const _WarningsTab();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<ProjectScanRun>>(
      stream: state.watchProjectScanRuns(),
      builder: (context, runSnap) {
        if (runSnap.hasError) {
          return _EmptyState(
            icon: Icons.error_outline,
            title: 'Warnings failed to load.',
            details: '${runSnap.error}',
          );
        }
        return StreamBuilder<List<ProjectObservation>>(
          stream: state.watchRecentProjectObservations(),
          builder: (context, observationSnap) {
            if (observationSnap.hasError) {
              return _EmptyState(
                icon: Icons.error_outline,
                title: 'Warnings failed to load.',
                details: '${observationSnap.error}',
              );
            }
            final rows = <String>[];
            for (final run in runSnap.data ?? const <ProjectScanRun>[]) {
              for (final warning in _decodeList(run.warningsJson)) {
                rows.add('${run.id}: $warning');
              }
            }
            for (final observation
                in observationSnap.data ?? const <ProjectObservation>[]) {
              for (final warning in _decodeList(observation.warningsJson)) {
                rows.add('${_displayName(observation)}: $warning');
              }
            }
            if (runSnap.connectionState == ConnectionState.waiting ||
                observationSnap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (rows.isEmpty) {
              return const _EmptyState(
                icon: Icons.check_circle_outline,
                title: 'No warnings recorded.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) => _Panel(
                child: SelectableText(
                  rows[index],
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ProjectLinkDialog extends StatefulWidget {
  final List<ProjectFull> projects;
  const _ProjectLinkDialog({required this.projects});

  @override
  State<_ProjectLinkDialog> createState() => _ProjectLinkDialogState();
}

class _ProjectLinkDialogState extends State<_ProjectLinkDialog> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Link to Atlas project'),
      content: DropdownButtonFormField<String>(
        value: _selectedId,
        items: [
          for (final project in widget.projects)
            DropdownMenuItem(value: project.id, child: Text(project.title)),
        ],
        onChanged: (value) => setState(() => _selectedId = value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selectedId == null
              ? null
              : () => Navigator.of(context).pop(_selectedId),
          child: const Text('Link'),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      padding: const EdgeInsets.all(14),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  const _Pill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x1F79A7FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x3379A7FF)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _RepositoryStatusPills extends StatelessWidget {
  final ProjectRegistryEntry entry;
  final ProjectObservation? observation;

  const _RepositoryStatusPills({required this.entry, this.observation});

  @override
  Widget build(BuildContext context) {
    final projectId = entry.atlasProjectId;
    if (projectId != null && projectId.trim().isNotEmpty) {
      return FutureBuilder<ProjectGitRemoteStatus?>(
        future: AppStateScope.of(
          context,
        ).getLatestProjectGitRemoteStatus(projectId),
        builder: (context, snapshot) => _RepositoryStatusPillWrap(
          entry: entry,
          observation: observation,
          github: snapshot.data,
        ),
      );
    }
    return _RepositoryStatusPillWrap(entry: entry, observation: observation);
  }
}

class _RepositoryStatusPillWrap extends StatelessWidget {
  final ProjectRegistryEntry entry;
  final ProjectObservation? observation;
  final ProjectGitRemoteStatus? github;

  const _RepositoryStatusPillWrap({
    required this.entry,
    this.observation,
    this.github,
  });

  @override
  Widget build(BuildContext context) {
    final remote = observation?.remoteUrl?.trim();
    final parsedGithub = _parseGithubRemote(remote);
    final dirtyCount = observation?.dirtyCount;
    final branch = observation?.branch;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if ((entry.gitRoot ?? '').trim().isNotEmpty)
          const _Pill(label: 'local git'),
        if (remote == null || remote.isEmpty)
          const _Pill(label: 'local-only')
        else if (github != null)
          _Pill(label: 'GitHub ${github!.fullName}')
        else if (parsedGithub != null)
          _Pill(label: 'GitHub ${parsedGithub.owner}/${parsedGithub.repo}')
        else
          const _Pill(label: 'remote non-GitHub'),
        if (github != null && (github!.visibility ?? '').isNotEmpty)
          _Pill(label: github!.visibility!),
        if (github != null && github!.hasError)
          const _Pill(label: 'GitHub warning'),
        if (branch != null && branch.trim().isNotEmpty)
          _Pill(label: 'branch $branch'),
        if (dirtyCount != null && dirtyCount > 0)
          _Pill(label: '$dirtyCount dirty'),
      ],
    );
  }
}

_GithubRemote? _parseGithubRemote(String? remoteUrl) {
  if (remoteUrl == null || remoteUrl.trim().isEmpty) return null;
  final trimmed = remoteUrl.trim();
  final patterns = [
    RegExp(
      r'github\.com[:/]([^/]+)/([^/\s]+?)(?:\.git)?$',
      caseSensitive: false,
    ),
    RegExp(
      r'^git@github\.com:([^/]+)/([^/\s]+?)(?:\.git)?$',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(trimmed);
    if (match == null) continue;
    final owner = match.group(1)?.trim();
    final repo = match.group(2)?.replaceAll(RegExp(r'\.git$'), '').trim();
    if (owner != null && owner.isNotEmpty && repo != null && repo.isNotEmpty) {
      return _GithubRemote(owner, repo);
    }
  }
  return null;
}

class _GithubRemote {
  final String owner;
  final String repo;

  const _GithubRemote(this.owner, this.repo);
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? details;
  const _EmptyState({required this.icon, required this.title, this.details});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: _text54),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(color: _text54)),
          if (details != null && details!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                details!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _text54, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

List<ProjectObservation> _latestByPath(List<ProjectObservation> observations) {
  final byPath = <String, ProjectObservation>{};
  for (final observation in observations) {
    final existing = byPath[observation.observedPath];
    if (existing == null ||
        observation.observedAt.isAfter(existing.observedAt)) {
      byPath[observation.observedPath] = observation;
    }
  }
  final rows = byPath.values.toList()
    ..sort((a, b) => b.observedAt.compareTo(a.observedAt));
  return rows;
}

List<ProjectObservation> _sortCandidateRows(
  List<ProjectObservation> rows,
  Map<String, ProjectRegistryEntry> registryByPath,
) {
  rows.sort((a, b) {
    final rank = _candidateRank(
      registryByPath[a.observedPath],
    ).compareTo(_candidateRank(registryByPath[b.observedPath]));
    if (rank != 0) return rank;
    final confidence = b.confidence.compareTo(a.confidence);
    if (confidence != 0) return confidence;
    return b.observedAt.compareTo(a.observedAt);
  });
  return rows;
}

bool _candidateMatchesFilter(
  ProjectRegistryEntry? registry,
  _CandidateFilter filter,
) {
  switch (filter) {
    case _CandidateFilter.needsAction:
      return registry == null || registry.reviewState == 'needs_review';
    case _CandidateFilter.known:
      return registry != null && registry.reviewState != 'ignored';
    case _CandidateFilter.ignored:
      return registry?.reviewState == 'ignored';
    case _CandidateFilter.all:
      return true;
  }
}

int _candidateRank(ProjectRegistryEntry? registry) {
  if (registry == null) return 0;
  if (registry.reviewState == 'needs_review') return 1;
  if (registry.reviewState == 'accepted') return 2;
  if (registry.atlasProjectId != null || registry.reviewState == 'linked') {
    return 3;
  }
  if (registry.reviewState == 'ignored') return 4;
  return 5;
}

List<ProjectRegistryEntry> _sortRegistryRows(List<ProjectRegistryEntry> rows) {
  rows.sort((a, b) {
    final rank = _registryRank(a).compareTo(_registryRank(b));
    if (rank != 0) return rank;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  });
  return rows;
}

bool _registryMatchesFilter(
  ProjectRegistryEntry entry,
  _RegistryFilter filter,
) {
  switch (filter) {
    case _RegistryFilter.needsAction:
      return entry.reviewState == 'needs_review' ||
          (entry.reviewState == 'accepted' &&
              (entry.atlasProjectId ?? '').isEmpty);
    case _RegistryFilter.linked:
      return (entry.atlasProjectId ?? '').isNotEmpty ||
          entry.reviewState == 'linked';
    case _RegistryFilter.ignored:
      return entry.reviewState == 'ignored';
    case _RegistryFilter.all:
      return true;
  }
}

int _registryRank(ProjectRegistryEntry entry) {
  if (entry.reviewState == 'needs_review') return 0;
  if (entry.reviewState == 'accepted' && (entry.atlasProjectId ?? '').isEmpty) {
    return 1;
  }
  if ((entry.atlasProjectId ?? '').isNotEmpty ||
      entry.reviewState == 'linked') {
    return 2;
  }
  if (entry.reviewState == 'ignored') return 3;
  return 4;
}

bool _isDescendantPath(String path, String root) {
  final normalizedPath = _normalizePath(path);
  final normalizedRoot = _normalizePath(root);
  if (normalizedPath == normalizedRoot) return false;
  return normalizedPath.startsWith('$normalizedRoot\\');
}

String _normalizePath(String path) => path
    .trim()
    .replaceAll('/', r'\')
    .replaceAll(RegExp(r'\\+$'), '')
    .toLowerCase();

String _formatDateTime(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${value.year}-${two(value.month)}-${two(value.day)}';
  final time = '${two(value.hour)}:${two(value.minute)}';
  return '$date $time';
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  String two(int n) => n.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
  return '$minutes:${two(seconds)}';
}

List<String> _decodeList(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded.map((item) => '$item').toList();
  } catch (_) {}
  return const [];
}

String _rootKey(String path) => path.trim().replaceAll('/', r'\').toLowerCase();

String _displayName(ProjectObservation observation) {
  try {
    final decoded = jsonDecode(observation.rawJson);
    if (decoded is Map && decoded['displayName'] is String) {
      final value = (decoded['displayName'] as String).trim();
      if (value.isNotEmpty) return value;
    }
  } catch (_) {}
  final parts = observation.observedPath.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? observation.observedPath : parts.last;
}
