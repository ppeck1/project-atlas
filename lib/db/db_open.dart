import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _databasePathOverride = String.fromEnvironment('ATLAS_DATABASE_PATH');

/// Resolves the on-disk Atlas SQLite file without opening it.
///
/// Recovery services use this to create a SQLite online snapshot; callers must
/// never copy the live database file directly because its WAL state may not be
/// reflected in that copy.
Future<File> resolveAtlasDatabaseFile() async {
  final configuredPath = _databasePathOverride.trim();
  return configuredPath.isNotEmpty
      ? File(configuredPath)
      : File(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'project_atlas.sqlite',
          ),
        );
}

/// Opens a plaintext SQLite database. Encryption is planned for a future release.
QueryExecutor openEncryptedExecutor() {
  return LazyDatabase(() async {
    final dbFile = await resolveAtlasDatabaseFile();
    await dbFile.parent.create(recursive: true);

    return NativeDatabase(
      dbFile,
      setup: (rawDb) {
        rawDb.execute('PRAGMA busy_timeout = 30000;');
        rawDb.execute('PRAGMA foreign_keys = ON;');
      },
    );
  });
}
