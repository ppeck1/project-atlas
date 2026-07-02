import 'dart:convert';
import 'package:http/http.dart' as http;
import 'project_summary_models.dart';

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
      final models = (data['models'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      final names =
          models
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
      final models = (data['models'] as List? ?? [])
          .cast<Map<String, dynamic>>();
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
  /// Returns an error string prefixed with "⚠ " on failure so callers can
  /// distinguish a real empty response from a connection/model error.
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
          .timeout(const Duration(seconds: 300));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return (data['message'] as Map<String, dynamic>?)?['content']
            as String?;
      }
      // Surface the actual HTTP error so the UI can show something useful
      final body = res.body.length > 200
          ? res.body.substring(0, 200)
          : res.body;
      return '⚠ Ollama returned HTTP ${res.statusCode} for model "$model" — $body';
    } catch (e) {
      return '⚠ Ollama request failed: $e';
    }
  }

  /// Send a chat message requesting JSON output.
  /// Uses format:"json" and low temperature for consistency.
  Future<String?> _chatStructured(
    String systemPrompt,
    String userMessage,
  ) async {
    try {
      final res = await http
          .post(
            Uri.parse('$host/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'stream': false,
              'format': 'json',
              'options': {'temperature': 0.2},
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                {'role': 'user', 'content': userMessage},
              ],
            }),
          )
          .timeout(const Duration(seconds: 300));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return (data['message'] as Map<String, dynamic>?)?['content']
            as String?;
      }
      final body = res.body.length > 200
          ? res.body.substring(0, 200)
          : res.body;
      return '⚠ Ollama returned HTTP ${res.statusCode} for model "$model" — $body';
    } catch (e) {
      return '⚠ Ollama request failed: $e';
    }
  }

  /// Generate a structured project summary using the supplied context.
  /// Returns an [OllamaResult] whose [output] is raw JSON, plus a parsed
  /// [ProjectSummaryResult] only when parsing and validation succeed.
  Future<
    ({
      OllamaResult result,
      ProjectSummaryResult? parsed,
      ProjectSummaryValidationReport validation,
    })
  >
  summarizeProjectStructured({required ProjectSummaryContext context}) async {
    const system = '''
You are a project status assistant for a local project management app.
Summarize the supplied project context and return ONLY valid JSON.

Rules:
- Use only the data provided. Do not invent people, document IDs, file paths, or work assignments.
- relevantDocuments must only reference document IDs that appear in the supplied Library Documents section.
- If the People section says none recorded, ownership must use "Unassigned" and explain the gap in the basis field.
- Do not recommend meetings, communication plans, timelines, stakeholders, team members, or repository setup unless the supplied context explicitly supports that action.
- If the supplied context is thin, say what is missing instead of filling in generic project-management advice.
- Keep goal to 1-2 concise lines.
- Keep currentState concise (1-2 short paragraphs).
- nextActions should be practical and specific (max 5).
- confidence should describe what was inferred and what data was missing.

Return a JSON object matching this exact schema:
{
  "goal": ["string (1-2 lines describing the project purpose)"],
  "currentState": "string",
  "ownership": [
    {
      "person": "string",
      "work": ["string"],
      "basis": "string (optional, how you determined this)"
    }
  ],
  "relevantDocuments": [
    {
      "documentId": "string (must match an ID from the supplied context)",
      "title": "string",
      "reason": "string (why this document is relevant)"
    }
  ],
  "blockersAndRisks": ["string"],
  "nextActions": ["string"],
  "confidence": "string"
}
''';

    final user = '${context.toPromptText()}\n\nReturn only valid JSON.';

    var finalInput = user;
    var rawOutput = await _chatStructured(system, user);
    var parsed = ProjectSummaryResult.tryParse(rawOutput);
    var validation = ProjectSummaryResult.validateParsed(
      parsed,
      context: context,
      rawOutput: rawOutput,
    );

    if (!validation.isValid && rawOutput != null && validation.shouldRetry) {
      final retryUser =
          '''
$user

The previous response failed validation:
${validation.toPromptText()}

Return ONLY a corrected JSON object matching the requested schema. Do not explain the correction.
''';
      final retryOutput = await _chatStructured(system, retryUser);
      final retryParsed = ProjectSummaryResult.tryParse(retryOutput);
      final retryValidation = ProjectSummaryResult.validateParsed(
        retryParsed,
        context: context,
        rawOutput: retryOutput,
      );
      finalInput = retryUser;
      rawOutput = retryOutput;
      parsed = retryValidation.isValid ? retryParsed : null;
      validation = retryValidation;
    } else if (!validation.isValid) {
      parsed = null;
    }

    final result = OllamaResult(
      input: finalInput,
      output: rawOutput,
      kind: 'project_summary_structured',
      title: 'Project Summary — ${context.title}',
    );
    return (result: result, parsed: parsed, validation: validation);
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

  bool get isSuccess =>
      output != null && output!.trim().isNotEmpty && !output!.startsWith('⚠ ');
}

class LinkedDocumentContext {
  final String title;
  final String text;

  const LinkedDocumentContext({required this.title, required this.text});
}
