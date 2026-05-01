import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../services/ollama_service.dart';
import '../../services/telegram_service.dart';
import '../../shared/models/app_state_scope.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Telegram
  final _tgTokenCtrl = TextEditingController();
  final _tgChatCtrl = TextEditingController();
  bool _tgEnabled = false;
  bool _tgTesting = false;
  String? _tgTestResult;

  // Ollama
  final _ollamaHostCtrl = TextEditingController();
  final _ollamaModelCtrl = TextEditingController();
  bool _ollamaTesting = false;
  String? _ollamaTestResult;

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
    }
  }

  Future<void> _saveAll() async {
    final state = AppStateScope.of(context);
    await Future.wait([
      state.setSetting(AppDb.kTelegramBotToken,
          _tgTokenCtrl.text.trim().isEmpty ? null : _tgTokenCtrl.text.trim()),
      state.setSetting(AppDb.kTelegramChatId,
          _tgChatCtrl.text.trim().isEmpty ? null : _tgChatCtrl.text.trim()),
      state.setSetting(AppDb.kTelegramEnabled, _tgEnabled ? '1' : '0'),
      state.setSetting(AppDb.kOllamaHost,
          _ollamaHostCtrl.text.trim().isEmpty
              ? null
              : _ollamaHostCtrl.text.trim()),
      state.setSetting(AppDb.kOllamaModel,
          _ollamaModelCtrl.text.trim().isEmpty
              ? null
              : _ollamaModelCtrl.text.trim()),
    ]);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved.')),
      );
    }
  }

  Future<void> _testTelegram() async {
    final token = _tgTokenCtrl.text.trim();
    final chatId = _tgChatCtrl.text.trim();
    if (token.isEmpty || chatId.isEmpty) {
      setState(() => _tgTestResult = '✗ Token and Chat ID are required.');
      return;
    }

    setState(() {
      _tgTesting = true;
      _tgTestResult = null;
    });

    final svc = TelegramService(botToken: token, chatId: chatId);
    final (ok, err) = await svc.testConnection();

    setState(() {
      _tgTesting = false;
      _tgTestResult = ok
          ? '✓ Message sent! Check your Telegram.'
          : '✗ Failed: ${err ?? 'Unknown error'}';
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
      _ollamaTestResult = null;
    });

    final svc = OllamaService(host: host, model: model);
    final available = await svc.isAvailable();

    setState(() {
      _ollamaTesting = false;
      _ollamaTestResult = available
          ? '✓ Ollama is running at $host'
          : '✗ Ollama not found at $host — is it running?';
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _saveAll,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Telegram ───────────────────────────────────────────────────────
          _SectionHeader(
            icon: Icons.send,
            iconColor: const Color(0xFF229ED9),
            title: 'Telegram',
            subtitle:
                'Outbound only — sends today\'s task list to your phone.',
          ),
          const SizedBox(height: 12),

          SwitchListTile(
            value: _tgEnabled,
            onChanged: (v) => setState(() => _tgEnabled = v),
            title: const Text('Enable Telegram sending'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _tgTokenCtrl,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Bot Token',
              hintText: '1234567890:ABCdef...',
              border: OutlineInputBorder(),
              helperText:
                  'Get this from @BotFather. Not committed to version control.',
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _tgChatCtrl,
            decoration: const InputDecoration(
              labelText: 'Chat ID',
              hintText: '-100123456789',
              border: OutlineInputBorder(),
              helperText:
                  'Your personal chat ID or group ID.',
            ),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _tgTesting ? null : _testTelegram,
                icon: _tgTesting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 16),
                label: const Text('Test connection'),
              ),
              if (_tgTestResult != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _tgTestResult!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _tgTestResult!.startsWith('✓')
                          ? Colors.green
                          : Colors.red,
                    ),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 20),

          // ── Ollama ─────────────────────────────────────────────────────────
          _SectionHeader(
            icon: Icons.psychology_outlined,
            iconColor: Colors.deepPurple,
            title: 'Ollama (local AI)',
            subtitle:
                'Used for summarization and drafts. Output is always shown for review.',
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _ollamaHostCtrl,
            decoration: const InputDecoration(
              labelText: 'Ollama host',
              hintText: 'http://localhost:11434',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _ollamaModelCtrl,
            decoration: const InputDecoration(
              labelText: 'Model name',
              hintText: 'mistral',
              border: OutlineInputBorder(),
              helperText:
                  'Run: ollama pull mistral  (or llama3, gemma2, etc.)',
            ),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _ollamaTesting ? null : _testOllama,
                icon: _ollamaTesting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.psychology_outlined, size: 16),
                label: const Text('Test Ollama'),
              ),
              if (_ollamaTestResult != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _ollamaTestResult!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _ollamaTestResult!.startsWith('✓')
                          ? Colors.green
                          : Colors.red,
                    ),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 20),

          // ── About ──────────────────────────────────────────────────────────
          _SectionHeader(
            icon: Icons.info_outline,
            iconColor: Colors.white38,
            title: 'About',
            subtitle: 'Project Atlas v1.1',
          ),
          const SizedBox(height: 8),
          const Text(
            'Local-first personal project management.\n'
            'Data stored in encrypted SQLite on this machine.\n'
            'No cloud. No telemetry.',
            style: TextStyle(fontSize: 12, color: Colors.white54, height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;

  const _SectionHeader({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
            Text(subtitle,
                style: const TextStyle(
                    fontSize: 12, color: Colors.white54)),
          ],
        ),
      ],
    );
  }
}
