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

// ── Minimal path_provider mock ──────────────────────────────────────────────

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String base;
  _FakePathProvider(this.base);

  @override
  Future<String?> getApplicationDocumentsPath() async => base;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Mirrors the contract that AppDb.deleteDocument(id) is expected to fulfil:
/// deletes the stored file from disk and removes the DB row plus any
/// associated documentLinks entries.  Used in tests until the method is
/// promoted to AppDb itself.
Future<void> _deleteDocument(AppDb db, String id) async {
  final doc = await (db.select(db.documents)
        ..where((t) => t.id.equals(id)))
      .getSingleOrNull();
  if (doc != null && doc.storedPath != null) {
    final f = File(doc.storedPath!);
    if (f.existsSync()) await f.delete();
  }
  await (db.delete(db.documentLinks)
        ..where((t) => t.documentId.equals(id)))
      .go();
  await (db.delete(db.documents)..where((t) => t.id.equals(id))).go();
}

List<int> _buildDocx(String text) {
  final xml = '''<?xml version="1.0" encoding="UTF-8"?>
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

      await db.importDocumentFromPath(src.path);

      final docs = await db.watchDocuments().first;
      expect(docs.first.extractedText, contains('Document content here'));
    });

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

    test('extractedText is null for PDF (no text extraction for binary types)',
        () async {
      final src = File(p.join(tempDir.path, 'file.pdf'))
        ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46]);
      await db.importDocumentFromPath(src.path);
      final docs = await db.watchDocuments().first;
      expect(docs.first.extractedText, isNull);
    });

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

    test('HTML import: both renderedMarkdown and extractedText are non-null',
        () async {
      final src = File(p.join(tempDir.path, 'both.html'))
        ..writeAsStringSync('<p>Hello</p>');
      await db.importDocumentFromPath(src.path);
      final doc = (await db.watchDocuments().first).first;
      expect(doc.renderedMarkdown, isNotNull);
      expect(doc.extractedText, isNotNull);
    });

    test('EML import stores body only in extractedText', () async {
      const emlContent = '''From: alice@example.com
To: bob@example.com
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
      const emlContent = 'From: a@b.com\nSubject: Test\n\nBody here.';
      final src = File(p.join(tempDir.path, 'msg.eml'))
        ..writeAsStringSync(emlContent);
      await db.importDocumentFromPath(src.path);
      final doc = (await db.watchDocuments().first).first;
      expect(doc.renderedMarkdown, isNull);
    });

    test('file over 10 MB is imported without exception and extractedText is null',
        () async {
      final bigBytes = List.filled(11 * 1024 * 1024, 0x41);
      final src = File(p.join(tempDir.path, 'large.txt'))
        ..writeAsBytesSync(bigBytes);
      await db.importDocumentFromPath(src.path);
      final docs = await db.watchDocuments().first;
      expect(docs, hasLength(1));
      expect(docs.first.extractedText, isNull);
    });
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

      await _deleteDocument(db, doc.id);

      final remaining = await db.watchDocuments().first;
      expect(remaining, isEmpty);
      expect(File(storedPath).existsSync(), isFalse);
    });

    test('deleting a non-existent ID does not throw', () async {
      await expectLater(
        _deleteDocument(db, 'non_existent_id_xyz'),
        completes,
      );
    });

    test('deleteDocument also removes associated documentLinks rows', () async {
      final src = File(p.join(tempDir.path, 'linked.txt'))
        ..writeAsStringSync('Linked doc');
      await db.importDocumentFromPath(src.path);
      final doc = (await db.watchDocuments().first).first;

      await db.into(db.documentLinks).insert(
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

      await _deleteDocument(db, doc.id);

      final linksAfter = await db.select(db.documentLinks).get();
      expect(linksAfter, isEmpty);
    });
  });
}
