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

  test(
    'imports a matching Dev Launchpad app as a runtime profile draft',
    () async {
      final yamlPath = p.join(tempDir.path, 'dev_launchpad.yaml');
      File(yamlPath).writeAsStringSync(r'''
settings:
  health_timeout_seconds: 2
apps:
- name: Project Atlas
  path: B:\dev\Project_Atlas\project-atlas-main
  start: powershell -NoProfile -ExecutionPolicy Bypass -File launch.ps1
  stop: taskkill /IM project_atlas.exe /F
  tests: B:\dev\flutter\bin\flutter.bat test
  ports: []
  urls:
  - label: Docs
    url: http://localhost/docs
  health_urls:
  - http://localhost/health
  notes: Flutter Windows desktop app.
  autostart: false
''');

      final draft = await const DevLaunchpadRuntimeImporter()
          .readProfileForProject(
            projectTitle: 'Project Atlas',
            yamlPath: yamlPath,
          );

      expect(draft, isNotNull);
      expect(draft!.enabled, isTrue);
      expect(
        draft.workingDirectory,
        r'B:\dev\Project_Atlas\project-atlas-main',
      );
      expect(draft.launchCommand, contains('launch.ps1'));
      expect(draft.testCommands.single, r'B:\dev\flutter\bin\flutter.bat test');
      expect(draft.urls.single.label, 'Docs');
      expect(draft.healthUrls.single, 'http://localhost/health');
      expect(draft.capsuleSourcePath, defaultProjectOpsCapsulePath);
    },
  );

  test('AppState imports and persists runtime profile data', () async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });
    await db.createProject('atlas', 'Project Atlas', DateTime(2026, 7, 2));

    final yamlPath = p.join(tempDir.path, 'dev_launchpad.yaml');
    File(yamlPath).writeAsStringSync(r'''
apps:
- name: Project Atlas
  path: B:\dev\Project_Atlas\project-atlas-main
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

    final profile = await state.importRuntimeProfileFromDevLaunchpad(
      'atlas',
      yamlPath: yamlPath,
    );
    final saved = await db.getProjectRuntimeProfile('atlas');

    expect(profile, isNotNull);
    expect(saved, isNotNull);
    expect(saved!.enabled, isTrue);
    expect(saved.workingDirectory, r'B:\dev\Project_Atlas\project-atlas-main');
    expect(saved.launchCommand, r'.\launch.ps1');
    expect(decodeStringList(saved.testCommandsJson), ['flutter test']);
    expect(decodeIntList(saved.portsJson), [5174]);
    expect(saved.autostart, isTrue);
    expect(saved.capsuleProfile, 'software_project');
  });
}
