import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/document_extractor.dart';

// Builds a minimal in-memory .docx (ZIP) with a word/document.xml containing [text].
List<int> _buildDocx(String text) {
  final xml =
      '''<?xml version="1.0" encoding="UTF-8"?>
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

    test('body text is preserved verbatim', () {
      const eml = 'From: a@b.com\n\nLine one.\nLine two.';
      final result = stripEmlBody(eml);
      expect(result, contains('Line one.'));
      expect(result, contains('Line two.'));
    });
  });

  group('extractHtmlText', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('atlas_html_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('HTML tags are stripped and text content is preserved', () {
      final file = File('${tempDir.path}/page.html')
        ..writeAsStringSync('<h1>Title</h1><p>Body</p>');
      final result = extractHtmlText(file.path);
      expect(result, isNotNull);
      expect(result, contains('Title'));
      expect(result, contains('Body'));
      expect(result, isNot(contains('<h1>')));
      expect(result, isNot(contains('<p>')));
    });

    test('back-to-back tags do not produce multiple consecutive spaces', () {
      final file = File('${tempDir.path}/multi.html')
        ..writeAsStringSync('<h1>Hello</h1><h2>World</h2>');
      final result = extractHtmlText(file.path);
      expect(result, isNotNull);
      expect(result, isNot(matches(RegExp(r'  +'))));
    });

    test('non-UTF-8 (latin1) bytes do not throw and return non-null', () {
      final latin1Bytes = [
        0x3C, 0x70, 0x3E, // <p>
        0xE9, 0xE0, 0xFC, // é à ü in latin1
        0x3C, 0x2F, 0x70, 0x3E, // </p>
      ];
      final file = File('${tempDir.path}/latin1.html')
        ..writeAsBytesSync(latin1Bytes);
      final result = extractHtmlText(file.path);
      expect(result, isNotNull);
    });

    test('missing file returns null', () {
      final result = extractHtmlText('${tempDir.path}/no_such.html');
      expect(result, isNull);
    });

    test('empty file returns empty or null without crashing', () {
      final file = File('${tempDir.path}/empty.html')..writeAsBytesSync([]);
      final result = extractHtmlText(file.path);
      // Both null and empty string are acceptable; crash is not.
      expect(result == null || result.isEmpty, isTrue);
    });
  });
}
