import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/project_runtime_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('atlas_runtime_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('imports a matching runtime manifest app as a profile draft', () async {
    final yamlPath = p.join(tempDir.path, 'runtime_manifest.yaml');
    File(yamlPath).writeAsStringSync(r'''
settings:
  health_timeout_seconds: 2
apps:
- name: Project Atlas
  path: C:\Projects\Project_Atlas\project-atlas-main
  start: powershell -NoProfile -ExecutionPolicy Bypass -File launch.ps1
  stop: taskkill /IM project_atlas.exe /F
  tests: C:\Tools\flutter\bin\flutter.bat test
  ports: []
  urls:
  - label: Docs
    url: http://localhost/docs
  health_urls:
  - http://localhost/health
  notes: Flutter Windows desktop app.
  autostart: false
''');

    final draft = await const RuntimeManifestImporter().readProfileForProject(
      projectTitle: 'Project Atlas',
      yamlPath: yamlPath,
    );

    expect(draft, isNotNull);
    expect(draft!.enabled, isTrue);
    expect(
      draft.workingDirectory,
      r'C:\Projects\Project_Atlas\project-atlas-main',
    );
    expect(draft.launchCommand, contains('launch.ps1'));
    expect(draft.testCommands.single, r'C:\Tools\flutter\bin\flutter.bat test');
    expect(draft.urls.single.label, 'Docs');
    expect(draft.healthUrls.single, 'http://localhost/health');
    expect(draft.capsuleSourcePath, defaultProjectProtocolPath);
  });

  test('AppState imports and persists runtime profile data', () async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });
    await db.createProject('atlas', 'Project Atlas', DateTime(2026, 7, 2));

    final yamlPath = p.join(tempDir.path, 'runtime_manifest.yaml');
    File(yamlPath).writeAsStringSync(r'''
apps:
- name: Project Atlas
  path: C:\Projects\Project_Atlas\project-atlas-main
  start: .\launch.ps1
  stop: ''
  tests: flutter test
  ports:
  - 5174
  urls: []
  health_urls: []
  notes: Imported.
  autostart: true
''');

    final profile = await state.importRuntimeProfileFromManifest(
      'atlas',
      yamlPath: yamlPath,
    );
    final saved = await db.getProjectRuntimeProfile('atlas');

    expect(profile, isNotNull);
    expect(saved, isNotNull);
    expect(saved!.enabled, isTrue);
    expect(
      saved.workingDirectory,
      r'C:\Projects\Project_Atlas\project-atlas-main',
    );
    expect(saved.launchCommand, r'.\launch.ps1');
    expect(decodeStringList(saved.testCommandsJson), ['flutter test']);
    expect(decodeIntList(saved.portsJson), [5174]);
    expect(saved.autostart, isTrue);
    expect(saved.capsuleProfile, 'software_project');
  });

  test('AppState saves and loads runtime default settings', () async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    final fallback = await state.loadProjectRuntimeDefaultsSettings();
    expect(fallback.resolvedRuntimeManifestPath, defaultRuntimeManifestPath);
    expect(fallback.capsuleEnabled, isTrue);
    expect(fallback.capsuleMode, 'check');
    expect(fallback.capsuleSourcePath, defaultProjectProtocolPath);
    expect(fallback.capsuleProfile, 'software_project');

    final yamlPath = p.join(tempDir.path, 'configured_runtime.yaml');
    await state.saveProjectRuntimeDefaultsSettings(
      ProjectRuntimeDefaultsSettings(
        runtimeManifestPath: yamlPath,
        capsuleEnabled: false,
        capsuleMode: 'strict_check',
        capsuleSourcePath: r'C:\Examples\project_protocol',
        capsuleProfile: 'public_repo',
      ),
    );

    final loaded = await state.loadProjectRuntimeDefaultsSettings();
    final draft = await state.defaultProjectRuntimeProfileDraft(
      workingDirectory: r'C:\Projects\example',
    );

    expect(loaded.resolvedRuntimeManifestPath, yamlPath);
    expect(loaded.capsuleEnabled, isFalse);
    expect(loaded.capsuleMode, 'strict_check');
    expect(loaded.capsuleSourcePath, r'C:\Examples\project_protocol');
    expect(loaded.capsuleProfile, 'public_repo');
    expect(draft.workingDirectory, r'C:\Projects\example');
    expect(draft.capsuleEnabled, isFalse);
    expect(draft.capsuleMode, 'strict_check');
    expect(draft.capsuleSourcePath, r'C:\Examples\project_protocol');
    expect(draft.capsuleProfile, 'public_repo');
  });

  test('AppState migrates an older runtime manifest path setting', () async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    final yamlPath = p.join(tempDir.path, 'existing_runtime.yaml');
    const previousKey = 'project_runtime_default_previous_yaml_path';
    await db.setMetaString(previousKey, yamlPath);
    await db.setMetaString(
      'projectXruntimeXdefaultXnoiseXyamlXpath',
      p.join(tempDir.path, 'noise.yaml'),
    );

    final loaded = await state.loadProjectRuntimeDefaultsSettings();

    expect(loaded.resolvedRuntimeManifestPath, yamlPath);
    expect(
      await db.getMetaString(AppDb.kProjectRuntimeDefaultManifestPath),
      yamlPath,
    );
    expect(await db.getMetaString(previousKey), yamlPath);
  });

  test('AppState migrates an older manifest path during startup', () async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final yamlPath = p.join(tempDir.path, 'startup_runtime.yaml');
    await db.setMetaString(
      'project_runtime_default_startup_yaml_path',
      yamlPath,
    );
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    String? migrated;
    for (var attempt = 0; attempt < 50 && migrated == null; attempt++) {
      migrated = await db.getMetaString(
        AppDb.kProjectRuntimeDefaultManifestPath,
      );
      if (migrated == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    expect(migrated, yamlPath);
  });

  test('AppState keeps the canonical runtime manifest path', () async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    final canonicalPath = p.join(tempDir.path, 'canonical_runtime.yaml');
    final olderPath = p.join(tempDir.path, 'older_runtime.yaml');
    await db.setMetaString(
      AppDb.kProjectRuntimeDefaultManifestPath,
      canonicalPath,
    );
    await db.setMetaString(
      'project_runtime_default_previous_yaml_path',
      olderPath,
    );

    final loaded = await state.loadProjectRuntimeDefaultsSettings();

    expect(loaded.resolvedRuntimeManifestPath, canonicalPath);
    expect(
      await db.getMetaString(AppDb.kProjectRuntimeDefaultManifestPath),
      canonicalPath,
    );
  });

  test(
    'runtime manifest migration preserves a concurrent canonical save',
    () async {
      final db = AppDb.withExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final olderPath = p.join(tempDir.path, 'older_runtime.yaml');
      final selectedPath = p.join(tempDir.path, 'selected_runtime.yaml');
      await db.setMetaString(
        'project_runtime_default_previous_yaml_path',
        olderPath,
      );

      await Future.wait([
        db.migrateLegacyRuntimeManifestPathIfUnambiguous(),
        db.setMetaString(
          AppDb.kProjectRuntimeDefaultManifestPath,
          selectedPath,
        ),
      ]);

      expect(
        await db.getMetaString(AppDb.kProjectRuntimeDefaultManifestPath),
        selectedPath,
      );
    },
  );

  test('AppState fails closed for ambiguous older manifest paths', () async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final ambiguousPath = p.join(tempDir.path, 'same.yaml');
    await db.setMetaString(
      'project_runtime_default_first_yaml_path',
      ambiguousPath,
    );
    await db.setMetaString(
      'project_runtime_default_second_yaml_path',
      ambiguousPath,
    );
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    final loaded = await state.loadProjectRuntimeDefaultsSettings();

    expect(loaded.runtimeManifestPath, isNull);
    expect(
      await db.getMetaString(AppDb.kProjectRuntimeDefaultManifestPath),
      isNull,
    );
  });

  test(
    'AppState imports runtime profiles from configured manifest defaults',
    () async {
      final db = AppDb.withExecutor(NativeDatabase.memory());
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      addTearDown(() async {
        state.dispose();
        await db.close();
      });
      await db.createProject('atlas', 'Project Atlas', DateTime(2026, 7, 2));

      final yamlPath = p.join(tempDir.path, 'configured_runtime.yaml');
      File(yamlPath).writeAsStringSync(r'''
apps:
- name: Project Atlas
  path: C:\Projects\Project_Atlas\project-atlas-main
  start: .\launch.ps1
  tests:
  - flutter test
  ports:
  - 5174
  urls: []
  health_urls: []
  autostart: false
''');
      await state.saveProjectRuntimeDefaultsSettings(
        ProjectRuntimeDefaultsSettings(
          runtimeManifestPath: yamlPath,
          capsuleEnabled: false,
          capsuleMode: 'strict_check',
          capsuleSourcePath: r'C:\Examples\project_protocol',
          capsuleProfile: 'public_repo',
        ),
      );

      final profile = await state.importRuntimeProfileFromManifest('atlas');
      final saved = await db.getProjectRuntimeProfile('atlas');

      expect(profile, isNotNull);
      expect(saved, isNotNull);
      expect(
        saved!.workingDirectory,
        r'C:\Projects\Project_Atlas\project-atlas-main',
      );
      expect(saved.launchCommand, r'.\launch.ps1');
      expect(decodeStringList(saved.testCommandsJson), ['flutter test']);
      expect(decodeIntList(saved.portsJson), [5174]);
      expect(saved.importSource, yamlPath);
      expect(saved.capsuleEnabled, isFalse);
      expect(saved.capsuleMode, 'strict_check');
      expect(saved.capsuleSourcePath, r'C:\Examples\project_protocol');
      expect(saved.capsuleProfile, 'public_repo');
    },
  );
}
