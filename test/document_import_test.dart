import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/windows_secret_store.dart';
import 'package:project_atlas/shared/models/atlas_operation_status.dart';
import 'package:project_atlas/shared/models/app_state.dart';

// ── Minimal path_provider mock ──────────────────────────────────────────────

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String base;
  _FakePathProvider(this.base);

  @override
  Future<String?> getApplicationDocumentsPath() async => base;

  @override
  Future<String?> getApplicationSupportPath() async => base;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

List<int> _buildDocx(String text) {
  final xml =
      '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>$text</w:t></w:r></w:p></w:body>
</w:document>''';
  final xmlBytes = utf8.encode(xml);
  final archive = Archive();
  archive.addFile(ArchiveFile('word/document.xml', xmlBytes.length, xmlBytes));
  return ZipEncoder().encode(archive)!;
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late Directory tempDir;
  late AppDb db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('atlas_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    db = AppDb.withExecutor(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  group('importDocumentFromPath', () {
    test('copies TXT file into app-owned atlas_documents dir', () async {
      final src = File(p.join(tempDir.path, 'notes.txt'))
        ..writeAsStringSync('Hello from notes');

      await db.importDocumentFromPath(src.path);

      final docs = await db.watchDocuments().first;
      expect(docs, hasLength(1));

      final doc = docs.first;
      expect(doc.storedPath, isNot(equals(src.path)));
      expect(doc.storedPath, contains('atlas_documents'));
      expect(File(doc.storedPath!).existsSync(), isTrue);
    });

    test('populates extractedText for TXT import', () async {
      final src = File(p.join(tempDir.path, 'readme.txt'))
        ..writeAsStringSync('Important notes here');

      await db.importDocumentFromPath(src.path);

      final docs = await db.watchDocuments().first;
      expect(docs.first.extractedText, equals('Important notes here'));
    });

    test('populates extractedText for JSON import', () async {
      final src = File(p.join(tempDir.path, 'data.json'))
        ..writeAsStringSync('{"key": "value"}');

      await db.importDocumentFromPath(src.path);

      final docs = await db.watchDocuments().first;
      expect(docs.first.extractedText, equals('{"key": "value"}'));
    });

    test('populates renderedMarkdown for MD import', () async {
      final src = File(p.join(tempDir.path, 'spec.md'))
        ..writeAsStringSync('# Title\nBody text');

      await db.importDocumentFromPath(src.path);

      final docs = await db.watchDocuments().first;
      expect(docs.first.renderedMarkdown, equals('# Title\nBody text'));
      expect(docs.first.extractedText, isNull);
    });

    test('populates extractedText for DOCX import', () async {
      final docxBytes = _buildDocx('Document content here');
      final src = File(p.join(tempDir.path, 'report.docx'))
        ..writeAsBytesSync(docxBytes);

      final id = await db.importDocumentFromPath(src.path);

      final docs = await db.watchDocuments().first;
      expect(id, docs.first.id);
      expect(docs.first.extractedText, contains('Document content here'));
      expect(docs.first.parseError, isNull);
    });

    test(
      'detailed import preserves the String ID compatibility wrapper',
      () async {
        final src = File(p.join(tempDir.path, 'compatible.html'))
          ..writeAsStringSync('<p>Compatible import</p>');

        final detailed = await db.importDocumentFromPathDetailed(src.path);
        final legacyId = await db.importDocumentFromPath(src.path);

        expect(detailed.documentId, isNotEmpty);
        expect(detailed.warning, isNull);
        expect(legacyId, isA<String>());
        expect(legacyId, isNot(equals(detailed.documentId)));
      },
    );

    test(
      'malformed DOCX is imported with a structured warning and owned file',
      () async {
        final src = File(p.join(tempDir.path, 'malformed.docx'))
          ..writeAsBytesSync([0, 1, 2, 3]);

        final result = await db.importDocumentFromPathDetailed(src.path);
        final docs = await db.watchDocuments().first;
        final doc = docs.single;

        expect(result.documentId, doc.id);
        expect(result.warning?.code, 'invalid_archive');
        expect(doc.status, 'imported');
        expect(doc.extractedText, isNull);
        expect(doc.renderedMarkdown, isNull);
        expect(File(doc.storedPath!).existsSync(), isTrue);
        final warning = jsonDecode(doc.parseError!) as Map<String, dynamic>;
        expect(warning['schema'], 'atlas.document_extraction_warning.v1');
        expect(warning['code'], 'invalid_archive');
        expect(warning['format'], 'docx');
        expect(warning['message'], isNot(contains(src.path)));
      },
    );

    test(
      'oversized HTML is imported without extraction and records its limit',
      () async {
        const maxSourceBytes = 10 * 1024 * 1024;
        final src = File(p.join(tempDir.path, 'oversized.html'))
          ..writeAsBytesSync(List<int>.filled(maxSourceBytes + 1, 0x41));

        final result = await db.importDocumentFromPathDetailed(src.path);
        final doc = (await db.watchDocuments().first).single;

        expect(result.warning?.code, 'source_size_limit');
        expect(doc.status, 'imported');
        expect(doc.extractedText, isNull);
        expect(doc.renderedMarkdown, isNull);
        expect(File(doc.storedPath!).lengthSync(), maxSourceBytes + 1);
        final warning = jsonDecode(doc.parseError!) as Map<String, dynamic>;
        expect(warning['sourceBytes'], maxSourceBytes + 1);
        expect(warning['limitBytes'], maxSourceBytes);
      },
    );

    test(
      'AppState reports warning imports as complete and audits the warning',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);
        final src = File(p.join(tempDir.path, 'warning.docx'))
          ..writeAsBytesSync([0, 1, 2, 3]);

        final result = await state.importDocumentFromPathDetailed(src.path);

        expect(result.warning, isNotNull);
        final operation = state.operationStatuses.singleWhere(
          (item) => item.title == 'Document import',
        );
        expect(operation.state, AtlasOperationState.complete);
        expect(operation.message, contains('text preview unavailable'));
        final events = await db.getRecentEvents();
        expect(
          events.map((event) => event.action),
          containsAll([
            'import_request',
            'import_completed_with_extraction_warning',
          ]),
        );
        final completed = events.firstWhere(
          (event) => event.action == 'import_completed_with_extraction_warning',
        );
        expect(completed.level, 'warn');
        expect(completed.entityId, result.documentId);
        expect(completed.outputJson, contains('invalid_archive'));
      },
    );

    test('throws FileSystemException for missing file', () async {
      expect(
        () => db.importDocumentFromPath('/nonexistent/file.txt'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('records correct extension and title', () async {
      final src = File(p.join(tempDir.path, 'summary.csv'))
        ..writeAsStringSync('a,b,c\n1,2,3');

      await db.importDocumentFromPath(src.path);

      final docs = await db.watchDocuments().first;
      expect(docs.first.extension, equals('csv'));
      expect(docs.first.title, equals('summary.csv'));
    });

    test(
      'stores source metadata display title and extracts Dart code',
      () async {
        await db.createProject(
          'project-doc-source',
          'Project document source',
          DateTime.now(),
        );
        final src = File(p.join(tempDir.path, 'main.dart'))
          ..writeAsStringSync('void main() {\n  print("atlas");\n}\n');

        final id = await db.importDocumentFromPath(
          src.path,
          projectId: 'project-doc-source',
          source: 'local_refresh:lib/main.dart',
          metadataJson: '{"relativePath":"lib/main.dart"}',
          title: 'main.dart',
          displayTitle: 'Application entrypoint',
        );

        final doc = await db.getProjectDocumentBySource(
          'project-doc-source',
          'local_refresh:lib/main.dart',
        );
        expect(doc, isNotNull);
        expect(doc!.id, equals(id));
        expect(doc.title, equals('Application entrypoint'));
        expect(doc.originalFilename, equals('main.dart'));
        expect(doc.source, equals('local_refresh:lib/main.dart'));
        expect(doc.metadataJson, equals('{"relativePath":"lib/main.dart"}'));
        expect(doc.extension, equals('dart'));
        expect(doc.extractedText, contains('void main()'));
      },
    );

    test('moving original file does not affect stored copy', () async {
      final src = File(p.join(tempDir.path, 'orig.txt'))
        ..writeAsStringSync('Stable content');

      await db.importDocumentFromPath(src.path);
      await src.delete();

      final docs = await db.watchDocuments().first;
      expect(File(docs.first.storedPath!).existsSync(), isTrue);
      expect(File(docs.first.storedPath!).readAsStringSync(), 'Stable content');
    });

    test('saves mimeType for known extensions', () async {
      final src = File(p.join(tempDir.path, 'doc.json'))
        ..writeAsStringSync('{}');
      await db.importDocumentFromPath(src.path);
      final docs = await db.watchDocuments().first;
      expect(docs.first.mimeType, equals('application/json'));
    });

    test('saves mimeType for PDF', () async {
      // Write minimal valid PDF header bytes so the file exists
      final src = File(p.join(tempDir.path, 'report.pdf'))
        ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46]); // %PDF
      await db.importDocumentFromPath(src.path);
      final docs = await db.watchDocuments().first;
      expect(docs.first.mimeType, equals('application/pdf'));
      expect(docs.first.storedPath, contains('atlas_documents'));
      expect(File(docs.first.storedPath!).existsSync(), isTrue);
    });

    test('saves mimeType for PNG image', () async {
      // PNG magic bytes
      final src = File(p.join(tempDir.path, 'photo.png'))
        ..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
      await db.importDocumentFromPath(src.path);
      final docs = await db.watchDocuments().first;
      expect(docs.first.mimeType, equals('image/png'));
    });

    test(
      'extractedText is null for PDF (no text extraction for binary types)',
      () async {
        final src = File(p.join(tempDir.path, 'file.pdf'))
          ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46]);
        await db.importDocumentFromPath(src.path);
        final docs = await db.watchDocuments().first;
        expect(docs.first.extractedText, isNull);
      },
    );

    test('HTML import stores raw HTML in renderedMarkdown', () async {
      final src = File(p.join(tempDir.path, 'page.html'))
        ..writeAsStringSync('<h1>Title</h1><p>Body text</p>');
      await db.importDocumentFromPath(src.path);
      final docs = await db.watchDocuments().first;
      expect(docs.first.renderedMarkdown, isNotNull);
      expect(docs.first.renderedMarkdown, contains('<'));
    });

    test('HTML import stores stripped text in extractedText', () async {
      final src = File(p.join(tempDir.path, 'page.html'))
        ..writeAsStringSync('<h1>Title</h1><p>Body text</p>');
      await db.importDocumentFromPath(src.path);
      final docs = await db.watchDocuments().first;
      expect(docs.first.extractedText, isNotNull);
      expect(docs.first.extractedText, isNot(contains('<')));
    });

    test(
      'HTML import: both renderedMarkdown and extractedText are non-null',
      () async {
        final src = File(p.join(tempDir.path, 'both.html'))
          ..writeAsStringSync('<p>Hello</p>');
        await db.importDocumentFromPath(src.path);
        final doc = (await db.watchDocuments().first).first;
        expect(doc.renderedMarkdown, isNotNull);
        expect(doc.extractedText, isNotNull);
      },
    );

    test('EML import stores body only in extractedText', () async {
      const emlContent = '''From: alice@example.invalid
To: bob@example.invalid
Subject: Hello

This is the email body.''';
      final src = File(p.join(tempDir.path, 'message.eml'))
        ..writeAsStringSync(emlContent);
      await db.importDocumentFromPath(src.path);
      final doc = (await db.watchDocuments().first).first;
      expect(doc.extractedText, isNotNull);
      expect(doc.extractedText, isNot(contains('From:')));
      expect(doc.extractedText, isNot(contains('Subject:')));
    });

    test('EML import: renderedMarkdown is null', () async {
      const emlContent =
          'From: sender@example.invalid\nSubject: Test\n\nBody here.';
      final src = File(p.join(tempDir.path, 'msg.eml'))
        ..writeAsStringSync(emlContent);
      await db.importDocumentFromPath(src.path);
      final doc = (await db.watchDocuments().first).first;
      expect(doc.renderedMarkdown, isNull);
    });

    test(
      'file over 10 MB is imported without exception and extractedText is null',
      () async {
        final bigBytes = List.filled(11 * 1024 * 1024, 0x41);
        final src = File(p.join(tempDir.path, 'large.txt'))
          ..writeAsBytesSync(bigBytes);
        await db.importDocumentFromPath(src.path);
        final docs = await db.watchDocuments().first;
        expect(docs, hasLength(1));
        expect(docs.first.extractedText, isNull);
      },
    );
  });

  group('deleteDocument', () {
    test('removes document row and deletes stored file from disk', () async {
      final src = File(p.join(tempDir.path, 'todelete.txt'))
        ..writeAsStringSync('Delete me');
      await db.importDocumentFromPath(src.path);
      final docs = await db.watchDocuments().first;
      expect(docs, hasLength(1));
      final doc = docs.first;
      final storedPath = doc.storedPath!;
      expect(File(storedPath).existsSync(), isTrue);

      await db.deleteDocument(doc.id);

      final remaining = await db.watchDocuments().first;
      expect(remaining, isEmpty);
      expect(File(storedPath).existsSync(), isFalse);
    });

    test('deleting a non-existent ID does not throw', () async {
      await expectLater(db.deleteDocument('non_existent_id_xyz'), completes);
    });

    test('deleteDocument also removes associated documentLinks rows', () async {
      final src = File(p.join(tempDir.path, 'linked.txt'))
        ..writeAsStringSync('Linked doc');
      await db.importDocumentFromPath(src.path);
      final doc = (await db.watchDocuments().first).first;

      await db
          .into(db.documentLinks)
          .insert(
            DocumentLinksCompanion(
              id: const Value('test_link_1'),
              documentId: Value(doc.id),
              entityType: const Value('work_item'),
              entityId: const Value('fake_work_item_id'),
              createdAt: Value(DateTime.now()),
            ),
          );

      final linksBefore = await db.select(db.documentLinks).get();
      expect(linksBefore, hasLength(1));

      await db.deleteDocument(doc.id);

      final linksAfter = await db.select(db.documentLinks).get();
      expect(linksAfter, isEmpty);
    });
  });

  group('soft delete, restore, and purge', () {
    test(
      'softDelete hides doc without touching disk; restore brings it back',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        final src = File(p.join(tempDir.path, 'undoable.txt'))
          ..writeAsStringSync('Undo me');
        await db.importDocumentFromPath(src.path);
        final doc = (await db.watchDocuments().first).single;
        final storedPath = doc.storedPath!;

        await state.softDeleteDocument(doc.id);
        expect(await db.watchDocuments().first, isEmpty);
        expect(await db.documentExists(doc.id), isFalse);
        // Disk copy must remain during the undo window.
        expect(File(storedPath).existsSync(), isTrue);

        await state.restoreDocument(doc.id);
        final restored = await db.watchDocuments().first;
        expect(restored.map((d) => d.id), [doc.id]);
        expect(restored.single.deletedAt, isNull);
      },
    );

    test('soft-deleted docs are hidden from project queries', () async {
      await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));
      final src = File(p.join(tempDir.path, 'proj-doc.txt'))
        ..writeAsStringSync('Project doc');
      final id = await db.importDocumentFromPath(
        src.path,
        projectId: 'project-a',
      );

      await db.softDeleteDocument(id);

      expect(await db.getDocumentsForProject('project-a'), isEmpty);
      expect(await db.watchDocumentsForProject('project-a').first, isEmpty);
      expect(await db.getDocumentPathsForProject('project-a'), isEmpty);
    });

    test(
      'purge with olderThan Duration.zero removes row, links, and file',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        final src = File(p.join(tempDir.path, 'purgeable.txt'))
          ..writeAsStringSync('Purge me');
        final id = await db.importDocumentFromPath(src.path);
        final doc = (await db.watchDocuments().first).single;
        final storedPath = doc.storedPath!;
        await db
            .into(db.documentLinks)
            .insert(
              DocumentLinksCompanion(
                id: const Value('purge_link_1'),
                documentId: Value(id),
                entityType: const Value('work_item'),
                entityId: const Value('fake_work_item_id'),
                createdAt: Value(DateTime.now()),
              ),
            );

        await state.softDeleteDocument(id);
        await state.purgeExpiredDeletedDocuments(olderThan: Duration.zero);

        expect(await db.select(db.documents).get(), isEmpty);
        expect(await db.select(db.documentLinks).get(), isEmpty);
        expect(File(storedPath).existsSync(), isFalse);
      },
    );

    test('purge with default retention keeps a fresh soft-delete', () async {
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      addTearDown(state.dispose);

      final src = File(p.join(tempDir.path, 'recent.txt'))
        ..writeAsStringSync('Too recent to purge');
      final id = await db.importDocumentFromPath(src.path);

      await state.softDeleteDocument(id);
      await state.purgeExpiredDeletedDocuments();

      final rows = await db.select(db.documents).get();
      expect(rows.map((d) => d.id), [id]);
      expect(rows.single.deletedAt, isNotNull);
    });

    test(
      'purge never deletes files outside the app-owned atlas_documents dir',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        final foreign = File(p.join(tempDir.path, 'foreign.txt'))
          ..writeAsStringSync('Not app-owned');
        await db
            .into(db.documents)
            .insert(
              DocumentsCompanion(
                id: const Value('doc-foreign'),
                title: const Value('Foreign'),
                originalFilename: const Value('foreign.txt'),
                storedPath: Value(foreign.path),
                createdAt: Value(DateTime.now()),
                updatedAt: Value(DateTime.now()),
              ),
            );

        await state.softDeleteDocument('doc-foreign');
        await state.purgeExpiredDeletedDocuments(olderThan: Duration.zero);

        expect(await db.select(db.documents).get(), isEmpty);
        expect(foreign.existsSync(), isTrue);
      },
    );
  });

  group('project media attachments', () {
    test(
      'work item media import is visible as project media for Library',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));
        final stage = (await db.getStagesForProject('project-a')).single;
        final workItemId = await db.addWorkItem(
          stageId: stage.id,
          title: 'Review screenshot',
        );
        final src = File(p.join(tempDir.path, 'task-shot.png'))
          ..writeAsBytesSync([1, 2, 3, 4]);

        final mediaId = await state.importWorkItemMediaFromPath(
          workItemId,
          src.path,
        );

        final libraryMedia = await state.watchAllProjectMedia().first;
        final linkedMedia = await state.getMediaForWorkItem(workItemId);
        final imported = libraryMedia.singleWhere((item) => item.id == mediaId);

        expect(imported.projectId, 'project-a');
        expect(imported.mediaType, 'image');
        expect(linkedMedia.map((item) => item.id), [mediaId]);
      },
    );

    test(
      'deleteProjectMedia removes copied media file, links, and row',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));
        final stage = (await db.getStagesForProject('project-a')).single;
        final workItemId = await db.addWorkItem(
          stageId: stage.id,
          title: 'Review screenshot',
        );
        final src = File(p.join(tempDir.path, 'delete-me.png'))
          ..writeAsBytesSync([1, 2, 3, 4]);

        final mediaId = await state.importProjectMediaFromPath(
          'project-a',
          src.path,
        );
        await state.attachProjectMediaToWorkItem(workItemId, mediaId);

        final media = await db.getProjectMediaItem(mediaId);
        expect(media, isNotNull);
        final storedPath = media!.storedPath;
        expect(storedPath, isNot(equals(src.path)));
        expect(storedPath, contains('project_media'));
        expect(File(storedPath).existsSync(), isTrue);
        expect(
          await db.getProjectMediaForEntity(
            entityType: 'work_item',
            entityId: workItemId,
          ),
          hasLength(1),
        );

        await state.deleteProjectMedia(mediaId);

        expect(await db.getProjectMediaItem(mediaId), isNull);
        expect(
          await db.getProjectMediaForEntity(
            entityType: 'work_item',
            entityId: workItemId,
          ),
          isEmpty,
        );
        expect(File(storedPath).existsSync(), isFalse);
      },
    );

    test(
      'deleteProjectMedia does not throw when copied file is gone',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1));
        final src = File(p.join(tempDir.path, 'already-gone.png'))
          ..writeAsBytesSync([1, 2, 3, 4]);

        final mediaId = await state.importProjectMediaFromPath(
          'project-a',
          src.path,
        );
        final media = await db.getProjectMediaItem(mediaId);
        expect(media, isNotNull);
        await File(media!.storedPath).delete();

        await expectLater(state.deleteProjectMedia(mediaId), completes);
        expect(await db.getProjectMediaItem(mediaId), isNull);
      },
    );
  });

  group('sendTodayToTelegram', () {
    test('returns disabled result without creating an outbox send', () async {
      final state = AppState(
        db,
        enableBackgroundSummaryRefresh: false,
        secretStore: MemorySecretStore(),
      );
      addTearDown(state.dispose);

      await state.setSetting(AppDb.kTelegramBotToken, 'token');
      await state.setSetting(AppDb.kTelegramChatId, 'chat');

      final (ok, err) = await state.sendTodayToTelegram();

      expect(ok, isFalse);
      expect(err, contains('disabled'));
      expect(await db.watchOutboxMessages().first, isEmpty);
    });
  });

  group('protected integration settings', () {
    test(
      'migrates a legacy Telegram token out of AppMeta on first read',
      () async {
        final secrets = MemorySecretStore();
        final state = AppState(
          db,
          enableBackgroundSummaryRefresh: false,
          secretStore: secrets,
        );
        addTearDown(state.dispose);
        await db.setMetaString(AppDb.kTelegramBotToken, 'legacy-token');

        expect(await state.getSetting(AppDb.kTelegramBotToken), 'legacy-token');
        expect(secrets.values[AppDb.kTelegramBotToken], 'legacy-token');
        expect(await db.getMetaString(AppDb.kTelegramBotToken), isNull);
      },
    );

    test('writes and clears Telegram tokens outside AppMeta', () async {
      final secrets = MemorySecretStore();
      final state = AppState(
        db,
        enableBackgroundSummaryRefresh: false,
        secretStore: secrets,
      );
      addTearDown(state.dispose);

      await state.setSetting(AppDb.kTelegramBotToken, 'new-token');
      expect(secrets.values[AppDb.kTelegramBotToken], 'new-token');
      expect(await db.getMetaString(AppDb.kTelegramBotToken), isNull);
      await state.setSetting(AppDb.kTelegramBotToken, null);
      expect(secrets.values, isEmpty);
    });
  });

  group('exportPortableDataArchive', () {
    test('ZIP contains portable export JSON and a document entry', () async {
      final src = File(p.join(tempDir.path, 'spec.txt'))
        ..writeAsStringSync('Backup test content');
      await db.importDocumentFromPath(src.path);

      final state = AppState(db);
      addTearDown(state.dispose);

      final zipPath = p.join(tempDir.path, 'backup.zip');
      await state.exportPortableDataArchive(zipPath);

      final zipBytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final entryNames = archive.map((e) => e.name).toSet();

      expect(entryNames, contains('portable_export.json'));
      expect(entryNames, anyElement(startsWith('documents/')));

      final jsonEntry = archive.findFile('portable_export.json')!;
      final payload =
          jsonDecode(utf8.decode(jsonEntry.content as List<int>))
              as Map<String, dynamic>;
      expect(payload.containsKey('documents'), isTrue);
      expect(payload.containsKey('projects'), isTrue);
      expect(payload['schema'], 'project_atlas_portable_export_v1');
    });
  });
}
