import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Opens a plaintext SQLite database. Encryption is planned for a future release.
QueryExecutor openEncryptedExecutor() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);

    final dbPath = p.join(dir.path, 'project_atlas.sqlite');

    return NativeDatabase(
      File(dbPath),
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys = ON;');
      },
    );
  });
}
