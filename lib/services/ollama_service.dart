import 'dart:convert';
import 'package:http/http.dart' as http;

/// Local LLM assistant via Ollama.
///
/// This service NEVER auto-applies output. All results are returned as strings
/// for the caller to display to the user first. The user must explicitly
/// choose to save or use anything produced here.
class OllamaService {
  final String host;
  final String model;

  OllamaService({
    this.host = 'http://localhost:11434',
    this.model = 'qwen3.5:9b',
  });

  /// Check whether the Ollama server is reachable (does not verify the model).
  Future<bool> isAvailable() async {
    try {
      final res = await http
          .get(Uri.parse('$host/api/tags'))
          .timeout(const Duration(seconds: 4));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Return the names of all models installed in Ollama, sorted alphabetically.
  /// Returns an empty list if Ollama is unreachable.
  Future<List<String>> getAvailableModels() async {
    try {
      final res = await http
          .get(Uri.parse('$host/api/tags'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final models =
          (data['models'] as List? ?? []).cast<Map<String, dynamic>>();
      final names = models
          .map((m) => (m['name'] as String? ?? ''))
          .where((n) => n.isNotEmpty)
          .toList()
        ..sort();
      return names;
    } catch (_) {
      return [];
    }
  }

  /// Check whether [model] is present in the Ollama model list.
  /// Requires [isAvailable()] to return true first.
  Future<bool> isModelAvailable() async {
    try {
      final res = await http
          .get(Uri.parse('$host/api/tags'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final models = (data['models'] as List? ?? []).cast<Map<String, dynamic>>();
      final base = model.toLowerCase().split(':').first;
      return models.any((m) {
        final name = (m['name'] as String? ?? '').toLowerCase();
        return name == model.toLowerCase() || name.startsWith('$base:');
      });
    } catch (_) {
      return false;
    }
  }

  /// Send a chat message and get the response text.
  /// Returns null on error or timeout.
  Future<String?> _chat(String systemPrompt, String userMessage) async {
    try {
      final res = await http
          .post(
            Uri.parse('$host/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'stream': false,
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                {'role': 'user', 'content': userMessage},
              ],
            }),
          )
          .timeout(const Duration(seconds: 90));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return (data['message'] as Map<String, dynamic>?)?['content']
            as String?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Summarize all active work items for a project into a concise status update.
  Future<OllamaResult> summarizeProject({
    required String projectTitle,
    required List<String> activeItems,
    required List<String> blockedItems,
    required List<String> completedRecently,
  }) async {
    const system = '''
You are a project status assistant. Given a list of tasks, write a concise 
executive summary (3–5 sentences) covering: what is in progress, what is 
blocked, and any notable completions. Be direct and specific. No fluff.
''';

    final user =
        '''
Project: $projectTitle

Active tasks:
${activeItems.isEmpty ? '(none)' : activeItems.map((t) => '- $t').join('\n')}

Blocked:
${blockedItems.isEmpty ? '(none)' : blockedItems.map((t) => '- $t').join('\n')}

Recently completed:
${completedRecently.isEmpty ? '(none)' : completedRecently.map((t) => '- $t').join('\n')}

Write the summary now.
''';

    final output = await _chat(system, user);
    return OllamaResult(
      input: user,
      output: output,
      kind: 'project_summary',
      title: 'Project Summary — $projectTitle',
    );
  }

  /// Summarize today's task list into an action-oriented briefing.
  Future<OllamaResult> summarizeToday({
    required List<String> doingItems,
    required List<String> overdueItems,
    required List<String> dueTodayItems,
    required List<String> blockedItems,
  }) async {
    const system = '''
You are a daily planning assistant. Given today's task snapshot, write a 
brief action-oriented daily briefing (4–6 sentences). Focus on: what to 
tackle first, what is at risk, and what needs follow-up. Be concrete.
''';

    final user =
        '''
Doing now:
${doingItems.isEmpty ? '(none)' : doingItems.map((t) => '- $t').join('\n')}

Overdue:
${overdueItems.isEmpty ? '(none)' : overdueItems.map((t) => '- $t').join('\n')}

Due today:
${dueTodayItems.isEmpty ? '(none)' : dueTodayItems.map((t) => '- $t').join('\n')}

Blocked:
${blockedItems.isEmpty ? '(none)' : blockedItems.map((t) => '- $t').join('\n')}

Write the briefing now.
''';

    final output = await _chat(system, user);
    return OllamaResult(
      input: user,
      output: output,
      kind: 'today_summary',
      title: 'Daily Briefing',
    );
  }

  /// Draft an email or message related to a specific task.
  Future<OllamaResult> draftEmail({
    required String taskTitle,
    required String? taskDescription,
    required String? blockedReason,
    required String instruction,
  }) async {
    const system = '''
You are an email drafting assistant. Write professional, concise emails or 
messages. Include a subject line starting with "Subject: ". Be specific and 
action-oriented. Do not be verbose.
''';

    final user =
        '''
Task: $taskTitle
${taskDescription != null ? 'Context: $taskDescription' : ''}
${blockedReason != null ? 'Blocked because: $blockedReason' : ''}

Instruction: $instruction

Draft the email now.
''';

    final output = await _chat(system, user);
    return OllamaResult(
      input: user,
      output: output,
      kind: 'email_draft',
      title: 'Email Draft — $taskTitle',
    );
  }

  /// Read-only advisory analysis for one work item and its linked documents.
  Future<OllamaResult> analyzeWorkItemReadOnly({
    required String title,
    required String? description,
    required String status,
    required String priority,
    required String? blockedReason,
    required List<LinkedDocumentContext> linkedDocuments,
  }) async {
    const system = '''
You are reading a Project Atlas work item and its linked documents.

Do not modify anything.
Do not invent missing facts.
Separate observed facts from interpretation.
Return:
1. Summary
2. Relevant document findings
3. Blockers / ambiguity
4. Suggested next actions
5. Risks
6. Open questions
''';

    final docs = linkedDocuments.isEmpty
        ? '(none)'
        : linkedDocuments
              .map(
                (d) =>
                    'Document: ${d.title}\n${d.text.trim().isEmpty ? '(no extracted text available)' : d.text}',
              )
              .join('\n\n---\n\n');

    final user =
        '''
Work item:
$title
${description ?? ''}
Status: $status
Priority: $priority
Blocked reason: ${blockedReason ?? '(none)'}

Linked documents:
$docs
''';

    final output = await _chat(system, user);
    return OllamaResult(
      input: user,
      output: output,
      kind: 'work_item_analysis',
      title: 'Read-only Work Item Analysis - $title',
    );
  }

  /// Extract structured tasks from a block of messy notes.
  Future<OllamaResult> extractTasksFromNote({
    required String rawNote,
    required String projectTitle,
  }) async {
    const system = '''
You are a task extraction assistant. Given raw notes, extract a clear list 
of actionable tasks. Format each task on its own line starting with "- ".
Include any due dates, owners, or blockers mentioned. Ignore filler text.
''';

    final user =
        '''
Project: $projectTitle

Raw notes:
$rawNote

Extract the actionable tasks now.
''';

    final output = await _chat(system, user);
    return OllamaResult(
      input: user,
      output: output,
      kind: 'task_extract',
      title: 'Extracted Tasks from Notes',
    );
  }
}

class OllamaResult {
  final String input;
  final String? output;
  final String kind;
  final String title;

  const OllamaResult({
    required this.input,
    required this.output,
    required this.kind,
    required this.title,
  });

  bool get isSuccess => output != null && output!.trim().isNotEmpty;
}

class LinkedDocumentContext {
  final String title;
  final String text;

  const LinkedDocumentContext({required this.title, required this.text});
}
