import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _databasePathOverride = String.fromEnvironment('ATLAS_DATABASE_PATH');

/// Opens a plaintext SQLite database. Encryption is planned for a future release.
QueryExecutor openEncryptedExecutor() {
  return LazyDatabase(() async {
    final configuredPath = _databasePathOverride.trim();
    final dbFile = configuredPath.isNotEmpty
        ? File(configuredPath)
        : File(
            p.join(
              (await getApplicationSupportDirectory()).path,
              'project_atlas.sqlite',
            ),
          );
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
