import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/document_extractor.dart';

// Builds a minimal in-memory .docx (ZIP) with a word/document.xml containing [text].
List<int> _buildDocx(String text) {
  final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>$text</w:t></w:r></w:p>
  </w:body>
</w:document>''';

  final archive = Archive();
  final xmlBytes = utf8.encode(xml);
  archive.addFile(ArchiveFile('word/document.xml', xmlBytes.length, xmlBytes));
  return ZipEncoder().encode(archive)!;
}

void main() {
  group('extractDocxTextFromBytes', () {
    test('extracts text from a minimal docx', () {
      final bytes = _buildDocx('Hello world');
      final result = extractDocxTextFromBytes(bytes);
      expect(result, isNotNull);
      expect(result, contains('Hello world'));
    });

    test('returns null for invalid bytes', () {
      final result = extractDocxTextFromBytes([0, 1, 2, 3]);
      expect(result, isNull);
    });

    test('returns null when word/document.xml is missing', () {
      final archive = Archive();
      final bytes = ZipEncoder().encode(archive)!;
      final result = extractDocxTextFromBytes(bytes);
      expect(result, isNull);
    });

    test('handles multi-paragraph documents', () {
      final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>First</w:t></w:r></w:p>
    <w:p><w:r><w:t>Second</w:t></w:r></w:p>
  </w:body>
</w:document>''';
      final xmlBytes = utf8.encode(xml);
      final archive = Archive();
      archive.addFile(
        ArchiveFile('word/document.xml', xmlBytes.length, xmlBytes),
      );
      final bytes = ZipEncoder().encode(archive)!;
      final result = extractDocxTextFromBytes(bytes);
      expect(result, isNotNull);
      expect(result, contains('First'));
      expect(result, contains('Second'));
    });

    test('returns empty string (trimmed to empty) for empty body', () {
      final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body></w:body>
</w:document>''';
      final xmlBytes = utf8.encode(xml);
      final archive = Archive();
      archive.addFile(
        ArchiveFile('word/document.xml', xmlBytes.length, xmlBytes),
      );
      final bytes = ZipEncoder().encode(archive)!;
      final result = extractDocxTextFromBytes(bytes);
      expect(result, isNotNull);
      expect(result!.trim(), isEmpty);
    });

    test('handles UTF-8 non-ASCII characters correctly', () {
      final bytes = _buildDocx('Héllo wörld — café');
      final result = extractDocxTextFromBytes(bytes);
      expect(result, isNotNull);
      expect(result, contains('Héllo'));
      expect(result, contains('café'));
    });
  });

  group('mimeTypeForExtension', () {
    test('returns correct MIME for common types', () {
      expect(mimeTypeForExtension('pdf'), 'application/pdf');
      expect(mimeTypeForExtension('png'), 'image/png');
      expect(mimeTypeForExtension('jpg'), 'image/jpeg');
      expect(mimeTypeForExtension('json'), 'application/json');
      expect(mimeTypeForExtension('html'), 'text/html');
      expect(mimeTypeForExtension('txt'), 'text/plain');
      expect(mimeTypeForExtension('csv'), 'text/csv');
      expect(mimeTypeForExtension('mp4'), 'video/mp4');
    });

    test('returns null for null extension', () {
      expect(mimeTypeForExtension(null), isNull);
    });

    test('returns null for unknown extension', () {
      expect(mimeTypeForExtension('xyzunknown'), isNull);
    });
  });

  group('stripEmlBody', () {
    test('strips RFC-2822 headers and returns body', () {
      const eml = '''From: alice@example.com
To: bob@example.com
Subject: Test

This is the body.
Second line.''';
      final result = stripEmlBody(eml);
      expect(result, 'This is the body.\nSecond line.');
      expect(result, isNot(contains('From:')));
      expect(result, isNot(contains('Subject:')));
    });

    test('returns empty string when there is no body', () {
      const eml = 'From: a@b.com\nTo: c@d.com\n\n';
      final result = stripEmlBody(eml);
      expect(result.trim(), isEmpty);
    });

    test('handles email with no headers (body only)', () {
      const eml = '\nJust body text.';
      final result = stripEmlBody(eml);
      expect(result, 'Just body text.');
    });
  });
}
