import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../db/app_db.dart';
import '../../services/ollama_service.dart';
import '../../services/telegram_service.dart';
import '../../shared/models/app_state.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/contact_picker.dart';

const _bg = Color(0xFF0F1115);
const _panel = Color(0xFF151A22);
const _line = Color(0xFF273044);
const _primary = Color(0xFF79A7FF);
const _text87 = Color(0xDEFFFFFF);
const _text54 = Color(0x8AFFFFFF);
const _text38 = Color(0x61FFFFFF);

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          Container(
            color: _panel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text(
                    'Settings',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: _text87,
                    ),
                  ),
                ),
                TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  indicatorColor: _primary,
                  indicatorSize: TabBarIndicatorSize.label,
                  labelColor: _primary,
                  unselectedLabelColor: _text54,
                  labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(fontSize: 13),
                  dividerColor: _line,
                  tabs: const [
                    Tab(text: 'Integrations'),
                    Tab(text: 'AI Summaries'),
                    Tab(text: 'Activity Log'),
                    Tab(text: 'Export'),
                    Tab(text: 'Workforce'),
                    Tab(text: 'Admin'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _IntegrationsTab(),
                _AiSummaryTab(),
                _ActivityLogTab(),
                _ExportTab(),
                _WorkforceTab(),
                _AdminTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1 — Integrations
// ─────────────────────────────────────────────────────────────────────────────

class _IntegrationsTab extends StatefulWidget {
  const _IntegrationsTab();

  @override
  State<_IntegrationsTab> createState() => _IntegrationsTabState();
}

class _IntegrationsTabState extends State<_IntegrationsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _tgTokenCtrl = TextEditingController();
  final _tgChatCtrl = TextEditingController();
  bool _tgEnabled = false;
  bool _tgTesting = false;
  String? _tgResult;

  final _ollamaHostCtrl = TextEditingController();
  final _ollamaModelCtrl = TextEditingController();
  bool _ollamaTesting = false;
  String? _ollamaResult;
  List<String> _availableModels = [];
  bool _loadingModels = false;

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final state = AppStateScope.of(context);
    final token = await state.getSetting(AppDb.kTelegramBotToken);
    final chatId = await state.getSetting(AppDb.kTelegramChatId);
    final enabled = await state.getSetting(AppDb.kTelegramEnabled);
    final host = await state.getSetting(AppDb.kOllamaHost);
    final model = await state.getSetting(AppDb.kOllamaModel);
    if (mounted) {
      setState(() {
        _tgTokenCtrl.text = token ?? '';
        _tgChatCtrl.text = chatId ?? '';
        _tgEnabled = enabled == '1';
        _ollamaHostCtrl.text = host ?? 'http://localhost:11434';
        _ollamaModelCtrl.text = model ?? 'mistral';
      });
      _fetchModels();
    }
  }

  Future<void> _fetchModels() async {
    final host = _ollamaHostCtrl.text.trim().isEmpty
        ? 'http://localhost:11434'
        : _ollamaHostCtrl.text.trim();
    setState(() => _loadingModels = true);
    final svc = OllamaService(host: host, model: '');
    final models = await svc.getAvailableModels();
    if (!mounted) return;
    String? autoFixed;
    setState(() {
      _loadingModels = false;
      _availableModels = models;
      if (models.isNotEmpty && !models.contains(_ollamaModelCtrl.text.trim())) {
        _ollamaModelCtrl.text = models.first;
        autoFixed = models.first;
      }
    });
    // Persist the auto-corrected model immediately so AI features pick it up
    // without requiring the user to click Save settings.
    if (autoFixed != null) {
      final state = AppStateScope.of(context);
      await state.setSetting(AppDb.kOllamaModel, autoFixed);
    }
  }

  Future<void> _save() async {
    final state = AppStateScope.of(context);
    await Future.wait([
      state.setSetting(
        AppDb.kTelegramBotToken,
        _tgTokenCtrl.text.trim().isEmpty ? null : _tgTokenCtrl.text.trim(),
      ),
      state.setSetting(
        AppDb.kTelegramChatId,
        _tgChatCtrl.text.trim().isEmpty ? null : _tgChatCtrl.text.trim(),
      ),
      state.setSetting(AppDb.kTelegramEnabled, _tgEnabled ? '1' : '0'),
      state.setSetting(
        AppDb.kOllamaHost,
        _ollamaHostCtrl.text.trim().isEmpty
            ? null
            : _ollamaHostCtrl.text.trim(),
      ),
      state.setSetting(
        AppDb.kOllamaModel,
        _ollamaModelCtrl.text.trim().isEmpty
            ? null
            : _ollamaModelCtrl.text.trim(),
      ),
    ]);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Settings saved.')));
    }
  }

  Future<void> _testTelegram() async {
    final token = _tgTokenCtrl.text.trim();
    final chatId = _tgChatCtrl.text.trim();
    if (token.isEmpty || chatId.isEmpty) {
      setState(() => _tgResult = 'Token and Chat ID are required.');
      return;
    }
    setState(() {
      _tgTesting = true;
      _tgResult = null;
    });
    final svc = TelegramService(botToken: token, chatId: chatId);
    final (ok, err) = await svc.testConnection();
    setState(() {
      _tgTesting = false;
      _tgResult = ok
          ? 'Connected. Check your Telegram.'
          : 'Failed: ${err ?? 'Unknown error'}';
    });
  }

  Future<void> _testOllama() async {
    final host = _ollamaHostCtrl.text.trim().isEmpty
        ? 'http://localhost:11434'
        : _ollamaHostCtrl.text.trim();
    final model = _ollamaModelCtrl.text.trim().isEmpty
        ? 'mistral'
        : _ollamaModelCtrl.text.trim();
    setState(() {
      _ollamaTesting = true;
      _ollamaResult = null;
    });
    final svc = OllamaService(host: host, model: model);
    final available = await svc.isAvailable();
    if (!available) {
      setState(() {
        _ollamaTesting = false;
        _ollamaResult = 'Ollama not reachable at $host — is it running?';
      });
      return;
    }
    final modelOk = await svc.isModelAvailable();
    setState(() {
      _ollamaTesting = false;
      _ollamaResult = modelOk
          ? 'Ollama running at $host · model "$model" ready ✓'
          : 'Ollama running but model "$model" not found — run: ollama pull $model';
    });
  }

  @override
  void dispose() {
    _tgTokenCtrl.dispose();
    _tgChatCtrl.dispose();
    _ollamaHostCtrl.dispose();
    _ollamaModelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // ── Telegram ───────────────────────────────────────────────────
        _SectionTitle(
          icon: Icons.send,
          iconColor: const Color(0xFF229ED9),
          title: 'Telegram',
          subtitle: 'Outbound only — sends task list to your phone.',
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          value: _tgEnabled,
          onChanged: (v) => setState(() => _tgEnabled = v),
          title: const Text(
            'Enable Telegram sending',
            style: TextStyle(fontSize: 14),
          ),
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 12),
        _Field(
          ctrl: _tgTokenCtrl,
          label: 'Bot Token',
          hint: '1234567890:ABCdef...',
          helper: 'Get this from @BotFather.',
          obscure: true,
        ),
        const SizedBox(height: 12),
        _Field(
          ctrl: _tgChatCtrl,
          label: 'Chat ID',
          hint: '-100123456789',
          helper: 'Your personal or group chat ID.',
        ),
        const SizedBox(height: 12),
        _TestRow(
          label: 'Test connection',
          icon: Icons.send,
          testing: _tgTesting,
          result: _tgResult,
          onTest: _testTelegram,
        ),
        const SizedBox(height: 28),
        const Divider(color: _line),
        const SizedBox(height: 24),

        // ── Ollama ─────────────────────────────────────────────────────
        _SectionTitle(
          icon: Icons.psychology_outlined,
          iconColor: Colors.deepPurpleAccent,
          title: 'Ollama (local AI)',
          subtitle:
              'Used for summarization and drafts. Output always shown for review.',
        ),
        const SizedBox(height: 14),
        _Field(
          ctrl: _ollamaHostCtrl,
          label: 'Ollama host',
          hint: 'http://localhost:11434',
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _availableModels.isEmpty
                  ? _Field(
                      ctrl: _ollamaModelCtrl,
                      label: 'Model name',
                      hint: 'mistral',
                      helper: _loadingModels
                          ? 'Fetching models from Ollama…'
                          : 'Click refresh to load available models',
                    )
                  : _ModelDropdown(
                      models: _availableModels,
                      selected: _ollamaModelCtrl.text.trim(),
                      onChanged: (v) {
                        if (v != null)
                          setState(() => _ollamaModelCtrl.text = v);
                      },
                    ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 56,
              child: IconButton(
                onPressed: _loadingModels ? null : _fetchModels,
                tooltip: 'Fetch available models from Ollama',
                icon: _loadingModels
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, color: _text54),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _TestRow(
          label: 'Test Ollama',
          icon: Icons.psychology_outlined,
          testing: _ollamaTesting,
          result: _ollamaResult,
          onTest: _testOllama,
        ),
        const SizedBox(height: 28),
        const Divider(color: _line),
        const SizedBox(height: 20),

        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: _bg,
            ),
            child: const Text('Save settings'),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 2 — Activity Log
// ─────────────────────────────────────────────────────────────────────────────

enum _AiSummaryMode { disabled, manual, bulk }

const _summaryModelGlobalValue = '__atlas_global_ollama_model__';

// Tab 2 - AI Summaries

class _AiSummaryTab extends StatefulWidget {
  const _AiSummaryTab();

  @override
  State<_AiSummaryTab> createState() => _AiSummaryTabState();
}

class _AiSummaryTabState extends State<_AiSummaryTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _enabled = false;
  bool _includeLibrary = true;
  bool _allowBulkRefresh = false;
  String? _summaryModel;
  String? _globalModel;
  List<String> _availableSummaryModels = [];
  bool _loadingSummaryModels = false;
  bool _loaded = false;
  bool _saving = false;
  String? _status;

  _AiSummaryMode get _mode {
    if (!_enabled) return _AiSummaryMode.disabled;
    return _allowBulkRefresh ? _AiSummaryMode.bulk : _AiSummaryMode.manual;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final state = AppStateScope.of(context);
    final settings = await state.loadProjectAiSummarySettings();
    final globalModel = await state.getSetting(AppDb.kOllamaModel);
    if (!mounted) return;
    setState(() {
      _enabled = settings.enabled;
      _includeLibrary = settings.includeLibrary;
      _allowBulkRefresh = settings.allowBulkRefresh;
      _summaryModel = settings.model;
      _globalModel = globalModel;
      _availableSummaryModels = [if (settings.model != null) settings.model!];
    });
    await _fetchSummaryModels();
  }

  void _setMode(_AiSummaryMode mode) {
    setState(() {
      _enabled = mode != _AiSummaryMode.disabled;
      _allowBulkRefresh = mode == _AiSummaryMode.bulk;
    });
  }

  Future<void> _fetchSummaryModels() async {
    final state = AppStateScope.of(context);
    final hostSetting = await state.getSetting(AppDb.kOllamaHost);
    final host = hostSetting?.trim().isNotEmpty == true
        ? hostSetting!.trim()
        : 'http://localhost:11434';
    if (mounted) setState(() => _loadingSummaryModels = true);
    final svc = OllamaService(host: host, model: '');
    final models = await svc.getAvailableModels();
    if (!mounted) return;
    final saved = _summaryModel?.trim();
    setState(() {
      _loadingSummaryModels = false;
      _availableSummaryModels = [
        ...models,
        if (saved != null && saved.isNotEmpty && !models.contains(saved)) saved,
      ];
    });
  }

  Future<void> _save() async {
    final state = AppStateScope.of(context);
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      await state.saveProjectAiSummarySettings(
        ProjectAiSummarySettings(
          enabled: _enabled,
          includeLibrary: _includeLibrary,
          allowBulkRefresh: _enabled && _allowBulkRefresh,
          model: _summaryModel,
        ),
      );
      if (!mounted) return;
      setState(() => _status = 'AI summary setup saved.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'AI summary setup failed: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _SectionTitle(
          icon: Icons.auto_awesome_outlined,
          iconColor: _primary,
          title: 'AI summary setup',
          subtitle: 'Project summaries are opt-in, local, and review-first.',
        ),
        const SizedBox(height: 16),
        _WizardStepPanel(
          step: '1',
          title: 'Mode',
          child: Column(
            children: [
              _ModeRadioTile(
                value: _AiSummaryMode.disabled,
                groupValue: _mode,
                onChanged: _setMode,
                title: 'Disabled',
                subtitle: 'Hide project summary controls.',
              ),
              _ModeRadioTile(
                value: _AiSummaryMode.manual,
                groupValue: _mode,
                onChanged: _setMode,
                title: 'Manual review',
                subtitle: 'Show project detail summaries only.',
              ),
              _ModeRadioTile(
                value: _AiSummaryMode.bulk,
                groupValue: _mode,
                onChanged: _setMode,
                title: 'Manual review + bulk refresh',
                subtitle: 'Also show the Projects toolbar refresh action.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _WizardStepPanel(
          step: '2',
          title: 'Model',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SummaryModelDropdown(
                  models: _availableSummaryModels,
                  selected: _summaryModel,
                  globalModel: _globalModel,
                  enabled: _enabled,
                  onChanged: (value) {
                    setState(() {
                      _summaryModel = value == _summaryModelGlobalValue
                          ? null
                          : value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh Ollama models',
                onPressed: _loadingSummaryModels ? null : _fetchSummaryModels,
                icon: _loadingSummaryModels
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, color: _text54),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _WizardStepPanel(
          step: '3',
          title: 'Evidence defaults',
          child: Column(
            children: [
              SwitchListTile(
                value: _includeLibrary,
                onChanged: _enabled
                    ? (value) => setState(() => _includeLibrary = value)
                    : null,
                activeColor: _primary,
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(
                  Icons.library_books_outlined,
                  color: _text54,
                ),
                title: const Text(
                  'Always include Library',
                  style: TextStyle(fontSize: 14, color: _text87),
                ),
                subtitle: const Text(
                  'Use project-linked documents as default summary context.',
                  style: TextStyle(fontSize: 12, color: _text54),
                ),
              ),
              const Divider(color: _line),
              const _GuardrailRow(
                icon: Icons.inventory_2_outlined,
                title: 'Draft evidence packet',
                subtitle: 'New drafts store the prompt packet in input_json.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const _WizardStepPanel(
          step: '4',
          title: 'Review guardrails',
          child: Column(
            children: [
              _GuardrailRow(
                icon: Icons.people_alt_outlined,
                title: 'Recorded people only',
                subtitle: 'Empty people lists are sent as explicit gaps.',
              ),
              Divider(color: _line),
              _GuardrailRow(
                icon: Icons.description_outlined,
                title: 'Known documents only',
                subtitle: 'Relevant documents must come from supplied IDs.',
              ),
              Divider(color: _line),
              _GuardrailRow(
                icon: Icons.rule_outlined,
                title: 'Hard validator',
                subtitle:
                    'Invalid schema, people, docs, and generic actions fail closed.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save setup'),
              style: FilledButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: _bg,
              ),
            ),
            if (_status != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _status!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _status!.contains('failed')
                        ? Colors.redAccent
                        : _primary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _ActivityLogTab extends StatefulWidget {
  const _ActivityLogTab();

  @override
  State<_ActivityLogTab> createState() => _ActivityLogTabState();
}

class _ActivityLogTabState extends State<_ActivityLogTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String _level = 'all';
  String _area = 'all';

  List<EventLogData> _filter(List<EventLogData> rows) => rows.where((e) {
    final levelOk = _level == 'all' || e.level == _level;
    final areaOk = _area == 'all' || e.area == _area;
    return levelOk && areaOk;
  }).toList();

  Future<void> _copyJson(List<EventLogData> rows) async {
    final data = rows
        .map(
          (e) => {
            'id': e.id,
            'timestamp': e.timestamp.toIso8601String(),
            'level': e.level,
            'area': e.area,
            'action': e.action,
            'entity_type': e.entityType,
            'entity_id': e.entityId,
            'input_json': e.inputJson,
            'output_json': e.outputJson,
            'error': e.error,
            'correlation_id': e.correlationId,
          },
        )
        .toList();
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Copied log as JSON.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = AppStateScope.of(context);
    return StreamBuilder<List<EventLogData>>(
      stream: state.watchRecentEvents(),
      builder: (context, snap) {
        final all = snap.data ?? const <EventLogData>[];
        final areas = [
          'all',
          ...({for (final e in all) e.area}.toList()..sort()),
        ];
        final rows = _filter(all);

        return Column(
          children: [
            Container(
              color: _panel,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _MiniDropdown(
                    value: _level,
                    items: ['all', 'debug', 'info', 'warn', 'error']
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text('Level: $v'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _level = v ?? 'all'),
                  ),
                  const SizedBox(width: 8),
                  _MiniDropdown(
                    value: areas.contains(_area) ? _area : 'all',
                    items: areas
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text('Area: $v'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _area = v ?? 'all'),
                  ),
                  const Spacer(),
                  Text(
                    '${rows.length} events',
                    style: const TextStyle(fontSize: 12, color: _text38),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _copyJson(rows),
                    icon: const Icon(Icons.data_object, size: 14),
                    label: const Text('Copy JSON'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _text54,
                      side: const BorderSide(color: _line),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () async {
                      await state.clearEventLog();
                    },
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 14,
                      color: Colors.red,
                    ),
                    label: const Text(
                      'Clear',
                      style: TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _line),
            Expanded(
              child: rows.isEmpty
                  ? const Center(
                      child: Text(
                        'No log events.',
                        style: TextStyle(color: _text38),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final e = rows[i];
                        final color = e.level == 'error'
                            ? Colors.redAccent
                            : e.level == 'warn'
                            ? Colors.orangeAccent
                            : _text54;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: _line),
                          ),
                          child: Material(
                            color: _panel,
                            child: ExpansionTile(
                              tilePadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 0,
                              ),
                              leading: Icon(
                                Icons.circle,
                                size: 8,
                                color: color,
                              ),
                              title: Text(
                                '${e.area}.${e.action}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: _text87,
                                ),
                              ),
                              subtitle: Text(
                                '${e.timestamp.toIso8601String().substring(0, 19)} · ${e.level}'
                                '${e.entityType != null ? ' · ${e.entityType}:${e.entityId ?? ''}' : ''}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: _text38,
                                ),
                              ),
                              childrenPadding: const EdgeInsets.fromLTRB(
                                16,
                                0,
                                16,
                                12,
                              ),
                              children: [
                                if (e.inputJson != null)
                                  SelectableText(
                                    'Input:\n${e.inputJson}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: _text54,
                                    ),
                                  ),
                                if (e.outputJson != null)
                                  SelectableText(
                                    'Output:\n${e.outputJson}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: _text54,
                                    ),
                                  ),
                                if (e.error != null)
                                  SelectableText(
                                    'Error:\n${e.error}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 3 — Export
// ─────────────────────────────────────────────────────────────────────────────

class _ExportTab extends StatefulWidget {
  const _ExportTab();

  @override
  State<_ExportTab> createState() => _ExportTabState();
}

class _ExportTabState extends State<_ExportTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _busy = false;
  String _exportText = '';
  String _status = '';

  Future<void> _generateToday() async {
    final state = AppStateScope.of(context);
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final items = await state.getTodayItems();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = today.add(const Duration(days: 1));
      const months = [
        '',
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
      final buf = StringBuffer(
        '# Today — ${months[now.month]} ${now.day}, ${now.year}\n\n',
      );
      void sec(String header, List<WorkItem> list) {
        if (list.isEmpty) return;
        buf.writeln('## $header');
        for (final i in list) {
          final due = i.dueAt != null
              ? ' — ${i.dueAt!.month}/${i.dueAt!.day}'
              : '';
          buf.writeln('- [ ] ${i.title}$due');
          if (i.blockedReason != null)
            buf.writeln('  BLOCKED: ${i.blockedReason}');
        }
        buf.writeln();
      }

      sec('Doing', items.where((i) => i.status == 'doing').toList());
      sec(
        'Overdue',
        items
            .where(
              (i) =>
                  i.dueAt != null &&
                  i.dueAt!.isBefore(today) &&
                  i.status != 'doing',
            )
            .toList(),
      );
      sec(
        'Due Today',
        items
            .where(
              (i) =>
                  i.dueAt != null &&
                  !i.dueAt!.isBefore(today) &&
                  i.dueAt!.isBefore(tomorrow) &&
                  i.status != 'doing',
            )
            .toList(),
      );
      sec(
        'Phone Queue',
        items.where((i) => i.phoneQueue && i.status != 'doing').toList(),
      );
      if (mounted) setState(() => _exportText = buf.toString().trim());
    } catch (e) {
      if (mounted) setState(() => _status = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateAll() async {
    final state = AppStateScope.of(context);
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final items = await state.getAllActiveWorkItems();
      final now = DateTime.now();
      const months = [
        '',
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
      final buf = StringBuffer(
        '# Project Atlas — ${months[now.month]} ${now.day}, ${now.year}\n\n',
      );
      final groups = <String, List<WorkItem>>{
        'doing': [],
        'next': [],
        'inbox': [],
        'waiting': [],
      };
      for (final i in items) groups[i.status]?.add(i);
      void sec(String header, List<WorkItem> list) {
        if (list.isEmpty) return;
        buf.writeln('## $header');
        for (final i in list) {
          final check = i.completed ? 'x' : ' ';
          final due = i.dueAt != null
              ? ' — due ${i.dueAt!.month}/${i.dueAt!.day}'
              : '';
          final p = i.priority != 'normal'
              ? ' [${i.priority.toUpperCase()}]'
              : '';
          buf.writeln('- [$check] ${i.title}$p$due');
        }
        buf.writeln();
      }

      sec('Doing', groups['doing']!);
      sec('Next', groups['next']!);
      sec('Inbox', groups['inbox']!);
      sec('Waiting', groups['waiting']!);
      if (mounted) setState(() => _exportText = buf.toString().trim());
    } catch (e) {
      if (mounted) setState(() => _status = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _aiSummary() async {
    final state = AppStateScope.of(context);
    setState(() {
      _busy = true;
      _status = 'Asking Ollama...';
    });
    try {
      final result = await state.summarizeToday().timeout(
        const Duration(seconds: 45),
      );
      if (!result.isSuccess) {
        if (mounted)
          setState(
            () => _status =
                'Ollama failed. Is it running at the configured host?',
          );
        return;
      }
      await state.saveDraft(
        kind: result.kind,
        title: result.title,
        body: result.output!,
        inputJson: result.input,
      );
      if (mounted) {
        setState(() {
          _exportText = result.output!;
          _status = 'AI summary saved as a draft for review.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Ollama failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendTelegram() async {
    if (_exportText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Generate a list first, then send.')),
      );
      return;
    }
    final state = AppStateScope.of(context);
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final (ok, err) = await state.sendTodayToTelegram();
      if (mounted)
        setState(
          () => _status = ok
              ? 'Sent to Telegram.'
              : 'Send failed: ${err ?? 'Unknown error'}',
        );
    } catch (e) {
      if (mounted) setState(() => _status = 'Send failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _generateToday,
                icon: const Icon(Icons.today, size: 16),
                label: const Text("Today's list"),
                style: FilledButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: _bg,
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _generateAll,
                icon: const Icon(Icons.list_alt, size: 16),
                label: const Text('All active tasks'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _text54,
                  side: const BorderSide(color: _line),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _aiSummary,
                icon: const Icon(Icons.psychology_outlined, size: 16),
                label: const Text('AI summary'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _text54,
                  side: const BorderSide(color: _line),
                ),
              ),
              FilledButton.icon(
                onPressed: _busy || _exportText.isEmpty ? null : _sendTelegram,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 16),
                label: const Text('Send to Telegram'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF229ED9),
                  foregroundColor: Colors.white,
                ),
              ),
              if (_exportText.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _exportText));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard.')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _text54,
                    side: const BorderSide(color: _line),
                  ),
                ),
            ],
          ),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _status.contains('fail') || _status.contains('failed')
                    ? Colors.red.withAlpha(25)
                    : _primary.withAlpha(25),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _status.contains('fail') || _status.contains('failed')
                      ? Colors.red.withAlpha(80)
                      : _primary.withAlpha(80),
                ),
              ),
              child: Text(
                _status,
                style: TextStyle(
                  fontSize: 12,
                  color: _status.contains('fail') || _status.contains('failed')
                      ? Colors.red
                      : _primary,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const _ProjectBundleExportWizard(),
          const SizedBox(height: 16),
          const Divider(color: _line),
          const SizedBox(height: 8),
          Expanded(
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : _exportText.isEmpty
                ? const Center(
                    child: Text(
                      'Choose an export format above.',
                      style: TextStyle(color: _text38),
                    ),
                  )
                : Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: _panel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _line),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        _exportText,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          color: _text87,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 4 — Workforce
// ─────────────────────────────────────────────────────────────────────────────

enum _ProjectBundlePreset { complete, handoff, audit, cleanGit, custom }

enum _ProjectBundleLogWindow { last7, last30, last90, all }

class _ProjectBundleExportWizard extends StatefulWidget {
  const _ProjectBundleExportWizard();

  @override
  State<_ProjectBundleExportWizard> createState() =>
      _ProjectBundleExportWizardState();
}

class _ProjectBundleExportWizardState
    extends State<_ProjectBundleExportWizard> {
  Future<List<ProjectFull>>? _projectsFuture;
  Future<ProjectBundleExportPreview>? _previewFuture;
  String? _projectId;
  _ProjectBundlePreset _preset = _ProjectBundlePreset.complete;
  _ProjectBundleLogWindow _logWindow = _ProjectBundleLogWindow.last30;
  bool _includeFiles = true;
  bool _includeSummary = true;
  bool _includeLogs = true;
  bool _includeGitArchive = false;
  bool _exporting = false;
  String? _status;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _projectsFuture ??= AppStateScope.of(context).getProjectsFull();
  }

  DateTime? get _eventLogSince {
    final now = DateTime.now();
    return switch (_logWindow) {
      _ProjectBundleLogWindow.last7 => now.subtract(const Duration(days: 7)),
      _ProjectBundleLogWindow.last30 => now.subtract(const Duration(days: 30)),
      _ProjectBundleLogWindow.last90 => now.subtract(const Duration(days: 90)),
      _ProjectBundleLogWindow.all => null,
    };
  }

  void _applyPreset(_ProjectBundlePreset preset) {
    setState(() {
      _preset = preset;
      switch (preset) {
        case _ProjectBundlePreset.complete:
          _includeFiles = true;
          _includeSummary = true;
          _includeLogs = true;
          _includeGitArchive = false;
          _logWindow = _ProjectBundleLogWindow.last30;
        case _ProjectBundlePreset.handoff:
          _includeFiles = false;
          _includeSummary = true;
          _includeLogs = true;
          _includeGitArchive = false;
          _logWindow = _ProjectBundleLogWindow.last30;
        case _ProjectBundlePreset.audit:
          _includeFiles = false;
          _includeSummary = true;
          _includeLogs = true;
          _includeGitArchive = false;
          _logWindow = _ProjectBundleLogWindow.all;
        case _ProjectBundlePreset.cleanGit:
          _includeFiles = false;
          _includeSummary = true;
          _includeLogs = true;
          _includeGitArchive = true;
          _logWindow = _ProjectBundleLogWindow.last30;
        case _ProjectBundlePreset.custom:
          break;
      }
      _status = null;
      _refreshPreview();
    });
  }

  void _refreshPreview() {
    final id = _projectId;
    _previewFuture = id == null
        ? null
        : AppStateScope.of(context).previewProjectBundleExport(
            id,
            includeFiles: _includeFiles,
            includeLatestSummary: _includeSummary,
            includeEventLogs: _includeLogs,
            eventLogSince: _includeLogs ? _eventLogSince : null,
            includeCleanGitArchive: _includeGitArchive,
          );
  }

  void _setProject(String? value) {
    setState(() {
      _projectId = value;
      _status = null;
      _refreshPreview();
    });
  }

  void _setOption(VoidCallback update) {
    setState(() {
      update();
      _preset = _ProjectBundlePreset.custom;
      _status = null;
      _refreshPreview();
    });
  }

  Future<void> _export(List<ProjectFull> projects) async {
    final projectId = _projectId;
    if (projectId == null || _exporting) return;
    final state = AppStateScope.of(context);
    ProjectFull? project;
    for (final candidate in projects) {
      if (candidate.id == projectId) {
        project = candidate;
        break;
      }
    }
    if (project == null) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export project bundle',
      fileName: '${_safeExportStem(project.title)}_project_bundle.zip',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (path == null || path.trim().isEmpty) return;
    final outputPath = path.toLowerCase().endsWith('.zip') ? path : '$path.zip';
    if (!mounted) return;
    setState(() {
      _exporting = true;
      _status = null;
    });
    try {
      await state.exportProjectBundleToZip(
        projectId,
        outputPath,
        includeFiles: _includeFiles,
        includeLatestSummary: _includeSummary,
        includeEventLogs: _includeLogs,
        eventLogSince: _includeLogs ? _eventLogSince : null,
        includeCleanGitArchive: _includeGitArchive,
      );
      if (!mounted) return;
      setState(() => _status = 'Project bundle exported: $outputPath');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Project bundle exported.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Export failed: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _WizardStepPanel(
      step: '1',
      title: 'Project bundle',
      child: FutureBuilder<List<ProjectFull>>(
        future: _projectsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LinearProgressIndicator(minHeight: 2);
          }
          if (snapshot.hasError) {
            return Text(
              'Projects failed to load: ${snapshot.error}',
              style: const TextStyle(color: Colors.orangeAccent),
            );
          }
          final projects = snapshot.data ?? const <ProjectFull>[];
          final selectedValue = projects.any((p) => p.id == _projectId)
              ? _projectId
              : null;
          Widget projectSelector() {
            return DropdownButtonFormField<String>(
              value: selectedValue,
              decoration: const InputDecoration(
                labelText: 'Project',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final project in projects)
                  DropdownMenuItem(
                    value: project.id,
                    child: Text(project.title),
                  ),
              ],
              onChanged: _exporting ? null : _setProject,
            );
          }

          Widget logWindowSelector() {
            return DropdownButtonFormField<String>(
              value: _logWindow.name,
              decoration: const InputDecoration(
                labelText: 'Log window',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'last7', child: Text('Last 7 days')),
                DropdownMenuItem(value: 'last30', child: Text('Last 30 days')),
                DropdownMenuItem(value: 'last90', child: Text('Last 90 days')),
                DropdownMenuItem(value: 'all', child: Text('All logs')),
              ],
              onChanged: !_includeLogs || _exporting
                  ? null
                  : (value) => _setOption(
                      () => _logWindow = _ProjectBundleLogWindow.values
                          .firstWhere(
                            (window) => window.name == value,
                            orElse: () => _ProjectBundleLogWindow.last30,
                          ),
                    ),
            );
          }

          final projectControls = LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    projectSelector(),
                    const SizedBox(height: 10),
                    logWindowSelector(),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: projectSelector()),
                  const SizedBox(width: 10),
                  SizedBox(width: 180, child: logWindowSelector()),
                ],
              );
            },
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _ExportWizardHeading(
                icon: Icons.folder_open,
                title: 'Project',
              ),
              const SizedBox(height: 8),
              projectControls,
              const SizedBox(height: 14),
              const _ExportWizardHeading(icon: Icons.tune, title: 'Preset'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _PresetChip(
                    selected: _preset == _ProjectBundlePreset.complete,
                    icon: Icons.inventory_2_outlined,
                    label: 'Complete',
                    onSelected: _exporting
                        ? null
                        : () => _applyPreset(_ProjectBundlePreset.complete),
                  ),
                  _PresetChip(
                    selected: _preset == _ProjectBundlePreset.handoff,
                    icon: Icons.ios_share_outlined,
                    label: 'Handoff',
                    onSelected: _exporting
                        ? null
                        : () => _applyPreset(_ProjectBundlePreset.handoff),
                  ),
                  _PresetChip(
                    selected: _preset == _ProjectBundlePreset.audit,
                    icon: Icons.manage_search_outlined,
                    label: 'Audit',
                    onSelected: _exporting
                        ? null
                        : () => _applyPreset(_ProjectBundlePreset.audit),
                  ),
                  _PresetChip(
                    selected: _preset == _ProjectBundlePreset.cleanGit,
                    icon: Icons.archive_outlined,
                    label: 'Clean git',
                    onSelected: _exporting
                        ? null
                        : () => _applyPreset(_ProjectBundlePreset.cleanGit),
                  ),
                  if (_preset == _ProjectBundlePreset.custom)
                    _PresetChip(
                      selected: true,
                      icon: Icons.edit_outlined,
                      label: 'Custom',
                      onSelected: () {},
                    ),
                ],
              ),
              const SizedBox(height: 14),
              const _ExportWizardHeading(
                icon: Icons.checklist_outlined,
                title: 'Contents',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ExportCheckbox(
                    value: _includeFiles,
                    label: 'Files',
                    onChanged: _exporting
                        ? null
                        : (value) => _setOption(() => _includeFiles = value),
                  ),
                  _ExportCheckbox(
                    value: _includeSummary,
                    label: 'AI summary',
                    onChanged: _exporting
                        ? null
                        : (value) => _setOption(() => _includeSummary = value),
                  ),
                  _ExportCheckbox(
                    value: _includeLogs,
                    label: 'Project logs',
                    onChanged: _exporting
                        ? null
                        : (value) => _setOption(() => _includeLogs = value),
                  ),
                  _ExportCheckbox(
                    value: _includeGitArchive,
                    label: 'Clean git',
                    onChanged: _exporting
                        ? null
                        : (value) =>
                              _setOption(() => _includeGitArchive = value),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const _ExportWizardHeading(
                icon: Icons.preview_outlined,
                title: 'Preview',
              ),
              const SizedBox(height: 8),
              _ProjectBundlePreview(future: _previewFuture),
              if (_status != null) ...[
                const SizedBox(height: 10),
                Text(
                  _status!,
                  style: TextStyle(
                    color: _status!.startsWith('Export failed')
                        ? Colors.redAccent
                        : _primary,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: selectedValue == null || _exporting
                    ? null
                    : () => _export(projects),
                icon: _exporting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.archive_outlined, size: 16),
                label: Text(_exporting ? 'Exporting' : 'Export ZIP'),
                style: FilledButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: _bg,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ExportWizardHeading extends StatelessWidget {
  final IconData icon;
  final String title;

  const _ExportWizardHeading({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: _text54, size: 17),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: _text87,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback? onSelected;

  const _PresetChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      selected: selected,
      showCheckmark: false,
      avatar: Icon(icon, size: 16, color: selected ? _bg : _text54),
      label: Text(label),
      labelStyle: TextStyle(
        color: selected ? _bg : _text87,
        fontSize: 12,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      selectedColor: _primary,
      backgroundColor: _panel,
      disabledColor: _panel,
      side: BorderSide(color: selected ? _primary : _line),
      onSelected: onSelected == null ? null : (_) => onSelected!(),
    );
  }
}

class _ExportCheckbox extends StatelessWidget {
  final bool value;
  final String label;
  final ValueChanged<bool>? onChanged;

  const _ExportCheckbox({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: CheckboxListTile(
        value: value,
        onChanged: onChanged == null
            ? null
            : (next) => onChanged!(next ?? false),
        title: Text(label),
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }
}

class _ProjectBundlePreview extends StatelessWidget {
  final Future<ProjectBundleExportPreview>? future;

  const _ProjectBundlePreview({required this.future});

  @override
  Widget build(BuildContext context) {
    final previewFuture = future;
    if (previewFuture == null) {
      return const Text(
        'Select a project to preview the export.',
        style: TextStyle(color: _text54, fontSize: 12),
      );
    }
    return FutureBuilder<ProjectBundleExportPreview>(
      future: previewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LinearProgressIndicator(minHeight: 2);
        }
        if (snapshot.hasError) {
          return Text(
            'Preview failed: ${snapshot.error}',
            style: const TextStyle(color: Colors.orangeAccent),
          );
        }
        final preview = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ExportMetric(
                  label: 'Atlas',
                  value: '${preview.atlasRecordCount}',
                ),
                _ExportMetric(label: 'Work', value: '${preview.workItems}'),
                _ExportMetric(
                  label: 'Documents',
                  value: '${preview.documents}',
                ),
                _ExportMetric(label: 'Media', value: '${preview.media}'),
                _ExportMetric(
                  label: 'Files',
                  value: '${preview.copiedFileCount}',
                ),
                _ExportMetric(label: 'Logs', value: '${preview.eventLogs}'),
                _ExportMetric(
                  label: 'Summary',
                  value: '${preview.latestSummaryDrafts}',
                ),
                _ExportMetric(
                  label: 'Git',
                  value: preview.cleanGitArchiveReady ? 'ready' : 'off',
                ),
              ],
            ),
            if (preview.warnings.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final warning in preview.warnings.take(4))
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    warning,
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (preview.warnings.length > 4)
                Text(
                  '+${preview.warnings.length - 4} more warning(s)',
                  style: const TextStyle(color: _text54, fontSize: 12),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _ExportMetric extends StatelessWidget {
  final String label;
  final String value;

  const _ExportMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: _primary.withAlpha(22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _primary.withAlpha(70)),
      ),
      child: Text(
        '$label $value',
        style: const TextStyle(fontSize: 12, color: _text87),
      ),
    );
  }
}

String _safeExportStem(String value) {
  final stem = value
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return stem.isEmpty ? 'project' : stem;
}

class _WorkforceTab extends StatefulWidget {
  const _WorkforceTab();

  @override
  State<_WorkforceTab> createState() => _WorkforceTabState();
}

class _WorkforceTabState extends State<_WorkforceTab> {
  Contact? _selected;
  String? _status;

  Future<String?> _askPath(String title, String hint) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: Text(title),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: 'File path',
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final trimmed = result?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _run(
    String label,
    Future<int> Function(String path) action,
    String hint,
  ) async {
    final path = await _askPath(label, hint);
    if (path == null) return;
    try {
      final count = await action(path);
      if (mounted)
        setState(() => _status = '$label completed: $count contact(s).');
    } catch (e) {
      if (mounted) setState(() => _status = '$label failed: $e');
    }
  }

  Future<void> _ensureContinuity() async {
    final state = AppStateScope.of(context);
    try {
      final result = await state.ensureContactContinuity();
      final owner = await state.db.getContact(result.ownerContactId);
      if (!mounted) return;
      setState(() {
        _selected = owner ?? _selected;
        _status =
            'Continuity setup: ${result.contactsSeeded} contact(s), '
            '${result.projectOwnersUpdated}/${result.projectsConsidered} owner field(s), '
            '${result.projectPeopleAdded} People row(s) added, '
            '${result.duplicateContactsRemoved} duplicate contact(s) removed.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Continuity setup failed: $error');
    }
  }

  Future<void> _delete(Contact contact) async {
    final appState = AppStateScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('Remove contact?'),
        content: Text(
          'Remove ${contact.name}? Existing project people records and work item owner text will remain for audit history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await appState.deleteContact(contact.id);
      if (mounted) {
        setState(() {
          if (_selected?.id == contact.id) _selected = null;
          _status = 'Removed ${contact.name}.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<Contact>>(
      stream: state.watchContacts(),
      builder: (context, snap) {
        final contacts = snap.data ?? const <Contact>[];
        final selected =
            _selected != null && contacts.any((c) => c.id == _selected!.id)
            ? contacts.firstWhere((c) => c.id == _selected!.id)
            : (contacts.isNotEmpty ? contacts.first : null);

        return Row(
          children: [
            SizedBox(
              width: 340,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () async {
                            final c = await showContactEditor(context);
                            if (c != null && mounted)
                              setState(() => _selected = c);
                          },
                          icon: const Icon(Icons.person_add, size: 16),
                          label: const Text('New contact'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _run(
                            'Import JSON',
                            state.importContactsFromJson,
                            r'C:\Users\you\Documents\atlas_contacts.json',
                          ),
                          icon: const Icon(Icons.upload_file, size: 16),
                          label: const Text('Import JSON'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _run(
                            'Export JSON',
                            state.exportContactsToJson,
                            r'C:\Users\you\Documents\atlas_contacts.json',
                          ),
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('Export JSON'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _run(
                            'Export CSV',
                            state.exportContactsToCsv,
                            r'C:\Users\you\Documents\atlas_contacts.csv',
                          ),
                          icon: const Icon(Icons.table_view, size: 16),
                          label: const Text('Export CSV'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _ensureContinuity,
                          icon: const Icon(Icons.verified_user, size: 16),
                          label: const Text('Continuity setup'),
                        ),
                      ],
                    ),
                  ),
                  if (_status != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        _status!,
                        style: const TextStyle(fontSize: 12, color: _primary),
                      ),
                    ),
                  const Divider(height: 1, color: _line),
                  Expanded(
                    child: contacts.isEmpty
                        ? const Center(
                            child: Text(
                              'No contacts yet. Create or import one.',
                              style: TextStyle(color: _text38),
                            ),
                          )
                        : ListView.builder(
                            itemCount: contacts.length,
                            itemBuilder: (context, index) {
                              final contact = contacts[index];
                              return ListTile(
                                selected: selected?.id == contact.id,
                                leading: _InitialsAvatar(contact.name),
                                title: Text(contact.name),
                                subtitle: Text(
                                  [
                                    if ((contact.title ?? '').isNotEmpty)
                                      contact.title!,
                                    if ((contact.email ?? '').isNotEmpty)
                                      contact.email!,
                                  ].join(' - '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () =>
                                    setState(() => _selected = contact),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1, color: _line),
            Expanded(
              child: selected == null
                  ? const Center(
                      child: Text(
                        'Select a contact to view responsibilities.',
                        style: TextStyle(color: _text38),
                      ),
                    )
                  : _ContactDetail(
                      contact: selected,
                      onEdit: () async {
                        final c = await showContactEditor(
                          context,
                          contact: selected,
                        );
                        if (c != null && mounted) setState(() => _selected = c);
                      },
                      onDelete: () => _delete(selected),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _InitialsAvatar extends StatelessWidget {
  final String name;
  const _InitialsAvatar(this.name);

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().substring(0, 1).toUpperCase();
    return CircleAvatar(
      backgroundColor: _primary.withAlpha(35),
      foregroundColor: _primary,
      child: Text(initial),
    );
  }
}

class _ContactDetail extends StatelessWidget {
  final Contact contact;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ContactDetail({
    required this.contact,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return FutureBuilder<ContactResponsibilities>(
      future: state.getContactResponsibilities(contact),
      builder: (context, snap) {
        final responsibilities = snap.data;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                _InitialsAvatar(contact.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        contact.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          if ((contact.title ?? '').isNotEmpty) contact.title!,
                          if ((contact.businessName ?? '').isNotEmpty)
                            contact.businessName!,
                        ].join(' - '),
                        style: const TextStyle(color: _text54),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _InfoLine('Phone', contact.phone),
            _InfoLine('Alternate phone', contact.alternatePhone),
            _InfoLine('Email', contact.email),
            _InfoLine('Website', contact.website),
            _InfoLine('Photo path', contact.photoPath),
            _InfoLine('Notes', contact.notes),
            const Divider(color: _line),
            const Text(
              'Responsibilities',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (responsibilities == null)
              const LinearProgressIndicator()
            else ...[
              _ResponsibilityGroup(
                'Projects owned',
                responsibilities.ownedProjects.map((p) => p.title).toList(),
              ),
              _ResponsibilityGroup(
                'Project roles',
                responsibilities.contributingProjects
                    .map((p) => p.title)
                    .toSet()
                    .toList(),
              ),
              _ResponsibilityGroup(
                'Work items owned',
                responsibilities.workItems.map((w) => w.title).toList(),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String? value;
  const _InfoLine(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: const TextStyle(color: _text38)),
          ),
          Expanded(child: SelectableText(text)),
        ],
      ),
    );
  }
}

class _ResponsibilityGroup extends StatelessWidget {
  final String title;
  final List<String> rows;
  const _ResponsibilityGroup(this.title, this.rows);

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text('$title (${rows.length})'),
      children: rows.isEmpty
          ? const [ListTile(dense: true, title: Text('None yet.'))]
          : rows.map((r) => ListTile(dense: true, title: Text(r))).toList(),
    );
  }
}
// Tab 5 — Admin
// ─────────────────────────────────────────────────────────────────────────────

class _AdminTab extends StatefulWidget {
  const _AdminTab();

  @override
  State<_AdminTab> createState() => _AdminTabState();
}

class _AdminTabState extends State<_AdminTab> {
  String? _status;

  Future<String?> _askPath(String title, String hint) async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: Text(title),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: _text87),
          decoration: InputDecoration(
            labelText: 'File path',
            hintText: hint,
            labelStyle: const TextStyle(color: _text54),
            enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: _line),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: _primary),
            ),
          ),
          autofocus: true,
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Use path'),
          ),
        ],
      ),
    );
    controller.dispose();
    return path?.trim().isEmpty == true ? null : path;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // About
        _SectionTitle(
          icon: Icons.info_outline,
          iconColor: _text38,
          title: 'About',
          subtitle: 'Project Atlas v1.1',
        ),
        const SizedBox(height: 10),
        const Text(
          'Local-first personal project management.\n'
          'Data stored in local SQLite on this machine.\n'
          'No cloud. No telemetry.',
          style: TextStyle(fontSize: 12, color: _text54, height: 1.6),
        ),
        const SizedBox(height: 28),
        const Divider(color: _line),
        const SizedBox(height: 24),

        _SectionTitle(
          icon: Icons.inventory_2_outlined,
          iconColor: _primary,
          title: 'Local data',
          subtitle: 'Backup and inspect your local Atlas files.',
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                final path = await _askPath(
                  'Export backup',
                  r'C:\Users\you\Documents\project_atlas_backup.zip',
                );
                if (path == null) return;
                try {
                  await state.exportOperationalBackupToJson(path);
                  if (mounted) {
                    setState(() => _status = 'Backup exported: $path');
                  }
                } catch (e) {
                  if (mounted) setState(() => _status = 'Backup failed: $e');
                }
              },
              icon: const Icon(Icons.save_alt, size: 16),
              label: const Text('Export backup'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  await state.openAppDataFolder();
                } catch (e) {
                  if (mounted) {
                    setState(() => _status = 'Open app data failed: $e');
                  }
                }
              },
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('Open app data folder'),
            ),
          ],
        ),
        if (_status != null) ...[
          const SizedBox(height: 10),
          SelectableText(
            _status!,
            style: const TextStyle(fontSize: 12, color: _text54),
          ),
        ],
        const SizedBox(height: 28),
        const Divider(color: _line),
        const SizedBox(height: 24),

        // Danger zone
        _SectionTitle(
          icon: Icons.warning_amber_rounded,
          iconColor: Colors.orange,
          title: 'Danger zone',
          subtitle: 'Irreversible operations.',
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: _panel,
                    title: const Text('Clear activity log?'),
                    content: const Text(
                      'All event log entries will be deleted. Cannot be undone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Clear log'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await state.clearEventLog();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Event log cleared.')),
                    );
                  }
                }
              },
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Clear event log'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange,
                side: BorderSide(color: Colors.orange.withAlpha(80)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

class _WizardStepPanel extends StatelessWidget {
  final String step;
  final String title;
  final Widget child;

  const _WizardStepPanel({
    required this.step,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _primary.withAlpha(35),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  step,
                  style: const TextStyle(
                    color: _primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  color: _text87,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ModeRadioTile extends StatelessWidget {
  final _AiSummaryMode value;
  final _AiSummaryMode groupValue;
  final ValueChanged<_AiSummaryMode> onChanged;
  final String title;
  final String subtitle;

  const _ModeRadioTile({
    required this.value,
    required this.groupValue,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return RadioListTile<_AiSummaryMode>(
      value: value,
      groupValue: groupValue,
      onChanged: (mode) {
        if (mode != null) onChanged(mode);
      },
      activeColor: _primary,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontSize: 14, color: _text87)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: _text54),
      ),
    );
  }
}

class _GuardrailRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _GuardrailRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: _text54, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 14, color: _text87)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: _text54),
      ),
      dense: true,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;

  const _SectionTitle({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: _text87,
              ),
            ),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: _text54),
            ),
          ],
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final String? hint;
  final String? helper;
  final bool obscure;

  const _Field({
    required this.ctrl,
    required this.label,
    this.hint,
    this.helper,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      enableSuggestions: !obscure,
      autocorrect: false,
      style: const TextStyle(color: _text87, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        labelStyle: const TextStyle(color: _text54),
        helperStyle: const TextStyle(fontSize: 11, color: _text38),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: _line),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: _primary),
        ),
        filled: true,
        fillColor: _bg,
      ),
    );
  }
}

class _ModelDropdown extends StatelessWidget {
  final List<String> models;
  final String selected;
  final ValueChanged<String?> onChanged;

  const _ModelDropdown({
    required this.models,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final value = models.contains(selected) ? selected : models.first;
    return DropdownButtonFormField<String>(
      value: value,
      items: models
          .map(
            (m) => DropdownMenuItem(
              value: m,
              child: Text(
                m,
                style: const TextStyle(color: _text87, fontSize: 14),
              ),
            ),
          )
          .toList(),
      onChanged: onChanged,
      dropdownColor: _panel,
      decoration: const InputDecoration(
        labelText: 'Model',
        labelStyle: TextStyle(color: _text54),
        helperText: 'Select a model from your local Ollama install',
        helperStyle: TextStyle(fontSize: 11, color: _text38),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _line)),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: _primary),
        ),
        filled: true,
        fillColor: _bg,
      ),
      style: const TextStyle(color: _text87, fontSize: 14),
    );
  }
}

class _SummaryModelDropdown extends StatelessWidget {
  final List<String> models;
  final String? selected;
  final String? globalModel;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  const _SummaryModelDropdown({
    required this.models,
    required this.selected,
    required this.globalModel,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final seen = <String>{};
    final installedModels = <String>[];
    for (final raw in models) {
      final model = raw.trim();
      if (model.isNotEmpty && seen.add(model)) installedModels.add(model);
    }
    final selectedValue =
        selected != null && installedModels.contains(selected!.trim())
        ? selected!.trim()
        : _summaryModelGlobalValue;
    final global = globalModel?.trim();
    final globalLabel = global == null || global.isEmpty
        ? 'Use global model'
        : 'Use global model ($global)';
    final items = [
      DropdownMenuItem(
        value: _summaryModelGlobalValue,
        child: Text(
          globalLabel,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _text87, fontSize: 14),
        ),
      ),
      ...installedModels.map(
        (model) => DropdownMenuItem(
          value: model,
          child: Text(
            model,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _text87, fontSize: 14),
          ),
        ),
      ),
    ];

    return DropdownButtonFormField<String>(
      value: selectedValue,
      items: items,
      isExpanded: true,
      onChanged: enabled ? onChanged : null,
      dropdownColor: _panel,
      decoration: InputDecoration(
        labelText: 'Summary model',
        labelStyle: const TextStyle(color: _text54),
        helperText: installedModels.isEmpty
            ? 'Refresh after Ollama starts to list installed models'
            : 'Used for project summaries only',
        helperStyle: const TextStyle(fontSize: 11, color: _text38),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: _line),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: _primary),
        ),
        filled: true,
        fillColor: _bg,
      ),
      style: const TextStyle(color: _text87, fontSize: 14),
    );
  }
}

class _TestRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool testing;
  final String? result;
  final VoidCallback onTest;

  const _TestRow({
    required this.label,
    required this.icon,
    required this.testing,
    required this.result,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: testing ? null : onTest,
          icon: testing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, size: 16),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: _text54,
            side: const BorderSide(color: _line),
          ),
        ),
        if (result != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              result!,
              style: TextStyle(
                fontSize: 12,
                color:
                    result!.startsWith('Ollama running') ||
                        result!.startsWith('Connected')
                    ? Colors.green
                    : Colors.red,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MiniDropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _MiniDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          style: const TextStyle(color: _text87, fontSize: 12),
          dropdownColor: _panel,
          isDense: true,
          iconSize: 14,
          iconEnabledColor: _text54,
        ),
      ),
    );
  }
}
