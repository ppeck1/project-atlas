import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/project_summary_models.dart';

void main() {
  group('ProjectSummaryResult.tryParse', () {
    test('parses valid JSON', () {
      const json = '''
{
  "goal": ["Build a local project manager"],
  "currentState": "In early development.",
  "ownership": [
    {"person": "Paul", "work": ["Architecture", "UI"], "basis": "Owner field"}
  ],
  "relevantDocuments": [
    {"documentId": "doc-1", "title": "Spec", "reason": "Core requirements"}
  ],
  "blockersAndRisks": ["No tests yet"],
  "nextActions": ["Write tests", "Ship v1"],
  "confidence": "High confidence on ownership; missing risk data."
}
''';
      final result = ProjectSummaryResult.tryParse(json);
      expect(result, isNotNull);
      expect(result!.goal, ['Build a local project manager']);
      expect(result.currentState, 'In early development.');
      expect(result.ownership.length, 1);
      expect(result.ownership.first.person, 'Paul');
      expect(result.ownership.first.work, ['Architecture', 'UI']);
      expect(result.ownership.first.basis, 'Owner field');
      expect(result.relevantDocuments.length, 1);
      expect(result.relevantDocuments.first.documentId, 'doc-1');
      expect(result.relevantDocuments.first.title, 'Spec');
      expect(result.blockersAndRisks, ['No tests yet']);
      expect(result.nextActions, ['Write tests', 'Ship v1']);
      expect(result.confidence, contains('High confidence'));
    });

    test('parses JSON wrapped in markdown code fence', () {
      const json =
          '```json\n{"goal":["G"],"currentState":"S","ownership":[],'
          '"relevantDocuments":[],"blockersAndRisks":[],"nextActions":[],"confidence":"C"}\n```';
      final result = ProjectSummaryResult.tryParse(json);
      expect(result, isNotNull);
      expect(result!.goal, ['G']);
    });

    test('parses JSON preceded by <think> block', () {
      const json =
          '<think>Reasoning here...</think>\n'
          '{"goal":["G"],"currentState":"S","ownership":[],'
          '"relevantDocuments":[],"blockersAndRisks":[],"nextActions":[],"confidence":"C"}';
      final result = ProjectSummaryResult.tryParse(json);
      expect(result, isNotNull);
      expect(result!.currentState, 'S');
    });

    test('returns null for invalid JSON', () {
      final result = ProjectSummaryResult.tryParse('not json at all');
      expect(result, isNull);
    });

    test('returns null for empty input', () {
      expect(ProjectSummaryResult.tryParse(null), isNull);
      expect(ProjectSummaryResult.tryParse(''), isNull);
      expect(ProjectSummaryResult.tryParse('   '), isNull);
    });

    test('returns null for error-prefixed Ollama output', () {
      final result = ProjectSummaryResult.tryParse(
        '⚠ Ollama returned HTTP 500',
      );
      expect(result, isNull);
    });

    test('handles missing optional fields gracefully', () {
      const json =
          '{"goal":[],"currentState":"","ownership":[],'
          '"relevantDocuments":[],"blockersAndRisks":[],"nextActions":[],"confidence":""}';
      final result = ProjectSummaryResult.tryParse(json);
      expect(result, isNotNull);
      expect(result!.goal, isEmpty);
      expect(result.ownership, isEmpty);
    });

    test('handles ownership item without basis', () {
      const json = '''
{
  "goal": ["G"],
  "currentState": "S",
  "ownership": [{"person": "Alice", "work": ["Coding"]}],
  "relevantDocuments": [],
  "blockersAndRisks": [],
  "nextActions": [],
  "confidence": "C"
}
''';
      final result = ProjectSummaryResult.tryParse(json);
      expect(result, isNotNull);
      expect(result!.ownership.first.basis, isNull);
    });
  });

  group('ProjectSummaryContext.toPromptText', () {
    test('includes project metadata', () {
      const ctx = ProjectSummaryContext(
        id: 'proj-1',
        title: 'My Project',
        description: 'A great project',
        desiredOutcome: 'Ship v1',
        successCriteria: 'All tests pass',
        status: 'active',
        phase: 'build',
        priority: 'high',
        owner: 'Paul',
        workItems: [],
        people: [],
        risks: [],
        decisions: [],
        documents: [],
      );
      final text = ctx.toPromptText();
      expect(text, contains('My Project'));
      expect(text, contains('A great project'));
      expect(text, contains('Ship v1'));
      expect(text, contains('All tests pass'));
      expect(text, contains('active'));
      expect(text, contains('build'));
      expect(text, contains('Paul'));
    });

    test('includes work items with blocked reason', () {
      const ctx = ProjectSummaryContext(
        id: 'proj-1',
        title: 'T',
        status: 'active',
        workItems: [
          ProjectSummaryContextWorkItem(
            id: 'w1',
            title: 'Fix bug',
            status: 'doing',
            priority: 'urgent',
            blockedReason: 'Waiting on API key',
          ),
        ],
        people: [],
        risks: [],
        decisions: [],
        documents: [],
      );
      final text = ctx.toPromptText();
      expect(text, contains('Fix bug'));
      expect(text, contains('BLOCKED: Waiting on API key'));
      expect(text, contains('urgent'));
    });

    test('includes document excerpt', () {
      const ctx = ProjectSummaryContext(
        id: 'proj-1',
        title: 'T',
        status: 'active',
        workItems: [],
        people: [],
        risks: [],
        decisions: [],
        documents: [
          ProjectSummaryContextDoc(
            id: 'doc-1',
            title: 'Design Doc',
            extension: 'md',
            excerpt: 'The system should do X.',
          ),
        ],
      );
      final text = ctx.toPromptText();
      expect(text, contains('doc-1'));
      expect(text, contains('Design Doc'));
      expect(text, contains('The system should do X.'));
    });
  });

  group('ProjectSummaryOutcome', () {
    test('isSuccess true when structured result is present', () {
      final outcome = ProjectSummaryOutcome(
        structured: ProjectSummaryResult(
          goal: ['G'],
          currentState: 'S',
          ownership: const [],
          relevantDocuments: const [],
          blockersAndRisks: const [],
          nextActions: const [],
          confidence: 'C',
        ),
      );
      expect(outcome.hasStructured, isTrue);
      expect(outcome.isSuccess, isTrue);
    });

    test('isSuccess false when rawOutput is error', () {
      const outcome = ProjectSummaryOutcome(
        rawOutput: '⚠ Ollama request failed: connection refused',
      );
      expect(outcome.hasStructured, isFalse);
      expect(outcome.isSuccess, isFalse);
    });

    test('isSuccess true when rawOutput is prose', () {
      const outcome = ProjectSummaryOutcome(
        rawOutput: 'This project is in build phase.',
      );
      expect(outcome.isSuccess, isTrue);
    });
  });
}
