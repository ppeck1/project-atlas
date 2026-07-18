import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../db/app_db.dart';
import '../../services/atlas_agent_service.dart';
import '../../services/project_capsule_service.dart';
import '../../services/project_capsule_truth_service.dart';
import '../../services/workload_planning_service.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/theme/atlas_colors.dart';
import '../../shared/widgets/atlas_command_palette.dart';
import 'capsule_truth_editor.dart';

typedef ProjectCapsuleLoader =
    Future<ProjectCapsuleSnapshot?> Function(String projectId);

class CapsuleScreen extends StatefulWidget {
  final ProjectCapsuleLoader? loader;

  const CapsuleScreen({super.key, this.loader});

  @override
  State<CapsuleScreen> createState() => _CapsuleScreenState();
}

class _CapsuleScreenState extends State<CapsuleScreen> {
  Stream<List<Project>>? _projects;
  Stream<Project?>? _activeProject;
  String? _selectedProjectId;
  int _refreshRevision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppStateScope.of(context);
    _projects ??= state.watchProjects();
    _activeProject ??= state.watchActiveProject();
  }

  String? _resolvedProjectId(List<Project> projects, Project? active) {
    final selected = _selectedProjectId;
    if (selected != null && projects.any((item) => item.id == selected)) {
      return selected;
    }
    if (active != null && projects.any((item) => item.id == active.id)) {
      return active.id;
    }
    return projects.isEmpty ? null : projects.first.id;
  }

  Future<void> _chooseProject(List<Project> projects, String currentId) async {
    final projectId = await showDialog<String>(
      context: context,
      builder: (_) => AtlasCommandPalette(projects: Future.value(projects)),
    );
    if (!mounted || projectId == null || projectId == currentId) return;
    setState(() {
      _selectedProjectId = projectId;
      _refreshRevision += 1;
    });
    unawaited(AppStateScope.read(context).setActiveById(projectId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Project Capsule'),
            Text(
              'Resume with shared project truth',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => context.go('/operations'),
            icon: const Icon(Icons.radar_outlined, size: 18),
            label: const Text('Sources & Health'),
          ),
          IconButton(
            tooltip: 'Refresh project capsule',
            onPressed: () => setState(() => _refreshRevision += 1),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<Project>>(
        stream: _projects,
        builder: (context, projectSnapshot) {
          if (projectSnapshot.connectionState == ConnectionState.waiting &&
              projectSnapshot.data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (projectSnapshot.hasError) {
            return _MessageState(
              title: 'Projects could not be loaded',
              message: '${projectSnapshot.error}',
              icon: Icons.error_outline,
            );
          }
          final projects = projectSnapshot.data ?? const <Project>[];
          if (projects.isEmpty) {
            return _MessageState(
              title: 'No projects to resume',
              message: 'Create a project before building a shared capsule.',
              icon: Icons.folder_off_outlined,
              actionLabel: 'Open Projects',
              onAction: () => context.go('/projects'),
            );
          }
          return StreamBuilder<Project?>(
            stream: _activeProject,
            builder: (context, activeSnapshot) {
              final projectId = _resolvedProjectId(
                projects,
                activeSnapshot.data,
              );
              if (projectId == null) {
                return const _MessageState(
                  title: 'Select a project',
                  message: 'Atlas needs a visible project to build a capsule.',
                  icon: Icons.info_outline,
                );
              }
              return _ProjectCapsuleBody(
                key: ValueKey('$projectId:$_refreshRevision'),
                projectId: projectId,
                loader: widget.loader,
                onChooseProject: () => _chooseProject(projects, projectId),
              );
            },
          );
        },
      ),
    );
  }
}

class _ProjectCapsuleBody extends StatefulWidget {
  final String projectId;
  final ProjectCapsuleLoader? loader;
  final VoidCallback onChooseProject;

  const _ProjectCapsuleBody({
    super.key,
    required this.projectId,
    required this.loader,
    required this.onChooseProject,
  });

  @override
  State<_ProjectCapsuleBody> createState() => _ProjectCapsuleBodyState();
}

class _ProjectCapsuleBodyState extends State<_ProjectCapsuleBody> {
  Future<ProjectCapsuleSnapshot?>? _snapshot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _snapshot ??= _load();
  }

  Future<ProjectCapsuleSnapshot?> _load() {
    final loader = widget.loader;
    if (loader != null) return loader(widget.projectId);
    final state = AppStateScope.read(context);
    return ProjectCapsuleService(
      AtlasAgentProjectCapsuleSource(AtlasAgentService(state)),
      truthService: ProjectCapsuleTruthService(state.db),
    ).buildSnapshot(widget.projectId);
  }

  Future<void> _editTruth(ProjectCapsuleSnapshot capsule) async {
    if (widget.loader != null) return;
    final state = AppStateScope.read(context);
    final saved = await showCapsuleTruthEditor(
      context: context,
      truth: capsule.authoredTruth,
      revisionId: capsule.truthRevisionId,
      onAccept: (fields, expectedRevisionId, reason) => state.updateProjectMeta(
        widget.projectId,
        fields,
        actor: 'Operator',
        sourceKind: 'capsule_editor',
        expectedTruthRevisionId: expectedRevisionId,
        reason: reason,
      ),
    );
    if (!mounted || !saved) return;
    setState(() {
      _snapshot = _load();
    });
  }

  Future<void> _showTruthHistory(ProjectCapsuleSnapshot capsule) async {
    if (widget.loader != null) return;
    final state = AppStateScope.read(context);
    try {
      final revisions = await state.getProjectCapsuleRevisions(
        widget.projectId,
      );
      if (!mounted) return;
      await showCapsuleTruthHistory(
        context: context,
        revisions: revisions,
        currentRevisionId: capsule.truthRevisionRecorded
            ? capsule.truthRevisionId
            : null,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Accepted truth history could not load: $error'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ProjectCapsuleSnapshot?>(
      future: _snapshot,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _MessageState(
            title: 'Capsule could not be built',
            message: '${snapshot.error}',
            icon: Icons.error_outline,
            actionLabel: 'Try again',
            onAction: () => setState(() {
              _snapshot = _load();
            }),
          );
        }
        final capsule = snapshot.data;
        if (capsule == null) {
          return const _MessageState(
            title: 'Project is unavailable',
            message: 'The selected project is no longer visible to Atlas.',
            icon: Icons.visibility_off_outlined,
          );
        }
        return _CapsuleTabs(
          capsule: capsule,
          onChooseProject: widget.onChooseProject,
          onEditTruth: widget.loader == null ? () => _editTruth(capsule) : null,
          onShowTruthHistory: widget.loader == null
              ? () => _showTruthHistory(capsule)
              : null,
        );
      },
    );
  }
}

class _CapsuleTabs extends StatelessWidget {
  final ProjectCapsuleSnapshot capsule;
  final VoidCallback onChooseProject;
  final VoidCallback? onEditTruth;
  final VoidCallback? onShowTruthHistory;

  const _CapsuleTabs({
    required this.capsule,
    required this.onChooseProject,
    required this.onEditTruth,
    required this.onShowTruthHistory,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: colors.panel,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: onChooseProject,
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: Text(_text(capsule.project['title'], 'Project')),
                ),
                _Pill('Status', _text(capsule.project['status'], 'unknown')),
                _Pill('Phase', _text(capsule.project['phase'], 'not set')),
                _Pill('Priority', _text(capsule.project['priority'], 'normal')),
                _Pill('Confidence', capsule.confidence),
                Tooltip(
                  message: capsule.contentHash,
                  child: _Pill('Snapshot', capsule.revisionId),
                ),
                Tooltip(
                  message: capsule.authoredTruth.contentHash,
                  child: _Pill(
                    'Truth',
                    capsule.truthRevisionNumber == null
                        ? 'unrecorded'
                        : 'v${capsule.truthRevisionNumber}',
                  ),
                ),
              ],
            ),
          ),
          Container(
            color: colors.panel,
            child: const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.play_arrow), text: 'Act'),
                Tab(icon: Icon(Icons.lightbulb_outline), text: 'Understand'),
                Tab(icon: Icon(Icons.fact_check_outlined), text: 'Audit'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ActTab(capsule),
                _UnderstandTab(
                  capsule,
                  onEditTruth: onEditTruth,
                  onShowTruthHistory: onShowTruthHistory,
                ),
                _AuditTab(capsule),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActTab extends StatelessWidget {
  final ProjectCapsuleSnapshot capsule;

  const _ActTab(this.capsule);

  @override
  Widget build(BuildContext context) {
    final projectId = _text(capsule.project['projectId'], '');
    final hasFrontier = <ProjectCapsuleAction>[
      ...capsule.readyItems,
      ...capsule.decisionItems,
      ...capsule.inProgressItems,
      ...capsule.reviewItems,
      ...capsule.blockedItems,
    ].isNotEmpty;
    return ListView(
      key: const Key('capsule-act-list'),
      padding: const EdgeInsets.all(16),
      children: [
        _RecommendationCard(capsule.recommendation),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => context.go(
                '/work?projectId=${Uri.encodeQueryComponent(projectId)}&scope=project',
              ),
              icon: const Icon(Icons.view_kanban_outlined, size: 18),
              label: const Text('Open project work'),
            ),
            OutlinedButton.icon(
              onPressed: () => context.go('/projects/$projectId'),
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('Project detail'),
            ),
            if (capsule.pendingAgentProposals > 0)
              OutlinedButton.icon(
                onPressed: () => context.go(
                  '/library?projectId=${Uri.encodeQueryComponent(projectId)}',
                ),
                icon: const Icon(Icons.rate_review_outlined, size: 18),
                label: Text(
                  'Review ${capsule.pendingAgentProposals} proposal${capsule.pendingAgentProposals == 1 ? '' : 's'}',
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (!hasFrontier)
          const _Section(
            title: 'Work frontier',
            icon: Icons.inbox_outlined,
            child: Text(
              'No active work is recorded. Define one bounded next action with an owner and verification.',
            ),
          ),
        _ActionSection('Ready now', capsule.readyItems),
        _ActionSection('Human must decide', capsule.decisionItems),
        _ActionSection('In progress', capsule.inProgressItems),
        _ActionSection('Ready for acceptance', capsule.reviewItems),
        _ActionSection('Waiting on evidence', capsule.blockedItems),
        if (capsule.errors.isNotEmpty ||
            capsule.warnings.isNotEmpty ||
            capsule.gaps.isNotEmpty)
          _MessagesSection(
            'Before committing',
            errors: capsule.errors,
            warnings: capsule.warnings,
            gaps: capsule.gaps,
          ),
      ],
    );
  }
}

class _UnderstandTab extends StatelessWidget {
  final ProjectCapsuleSnapshot capsule;
  final VoidCallback? onEditTruth;
  final VoidCallback? onShowTruthHistory;

  const _UnderstandTab(
    this.capsule, {
    required this.onEditTruth,
    required this.onShowTruthHistory,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const Key('capsule-understand-list'),
      padding: const EdgeInsets.all(16),
      children: [
        if (onEditTruth != null || onShowTruthHistory != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (onEditTruth != null)
                  FilledButton.icon(
                    key: const Key('capsule-edit-truth'),
                    onPressed: onEditTruth,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit accepted truth'),
                  ),
                if (onShowTruthHistory != null)
                  OutlinedButton.icon(
                    key: const Key('capsule-truth-history'),
                    onPressed: onShowTruthHistory,
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('Accepted history'),
                  ),
              ],
            ),
          ),
        _MapSection('Intent', Icons.flag_outlined, capsule.intent),
        _MapSection(
          'Accepted project state',
          Icons.verified_outlined,
          capsule.acceptedState,
        ),
        _RecordsSection(
          'Recent decisions',
          Icons.gavel_outlined,
          capsule.decisions,
          emptyMessage: 'No project decisions are recorded.',
        ),
        _RecordsSection(
          'Recorded risks',
          Icons.warning_amber_outlined,
          capsule.risks,
          emptyMessage: 'No project risks are recorded.',
        ),
        _MapSection('Scope', Icons.filter_center_focus, capsule.scope),
        if (capsule.pendingAgentProposals > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Section(
              title: 'Proposed changes',
              icon: Icons.rate_review_outlined,
              trailing: TextButton(
                onPressed: () => context.go(
                  '/library?projectId=${Uri.encodeQueryComponent(_text(capsule.project['projectId'], ''))}',
                ),
                child: const Text('Open review queue'),
              ),
              child: Text(
                '${capsule.pendingAgentProposals} agent proposal${capsule.pendingAgentProposals == 1 ? '' : 's'} remain outside accepted truth until human review.',
              ),
            ),
          ),
        _MapSection(
          'Collaboration constraints',
          Icons.shield_outlined,
          capsule.safeConstraints,
        ),
      ],
    );
  }
}

class _AuditTab extends StatelessWidget {
  final ProjectCapsuleSnapshot capsule;

  const _AuditTab(this.capsule);

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const Key('capsule-audit-list'),
      padding: const EdgeInsets.all(16),
      children: [
        _MapSection(
          'Freshness preflight',
          Icons.schedule_outlined,
          _map(capsule.audit['freshness']),
        ),
        _MapSection(
          'Source posture',
          Icons.source_outlined,
          _map(capsule.audit['sources']),
          trailing: TextButton(
            onPressed: () => context.go('/operations'),
            child: const Text('Open Sources & Health'),
          ),
        ),
        _MapSection(
          'Protocol metadata',
          Icons.health_and_safety_outlined,
          _map(capsule.audit['protocolMetadata']),
        ),
        _MapSection(
          'Verification expectations',
          Icons.fact_check_outlined,
          capsule.verification,
        ),
        _MessagesSection(
          'Warnings, errors, and unknowns',
          errors: capsule.errors,
          warnings: capsule.warnings,
          gaps: capsule.gaps,
        ),
        const _Section(
          title: 'Acceptance boundary',
          icon: Icons.person_outline,
          child: Text(
            'Agent output remains a proposal. A human must explicitly accept, reject, or request revision before project truth changes.',
          ),
        ),
      ],
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  final ProjectCapsuleRecommendation recommendation;

  const _RecommendationCard(this.recommendation);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.selectedFill,
        border: Border.all(color: colors.primary),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.near_me_outlined, color: colors.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Recommended next action',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              _Pill('Owner', workloadLabel(recommendation.owner)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            recommendation.action,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(recommendation.rationale),
          const SizedBox(height: 6),
          Text(
            'Moves forward when: ${recommendation.transition}',
            style: TextStyle(color: colors.inactive),
          ),
        ],
      ),
    );
  }
}

class _ActionSection extends StatelessWidget {
  final String title;
  final List<ProjectCapsuleAction> items;

  const _ActionSection(this.title, this.items);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _Section(
        title: '$title (${items.length})',
        icon: Icons.route_outlined,
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              _ActionItem(items[i]),
              if (i != items.length - 1) const Divider(height: 20),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  final ProjectCapsuleAction item;

  const _ActionItem(this.item);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Pill('Owner', workloadLabel(item.owner)),
            _Pill('Suggested', workloadLabel(item.suggestedActor)),
            _Pill('Risk', workloadLabel(item.risk)),
            _Pill('Verify', workloadLabel(item.verificationNeeded)),
          ],
        ),
        const SizedBox(height: 8),
        Text('Why here: ${item.whyHere}'),
        const SizedBox(height: 4),
        Text(
          'Moves forward when: ${item.transition}',
          style: TextStyle(color: colors.inactive),
        ),
      ],
    );
  }
}

class _MapSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final Map<String, Object?> values;
  final Widget? trailing;

  const _MapSection(this.title, this.icon, this.values, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _Section(
        title: title,
        icon: icon,
        trailing: trailing,
        child: values.isEmpty
            ? const Text('Not available.')
            : Column(
                children: [
                  for (final entry in values.entries)
                    _KeyValue(workloadLabel(entry.key), _display(entry.value)),
                ],
              ),
      ),
    );
  }
}

class _RecordsSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Map<String, Object?>> records;
  final String emptyMessage;

  const _RecordsSection(
    this.title,
    this.icon,
    this.records, {
    required this.emptyMessage,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _Section(
        title: title,
        icon: icon,
        child: records.isEmpty
            ? Text(emptyMessage)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < records.length; i++) ...[
                    Text(
                      _text(records[i]['title'], 'Untitled'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (_recordDetail(records[i]) case final detail?) ...[
                      const SizedBox(height: 4),
                      Text(detail, style: TextStyle(color: colors.inactive)),
                    ],
                    if (i != records.length - 1) const Divider(height: 20),
                  ],
                ],
              ),
      ),
    );
  }
}

class _MessagesSection extends StatelessWidget {
  final String title;
  final List<String> errors;
  final List<String> warnings;
  final List<String> gaps;

  const _MessagesSection(
    this.title, {
    required this.errors,
    required this.warnings,
    required this.gaps,
  });

  @override
  Widget build(BuildContext context) {
    final messages = [
      for (final value in errors) ('Error', value, Icons.error_outline),
      for (final value in warnings)
        ('Warning', value, Icons.warning_amber_outlined),
      for (final value in gaps) ('Unknown', value, Icons.help_outline),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      child: _Section(
        title: title,
        icon: Icons.report_outlined,
        child: messages.isEmpty
            ? const Text('No warnings, errors, or known context gaps.')
            : Column(
                children: [
                  for (final message in messages)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(message.$3, size: 18),
                      title: Text(message.$1),
                      subtitle: Text(message.$2),
                    ),
                ],
              ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  const _Section({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  final String label;
  final String value;

  const _KeyValue(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 190,
            child: Text(label, style: TextStyle(color: colors.inactive)),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final String value;

  const _Pill(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceDeep,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('$label: $value', style: const TextStyle(fontSize: 11)),
    );
  }
}

class _MessageState extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MessageState({
    required this.title,
    required this.message,
    required this.icon,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 36),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 14),
                  FilledButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry('$key', item));
}

String _text(Object? value, String fallback) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? fallback : text;
}

String _display(Object? value) {
  if (value == null) return 'Not defined';
  if (value is bool) return value ? 'Yes' : 'No';
  if (value is Iterable) {
    final items = value
        .map((item) => _text(item, ''))
        .where((item) => item.isNotEmpty);
    return items.isEmpty ? 'None' : items.join(', ');
  }
  if (value is Map) {
    if (value.isEmpty) return 'None';
    return value.entries
        .map(
          (entry) =>
              '${workloadLabel('${entry.key}')}: ${_display(entry.value)}',
        )
        .join('\n');
  }
  return _text(value, 'Not defined');
}

String? _recordDetail(Map<String, Object?> record) {
  for (final key in const ['context', 'description', 'desc']) {
    final value = _text(record[key], '');
    if (value.isNotEmpty) return value;
  }
  return null;
}
