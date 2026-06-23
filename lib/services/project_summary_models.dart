import 'dart:convert';

// ─────────────────────────────────────────────────────────────────────────────
// Input context fed to the LLM
// ─────────────────────────────────────────────────────────────────────────────

class ProjectSummaryContextWorkItem {
  final String id;
  final String title;
  final String status;
  final String priority;
  final String? owner;
  final String? blockedReason;
  final DateTime? dueAt;

  const ProjectSummaryContextWorkItem({
    required this.id,
    required this.title,
    required this.status,
    required this.priority,
    this.owner,
    this.blockedReason,
    this.dueAt,
  });
}

class ProjectSummaryContextPerson {
  final String id;
  final String name;
  final String? role;
  final String? authority;

  const ProjectSummaryContextPerson({
    required this.id,
    required this.name,
    this.role,
    this.authority,
  });
}

class ProjectSummaryContextRisk {
  final String id;
  final String title;
  final String severity;
  final String? description;

  const ProjectSummaryContextRisk({
    required this.id,
    required this.title,
    required this.severity,
    this.description,
  });
}

class ProjectSummaryContextDecision {
  final String id;
  final String title;
  final String? context;
  final String? decider;

  const ProjectSummaryContextDecision({
    required this.id,
    required this.title,
    this.context,
    this.decider,
  });
}

class ProjectSummaryContextDoc {
  final String id;
  final String title;
  final String? extension;
  final String? excerpt;
  final String? storedPath;
  final bool canOpenInExplorer;

  const ProjectSummaryContextDoc({
    required this.id,
    required this.title,
    this.extension,
    this.excerpt,
    this.storedPath,
    this.canOpenInExplorer = false,
  });
}

class ProjectSummaryContext {
  final String id;
  final String title;
  final String? description;
  final String? desiredOutcome;
  final String? successCriteria;
  final String status;
  final String? phase;
  final String? priority;
  final String? owner;

  final List<ProjectSummaryContextWorkItem> workItems;
  final List<ProjectSummaryContextPerson> people;
  final List<ProjectSummaryContextRisk> risks;
  final List<ProjectSummaryContextDecision> decisions;
  final List<ProjectSummaryContextDoc> documents;

  const ProjectSummaryContext({
    required this.id,
    required this.title,
    this.description,
    this.desiredOutcome,
    this.successCriteria,
    required this.status,
    this.phase,
    this.priority,
    this.owner,
    required this.workItems,
    required this.people,
    required this.risks,
    required this.decisions,
    required this.documents,
  });

  /// Renders context as a structured text block for the LLM prompt.
  String toPromptText() {
    final buf = StringBuffer();
    buf.writeln('## Project: $title');
    buf.writeln('ID: $id');
    buf.writeln('Status: $status');
    if (phase != null) buf.writeln('Phase: $phase');
    if (priority != null) buf.writeln('Priority: $priority');
    if (owner != null) buf.writeln('Owner: $owner');
    if (description != null) buf.writeln('Description: $description');
    if (desiredOutcome != null) buf.writeln('Desired outcome: $desiredOutcome');
    if (successCriteria != null)
      buf.writeln('Success criteria: $successCriteria');

    if (workItems.isNotEmpty) {
      buf.writeln('\n## Work Items');
      for (final item in workItems) {
        buf.write('- [${item.status}] ${item.title}');
        if (item.owner != null) buf.write(' (owner: ${item.owner})');
        if (item.priority != 'normal') buf.write(' [${item.priority}]');
        if (item.dueAt != null) {
          final d = item.dueAt!;
          buf.write(
            ' due: ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
          );
        }
        if (item.blockedReason != null)
          buf.write('\n  BLOCKED: ${item.blockedReason}');
        buf.writeln();
      }
    }

    if (people.isNotEmpty) {
      buf.writeln('\n## People');
      for (final p in people) {
        buf.write('- ${p.name}');
        if (p.role != null) buf.write(' (role: ${p.role})');
        if (p.authority != null) buf.write(' [authority: ${p.authority}]');
        buf.writeln();
      }
    }

    if (risks.isNotEmpty) {
      buf.writeln('\n## Risks');
      for (final r in risks) {
        buf.write('- [${r.severity}] ${r.title}');
        if (r.description != null) buf.write(': ${r.description}');
        buf.writeln();
      }
    }

    if (decisions.isNotEmpty) {
      buf.writeln('\n## Decisions');
      for (final d in decisions) {
        buf.writeln('- ${d.title}');
        if (d.context != null) buf.writeln('  Context: ${d.context}');
        if (d.decider != null) buf.writeln('  Decided by: ${d.decider}');
      }
    }

    if (documents.isNotEmpty) {
      buf.writeln('\n## Library Documents');
      for (final doc in documents) {
        buf.writeln('Document ID: ${doc.id}');
        buf.writeln('Title: ${doc.title}');
        if (doc.extension != null) buf.writeln('Type: .${doc.extension}');
        if (doc.excerpt != null && doc.excerpt!.trim().isNotEmpty) {
          buf.writeln('Excerpt:');
          buf.writeln(doc.excerpt);
        }
        buf.writeln('---');
      }
    }

    return buf.toString();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Structured output from the LLM
// ─────────────────────────────────────────────────────────────────────────────

class ProjectSummaryOwnershipItem {
  final String person;
  final List<String> work;
  final String? basis;

  const ProjectSummaryOwnershipItem({
    required this.person,
    required this.work,
    this.basis,
  });

  factory ProjectSummaryOwnershipItem.fromJson(Map<String, dynamic> j) =>
      ProjectSummaryOwnershipItem(
        person: j['person'] as String? ?? 'Unknown',
        work: (j['work'] as List? ?? []).cast<String>(),
        basis: j['basis'] as String?,
      );
}

class ProjectSummaryDocumentRef {
  final String documentId;
  final String title;
  final String reason;

  const ProjectSummaryDocumentRef({
    required this.documentId,
    required this.title,
    required this.reason,
  });

  factory ProjectSummaryDocumentRef.fromJson(Map<String, dynamic> j) =>
      ProjectSummaryDocumentRef(
        documentId: j['documentId'] as String? ?? '',
        title: j['title'] as String? ?? 'Untitled',
        reason: j['reason'] as String? ?? '',
      );
}

class ProjectSummaryResult {
  final List<String> goal;
  final String currentState;
  final List<ProjectSummaryOwnershipItem> ownership;
  final List<ProjectSummaryDocumentRef> relevantDocuments;
  final List<String> blockersAndRisks;
  final List<String> nextActions;
  final String confidence;

  const ProjectSummaryResult({
    required this.goal,
    required this.currentState,
    required this.ownership,
    required this.relevantDocuments,
    required this.blockersAndRisks,
    required this.nextActions,
    required this.confidence,
  });

  factory ProjectSummaryResult.fromJson(Map<String, dynamic> j) =>
      ProjectSummaryResult(
        goal: (j['goal'] as List? ?? []).cast<String>(),
        currentState: j['currentState'] as String? ?? '',
        ownership: (j['ownership'] as List? ?? [])
            .cast<Map<String, dynamic>>()
            .map(ProjectSummaryOwnershipItem.fromJson)
            .toList(),
        relevantDocuments: (j['relevantDocuments'] as List? ?? [])
            .cast<Map<String, dynamic>>()
            .map(ProjectSummaryDocumentRef.fromJson)
            .toList(),
        blockersAndRisks: (j['blockersAndRisks'] as List? ?? []).cast<String>(),
        nextActions: (j['nextActions'] as List? ?? []).cast<String>(),
        confidence: j['confidence'] as String? ?? '',
      );

  /// Parse from raw JSON string. Returns null on failure.
  static ProjectSummaryResult? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final cleaned = _extractJsonObject(raw);
      if (cleaned == null) return null;
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, dynamic>) {
        return ProjectSummaryResult.fromJson(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Strips `<think>…</think>` blocks, markdown code fences, then extracts
  /// the outermost JSON object.
  static String? _extractJsonObject(String raw) {
    var text = raw;

    // Remove <think>...</think> sections (e.g. qwen reasoning models)
    text = text.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', multiLine: true),
      '',
    );

    // Strip markdown code fences
    text = text.replaceAll(RegExp(r'```json?\s*', multiLine: true), '');
    text = text.replaceAll(RegExp(r'```\s*', multiLine: true), '');

    text = text.trim();

    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) return null;
    return text.substring(start, end + 1);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Combined outcome returned to the UI
// ─────────────────────────────────────────────────────────────────────────────

class ProjectSummaryOutcome {
  /// The raw Ollama result (for fallback prose display).
  final String? rawOutput;

  /// Parsed structured result; null if parsing failed or structured call
  /// was not attempted.
  final ProjectSummaryResult? structured;

  /// Map from documentId → storedPath (may be null) for Explorer actions.
  final Map<String, String?> documentPaths;

  const ProjectSummaryOutcome({
    this.rawOutput,
    this.structured,
    this.documentPaths = const {},
  });

  bool get hasStructured => structured != null;

  bool get isSuccess {
    if (hasStructured) return true;
    return rawOutput != null &&
        rawOutput!.trim().isNotEmpty &&
        !rawOutput!.startsWith('⚠ ');
  }
}
