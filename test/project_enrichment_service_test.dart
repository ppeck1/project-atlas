import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/project_enrichment_service.dart';

void main() {
  ProjectEnrichmentFindingDraft draft({
    String severity = 'warning',
    String category = 'registry',
  }) => ProjectEnrichmentFindingDraft(
    severity: severity,
    category: category,
    title: 'Finding title',
  );

  group('ProjectEnrichmentService finding-to-proposal mapping', () {
    test('maps every known category to its proposal type', () {
      const expected = {
        'registry': 'registry_review',
        'library': 'library_import_review',
        'media': 'media_import_review',
        'identity': 'identity_update',
        'people': 'people_role_update',
        'workboard': 'task_update',
        'governance': 'governance_update',
        'repository': 'repository_metadata_review',
      };
      expected.forEach((category, proposalType) {
        expect(
          ProjectEnrichmentService.proposalTypeForFinding(
            draft(category: category),
          ),
          proposalType,
        );
      });
      expect(
        ProjectEnrichmentService.proposalTypeForFinding(
          draft(category: 'something_else'),
        ),
        'enrichment_follow_up',
      );
    });

    test('recommended action is non-empty for all categories', () {
      for (final category in [
        'registry',
        'library',
        'media',
        'identity',
        'people',
        'workboard',
        'governance',
        'repository',
        'unknown',
      ]) {
        expect(
          ProjectEnrichmentService.recommendedActionForFinding(
            draft(category: category),
          ),
          isNotEmpty,
        );
      }
    });

    test('proposal confidence tracks severity', () {
      expect(
        ProjectEnrichmentService.proposalConfidenceForFinding(
          draft(severity: 'error'),
        ),
        85,
      );
      expect(
        ProjectEnrichmentService.proposalConfidenceForFinding(
          draft(severity: 'warning'),
        ),
        75,
      );
      expect(
        ProjectEnrichmentService.proposalConfidenceForFinding(
          draft(severity: 'info'),
        ),
        60,
      );
    });

    test('proposal cap stays at the audited value', () {
      expect(ProjectEnrichmentService.proposalCap, 120);
    });
  });
}
