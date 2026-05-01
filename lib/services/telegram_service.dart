import 'dart:convert';
import 'package:http/http.dart' as http;

/// Sends messages to Telegram via Bot API.
/// Outbound only — no inbound command handling.
class TelegramService {
  final String botToken;
  final String chatId;

  TelegramService({required this.botToken, required this.chatId});

  /// Returns (success, errorMessage).
  Future<(bool, String?)> sendMessage(String text) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://api.telegram.org/bot$botToken/sendMessage'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'chat_id': chatId,
              'text': text,
              'parse_mode': 'HTML',
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode == 200) return (true, null);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return (false, body['description'] as String? ?? 'HTTP ${res.statusCode}');
    } catch (e) {
      return (false, e.toString());
    }
  }

  Future<(bool, String?)> testConnection() => sendMessage(
        '<b>Project Atlas</b> — connection test ✓\n'
        'Your bot is configured correctly.',
      );

  /// Escapes characters that are special in Telegram HTML mode.
  /// Must be applied to any user-supplied text inserted into the message.
  static String _esc(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String formatTodayList({
    required String date,
    required List<
            ({
              String title,
              String project,
              String stage,
              String? dueDate,
              String priority
            })>
        doingItems,
    required List<
            ({
              String title,
              String project,
              String stage,
              String? dueDate,
              String priority
            })>
        overdueItems,
    required List<
            ({
              String title,
              String project,
              String stage,
              String? dueDate,
              String priority
            })>
        dueTodayItems,
    required List<({String title, String blockedReason})> blockedItems,
    required List<
            ({
              String title,
              String project,
              String stage,
              String priority
            })>
        phoneQueueItems,
  }) {
    final buf = StringBuffer();
    buf.writeln('<b>📋 Project Atlas — ${_esc(date)}</b>');
    buf.writeln();

    void section(String header, List<String> lines) {
      if (lines.isEmpty) return;
      buf.writeln('<b>$header</b>');
      for (final l in lines) {
        buf.writeln(l);
      }
      buf.writeln();
    }

    section(
      '🔄 Doing',
      doingItems.map((t) {
        final due = t.dueDate?.isNotEmpty == true ? ' · due ${_esc(t.dueDate!)}' : '';
        return '[ ] ${_esc(t.title)} — ${_esc(t.project)}$due';
      }).toList(),
    );

    section(
      '🔴 Overdue',
      overdueItems.map((t) {
        final due = t.dueDate?.isNotEmpty == true ? ' (was ${_esc(t.dueDate!)})' : '';
        return '[ ] ${_esc(t.title)}$due — ${_esc(t.project)}';
      }).toList(),
    );

    section(
      '📅 Due Today',
      dueTodayItems.map((t) => '[ ] ${_esc(t.title)} — ${_esc(t.project)}').toList(),
    );

    section(
      '📞 Phone / Follow-up',
      phoneQueueItems.map((t) => '[ ] ${_esc(t.title)} — ${_esc(t.project)}').toList(),
    );

    section(
      '🚫 Blocked',
      blockedItems
          .map((t) => '• ${_esc(t.title)} — ${_esc(t.blockedReason)}')
          .toList(),
    );

    if (doingItems.isEmpty &&
        overdueItems.isEmpty &&
        dueTodayItems.isEmpty &&
        phoneQueueItems.isEmpty &&
        blockedItems.isEmpty) {
      buf.writeln('No urgent items today. ✓');
    }

    return buf.toString().trim();
  }
}
