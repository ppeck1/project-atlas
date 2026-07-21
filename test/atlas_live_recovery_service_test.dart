import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/atlas_full_backup_service.dart';
import 'package:project_atlas/services/atlas_live_recovery_service.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'replaces only disposable Atlas paths after a fresh safety backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'atlas_live_recovery_',
      );
      addTearDown(() => root.delete(recursive: true));
      final live = File(p.join(root.path, 'live', 'project_atlas.sqlite'));
      final documents = Directory(p.join(root.path, 'live', 'atlas_documents'));
      final media = Directory(p.join(root.path, 'live', 'project_media'));
      await live.parent.create(recursive: true);
      await documents.create(recursive: true);
      await media.create(recursive: true);
      _writeDatabase(live, 'Recovered Atlas');
      await File(
        p.join(documents.path, 'brief.txt'),
      ).writeAsString('recovered document');
      await File(
        p.join(media.path, 'image.txt'),
      ).writeAsString('recovered media');

      AtlasFullBackupService backupService() => AtlasFullBackupService(
        sourceDatabase: live,
        appOwnedRoots: {'atlas_documents': documents, 'project_media': media},
        clock: () => DateTime.utc(2026, 7, 21, 9),
        random: Random(11),
      );
      final source = await backupService().createBundle(
        Directory(p.join(root.path, 'source_backups')),
      );

      _writeDatabase(live, 'Mutated live Atlas');
      await File(
        p.join(documents.path, 'brief.txt'),
      ).writeAsString('mutated document');
      await File(
        p.join(media.path, 'image.txt'),
      ).writeAsString('mutated media');
      await File('${live.path}-wal').writeAsString('old wal');
      await File('${live.path}-shm').writeAsString('old shm');
      final plan = AtlasLiveRecoveryPlan(
        planFile: File(p.join(root.path, 'handoff', 'plan.json')),
        sourceBundle: source.bundle,
        safetyBackupRoot: Directory(p.join(root.path, 'safety_backups')),
        executablePath: 'test.exe',
        managedFileCount: 3,
        databaseInventory: null,
      );
      await plan.planFile.parent.create(recursive: true);
      await plan.write();

      final service = AtlasLiveRecoveryService(
        backupService: () async => backupService(),
        paths: () async => AtlasLiveRecoveryPaths(
          database: live,
          documents: documents,
          media: media,
        ),
        delay: (_) async {},
      );
      await service.applyPlan(plan.planFile);

      expect(_readTitle(live), 'Recovered Atlas');
      expect(
        await File(p.join(documents.path, 'brief.txt')).readAsString(),
        'recovered document',
      );
      expect(
        await File(p.join(media.path, 'image.txt')).readAsString(),
        'recovered media',
      );
      expect(await File('${live.path}-wal').exists(), isFalse);
      expect(await File('${live.path}-shm').exists(), isFalse);
      expect(await plan.planFile.exists(), isFalse);
      expect(
        await File(
          p.join(root.path, 'handoff', 'live_recovery_complete.json'),
        ).exists(),
        isTrue,
      );

      final safety = (await Directory(
        p.join(root.path, 'safety_backups'),
      ).list().toList()).whereType<Directory>().single;
      expect((await backupService().validateBundle(safety)).isValid, isTrue);
      final safetyDb = File(
        p.join(safety.path, 'database', 'project_atlas.sqlite'),
      );
      expect(_readTitle(safetyDb), 'Mutated live Atlas');
      final rollback =
          (await Directory(
            p.join(root.path, 'handoff'),
          ).list().toList()).whereType<Directory>().firstWhere(
            (item) => p.basename(item.path).startsWith('rollback-'),
          );
      expect(
        await File(p.join(rollback.path, 'project_atlas.sqlite-wal')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(rollback.path, 'project_atlas.sqlite-shm')).exists(),
        isTrue,
      );
    },
  );
}

void _writeDatabase(File file, String title) {
  final database = sqlite3.open(file.path);
  database.execute(
    'CREATE TABLE IF NOT EXISTS projects (title TEXT NOT NULL);',
  );
  database.execute('DELETE FROM projects;');
  database.execute('INSERT INTO projects VALUES (?);', [title]);
  database.dispose();
}

String _readTitle(File file) {
  final database = sqlite3.open(file.path, mode: OpenMode.readOnly);
  final title =
      database.select('SELECT title FROM projects;').single['title'] as String;
  database.dispose();
  return title;
}
