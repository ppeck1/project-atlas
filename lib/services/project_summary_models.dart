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

    buf.writeln('\n## Work Items');
    if (workItems.isEmpty) {
      buf.writeln('(none recorded)');
    } else {
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

    buf.writeln('\n## People');
    if (people.isEmpty) {
      buf.writeln('(none recorded; do not invent people or assignments)');
    } else {
      for (final p in people) {
        buf.write('- ${p.name}');
        if (p.role != null) buf.write(' (role: ${p.role})');
        if (p.authority != null) buf.write(' [authority: ${p.authority}]');
        buf.writeln();
      }
    }

    buf.writeln('\n## Risks');
    if (risks.isEmpty) {
      buf.writeln('(none recorded)');
    } else {
      for (final r in risks) {
        buf.write('- [${r.severity}] ${r.title}');
        if (r.description != null) buf.write(': ${r.description}');
        buf.writeln();
      }
    }

    buf.writeln('\n## Decisions');
    if (decisions.isEmpty) {
      buf.writeln('(none recorded)');
    } else {
      for (final d in decisions) {
        buf.writeln('- ${d.title}');
        if (d.context != null) buf.writeln('  Context: ${d.context}');
        if (d.decider != null) buf.writeln('  Decided by: ${d.decider}');
      }
    }

    buf.writeln('\n## Library Documents');
    if (documents.isEmpty) {
      buf.writeln('(none supplied; do not cite or invent documents)');
    } else {
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

  ProjectSummaryValidationReport validateAgainst(
    ProjectSummaryContext context,
  ) {
    final issues = <ProjectSummaryValidationIssue>[];
    final documentIds = context.documents.map((doc) => doc.id).toSet();
    final suppliedOwnerNames = _suppliedOwnerNames(context);
    final suppliedOwnerLabels = _suppliedOwnerLabels(context);

    if (goal.where((item) => item.trim().isNotEmpty).isEmpty) {
      issues.add(
        const ProjectSummaryValidationIssue(
          code: 'missing_goal',
          message: 'goal must contain at least one non-empty string.',
        ),
      );
    }
    if (currentState.trim().isEmpty) {
      issues.add(
        const ProjectSummaryValidationIssue(
          code: 'missing_current_state',
          message: 'currentState must be a non-empty string.',
        ),
      );
    }
    if (confidence.trim().isEmpty) {
      issues.add(
        const ProjectSummaryValidationIssue(
          code: 'missing_confidence',
          message: 'confidence must describe evidence quality and gaps.',
        ),
      );
    }
    if (ownership.isEmpty) {
      issues.add(
        const ProjectSummaryValidationIssue(
          code: 'missing_ownership',
          message: 'ownership must be present; use Unassigned when unknown.',
        ),
      );
    }
    for (final owner in ownership) {
      final person = owner.person.trim();
      if (person.isEmpty) {
        issues.add(
          const ProjectSummaryValidationIssue(
            code: 'empty_owner',
            message: 'ownership.person cannot be empty.',
          ),
        );
      } else if (suppliedOwnerNames.isEmpty && person != 'Unassigned') {
        issues.add(
          ProjectSummaryValidationIssue(
            code: 'invented_owner',
            message:
                'ownership.person "$person" is not allowed when no owners or people are supplied; use Unassigned.',
          ),
        );
      } else if (suppliedOwnerNames.isNotEmpty &&
          person != 'Unassigned' &&
          !suppliedOwnerNames.contains(_normalizedName(person))) {
        issues.add(
          ProjectSummaryValidationIssue(
            code: 'invented_owner',
            message:
                'ownership.person "$person" does not match a supplied person or owner (${suppliedOwnerLabels.join(', ')}).',
          ),
        );
      }
    }

    if (context.documents.isNotEmpty && relevantDocuments.isEmpty) {
      issues.add(
        const ProjectSummaryValidationIssue(
          code: 'missing_relevant_documents',
          message:
              'Library Documents were supplied; cite at least one relevant document ID.',
        ),
      );
    }
    for (final doc in relevantDocuments) {
      final id = doc.documentId.trim();
      if (id.isEmpty) {
        issues.add(
          const ProjectSummaryValidationIssue(
            code: 'empty_document_id',
            message: 'relevantDocuments.documentId cannot be empty.',
          ),
        );
      } else if (!documentIds.contains(id)) {
        issues.add(
          ProjectSummaryValidationIssue(
            code: 'invalid_document_id',
            message:
                'relevantDocuments.documentId "$id" was not supplied in Library Documents.',
          ),
        );
      }
    }

    if (nextActions.length > 5) {
      issues.add(
        const ProjectSummaryValidationIssue(
          code: 'too_many_next_actions',
          message: 'nextActions must contain no more than five items.',
        ),
      );
    }
    for (final action in nextActions) {
      final text = action.trim();
      if (text.isEmpty) {
        issues.add(
          const ProjectSummaryValidationIssue(
            code: 'empty_next_action',
            message: 'nextActions cannot contain empty strings.',
          ),
        );
        continue;
      }
      final blockedPhrase = _unsupportedGenericActionPhrase(text, context);
      if (blockedPhrase != null) {
        issues.add(
          ProjectSummaryValidationIssue(
            code: 'unsupported_generic_action',
            message:
                'nextActions contains unsupported generic advice "$blockedPhrase": $text',
          ),
        );
      }
    }

    return ProjectSummaryValidationReport(issues);
  }

  static ProjectSummaryValidationReport validateParsed(
    ProjectSummaryResult? result, {
    required ProjectSummaryContext context,
    String? rawOutput,
  }) {
    if (rawOutput != null && _isModelErrorOutput(rawOutput)) {
      return ProjectSummaryValidationReport([
        ProjectSummaryValidationIssue(code: 'model_error', message: rawOutput),
      ]);
    }
    if (rawOutput == null || rawOutput.trim().isEmpty) {
      return const ProjectSummaryValidationReport([
        ProjectSummaryValidationIssue(
          code: 'empty_output',
          message: 'The model returned no output.',
        ),
      ]);
    }
    if (rawOutput.startsWith('âš  ')) {
      return ProjectSummaryValidationReport([
        ProjectSummaryValidationIssue(code: 'model_error', message: rawOutput),
      ]);
    }
    if (result == null) {
      return const ProjectSummaryValidationReport([
        ProjectSummaryValidationIssue(
          code: 'parse_failed',
          message: 'The model output was not parseable as a JSON object.',
        ),
      ]);
    }
    return result.validateAgainst(context);
  }

  static String _normalizedName(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static Set<String> _suppliedOwnerNames(ProjectSummaryContext context) {
    final names = <String>{};
    void add(String? value) {
      final normalized = _normalizedName(value ?? '');
      if (normalized.isNotEmpty) names.add(normalized);
    }

    add(context.owner);
    for (final item in context.workItems) {
      add(item.owner);
    }
    for (final person in context.people) {
      add(person.name);
    }
    return names;
  }

  static List<String> _suppliedOwnerLabels(ProjectSummaryContext context) {
    final labels = <String>[];
    final seen = <String>{};
    void add(String? value) {
      final label = value?.trim();
      if (label == null || label.isEmpty) return;
      if (seen.add(_normalizedName(label))) labels.add(label);
    }

    add(context.owner);
    for (final item in context.workItems) {
      add(item.owner);
    }
    for (final person in context.people) {
      add(person.name);
    }
    return labels;
  }

  static bool _isModelErrorOutput(String rawOutput) {
    final trimmed = rawOutput.trimLeft();
    final lower = trimmed.toLowerCase();
    return trimmed.startsWith('⚠ ') ||
        trimmed.startsWith('âš  ') ||
        trimmed.startsWith('Ã¢Å¡Â  ') ||
        lower.startsWith('ollama returned http') ||
        lower.startsWith('ollama request failed') ||
        lower.contains('ollama returned http') ||
        lower.contains('ollama request failed');
  }

  static String? _unsupportedGenericActionPhrase(
    String action,
    ProjectSummaryContext context,
  ) {
    final lower = action.toLowerCase();
    final suppliedContext = context.toPromptText().toLowerCase();
    const phrases = [
      'schedule a meeting',
      'communication plan',
      'stakeholder',
      'team member',
      'team members',
      'project manager',
      'specific individuals',
      'assign roles',
      'establish a timeline',
      'development timeline',
      'set up a repository',
      'set up project repository',
      'set up the github repository',
      'set up a github repository',
      'set up development environment',
    ];
    for (final phrase in phrases) {
      if (lower.contains(phrase) && !suppliedContext.contains(phrase)) {
        return phrase;
      }
    }
    return null;
  }
}

class ProjectSummaryValidationIssue {
  final String code;
  final String message;

  const ProjectSummaryValidationIssue({
    required this.code,
    required this.message,
  });

  @override
  String toString() => '$code: $message';
}

class ProjectSummaryValidationReport {
  final List<ProjectSummaryValidationIssue> issues;

  const ProjectSummaryValidationReport(this.issues);

  bool get isValid => issues.isEmpty;
  bool get shouldRetry =>
      issues.isNotEmpty &&
      !issues.any(
        (issue) => issue.code == 'model_error' || issue.code == 'empty_output',
      );

  String toPromptText() => issues.map((issue) => '- $issue').join('\n');
}

// ─────────────────────────────────────────────────────────────────────────────
// Combined outcome returned to the UI
// ─────────────────────────────────────────────────────────────────────────────

class ProjectSummaryOutcome {
  /// The raw Ollama result (for fallback prose display).
  final String? rawOutput;

  /// The exact prompt/evidence packet sent to the model.
  final String? inputText;

  /// Parsed structured result; null if parsing failed or structured call
  /// was not attempted.
  final ProjectSummaryResult? structured;

  /// Validation issues from structured summary generation.
  final List<ProjectSummaryValidationIssue> validationIssues;

  /// Map from documentId → storedPath (may be null) for Explorer actions.
  final Map<String, String?> documentPaths;

  const ProjectSummaryOutcome({
    this.rawOutput,
    this.inputText,
    this.structured,
    this.validationIssues = const [],
    this.documentPaths = const {},
  });

  bool get hasStructured => structured != null;
  bool get hasValidationIssues => validationIssues.isNotEmpty;

  bool get isSuccess {
    if (hasValidationIssues) return false;
    if (hasStructured) return true;
    return rawOutput != null &&
        rawOutput!.trim().isNotEmpty &&
        !rawOutput!.startsWith('⚠ ');
  }
}
