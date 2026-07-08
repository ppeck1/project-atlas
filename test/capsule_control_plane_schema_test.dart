import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Capsule control plane docs contract', () {
    late Map<String, dynamic> schema;
    late Map<String, dynamic> example;

    setUpAll(() {
      schema = _readJson(
        'docs/schemas/capsule_upgrade_work_order_v1.schema.json',
      );
      example = _readJson(
        'docs/examples/capsule_upgrade_work_order_v1.example.json',
      );
    });

    test('schema and example use the same versioned contract', () {
      final properties = _jsonObject(schema['properties']);
      final schemaField = _jsonObject(properties['schema']);

      expect(schema['title'], 'Capsule Upgrade Work Order v1');
      expect(schemaField['const'], 'capsule.upgrade_work_order.v1');
      expect(example['schema'], schemaField['const']);
      _expectRequiredKeys(example, schema);
    });

    test('example includes required nested upgrade-order objects', () {
      final properties = _jsonObject(schema['properties']);

      for (final key in [
        'generatedBy',
        'project',
        'protocol',
        'detection',
        'adoption',
        'policy',
        'upgradePlan',
        'atlasActions',
      ]) {
        _expectRequiredKeys(
          _jsonObject(example[key]),
          _jsonObject(properties[key]),
        );
      }

      expect(_jsonObject(example['detection'])['status'], 'outdated');
      expect(
        _jsonObject(example['adoption'])['status'],
        'upgrade_order_generated',
      );
    });

    test('guardrails prevent silent multi-repo mutation', () {
      final policy = _jsonObject(example['policy']);
      final forbiddenActions = _jsonList(example['forbiddenActions']);

      expect(policy['writePolicy'], 'stage_only_until_user_approved');
      expect(policy['operatorApprovalRequired'], isTrue);
      expect(policy['multiRepoMutationAllowed'], isFalse);
      expect(
        forbiddenActions,
        contains('mutate_other_repository_without_operator_approval'),
      );
      expect(forbiddenActions, contains('mark_adopted_without_evidence'));
      expect(
        forbiddenActions,
        contains('rewrite_capsule_catalog_from_atlas_detection'),
      );
    });

    test('adoption states cover detection through completion outcomes', () {
      final properties = _jsonObject(schema['properties']);
      final adoptionSchema = _jsonObject(properties['adoption']);
      final adoptionProperties = _jsonObject(adoptionSchema['properties']);
      final statusSchema = _jsonObject(adoptionProperties['status']);
      final statuses = _jsonList(statusSchema['enum']);

      expect(statuses, contains('not_detected'));
      expect(statuses, contains('upgrade_order_generated'));
      expect(statuses, contains('operator_approved'));
      expect(statuses, contains('in_progress'));
      expect(statuses, contains('adopted'));
      expect(statuses, contains('blocked'));
      expect(statuses, contains('deferred'));
      expect(statuses, contains('not_applicable'));
      expect(statuses, contains(_jsonObject(example['adoption'])['status']));
    });
  });
}

Map<String, dynamic> _readJson(String path) {
  return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _jsonObject(Object? value) {
  return Map<String, dynamic>.from(value as Map);
}

List<dynamic> _jsonList(Object? value) {
  return List<dynamic>.from(value as List);
}

void _expectRequiredKeys(
  Map<String, dynamic> object,
  Map<String, dynamic> schema,
) {
  for (final key in _jsonList(schema['required']).cast<String>()) {
    expect(object.containsKey(key), isTrue, reason: 'Missing required $key');
  }
}
