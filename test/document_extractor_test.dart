import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/document_extractor.dart';

import 'support/document_extraction_fixtures.dart';

void main() {
  group('extractDocxTextFromBytes', () {
    test('extracts text from a minimal docx', () {
      final bytes = buildDocxText('Hello world');
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

    test('fails closed for a DOCX above the default entry cap', () {
      const limits = DocumentExtractionLimits();
      final bytes = buildDocxText(
        'over entry cap',
        extraEntries: {
          for (var index = 0; index < limits.maxEntries; index++)
            'word/extra_$index.xml': const <int>[],
        },
      );

      expect(extractDocxTextFromBytes(bytes), isNull);
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
      final bytes = buildDocxText('Héllo wörld — café');
      final result = extractDocxTextFromBytes(bytes);
      expect(result, isNotNull);
      expect(result, contains('Héllo'));
      expect(result, contains('café'));
    });
  });

  group('extractDocument bounded async extraction', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'atlas_document_extraction_',
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'valid DOCX and HTML extraction preserves legacy text semantics',
      () async {
        final docx = File(p.join(tempDir.path, 'valid.docx'))
          ..writeAsBytesSync(buildDocxText('Hello DOCX'));
        final html = File(p.join(tempDir.path, 'valid.html'))
          ..writeAsStringSync('<h1>Hello</h1><p>HTML body</p>');

        final docxResult = await extractDocument(docx.path, 'docx');
        final htmlResult = await extractDocument(html.path, 'html');

        expect(docxResult.warning, isNull);
        expect(docxResult.extractedText, contains('Hello DOCX'));
        expect(docxResult.renderedMarkdown, isNull);
        expect(htmlResult.warning, isNull);
        expect(htmlResult.extractedText, contains('Hello'));
        expect(htmlResult.extractedText, contains('HTML body'));
        expect(htmlResult.extractedText, isNot(contains('<h1>')));
        expect(htmlResult.renderedMarkdown, '<h1>Hello</h1><p>HTML body</p>');
      },
    );

    test(
      'source-byte limit accepts exact boundary and warns at plus one',
      () async {
        final html = File(p.join(tempDir.path, 'source-boundary.html'))
          ..writeAsStringSync('<p>abcd</p>');
        final sourceBytes = html.lengthSync();

        final exact = await extractDocument(
          html.path,
          'html',
          limits: DocumentExtractionLimits(
            maxSourceBytes: sourceBytes,
            maxCentralDirectoryBytes: sourceBytes,
            maxCompressedEntryBytes: sourceBytes,
          ),
        );
        final over = await extractDocument(
          html.path,
          'html',
          limits: DocumentExtractionLimits(
            maxSourceBytes: sourceBytes - 1,
            maxCentralDirectoryBytes: sourceBytes - 1,
            maxCompressedEntryBytes: sourceBytes - 1,
          ),
        );

        expect(exact.warning, isNull);
        expect(exact.sourceBytes, sourceBytes);
        expect(over.extractedText, isNull);
        expect(over.warning?.code, 'source_size_limit');
        expect(over.warning?.format, 'html');
        expect(over.warning?.sourceBytes, sourceBytes);
        expect(over.warning?.limitBytes, sourceBytes - 1);
        expect(over.warning?.message, isNotEmpty);
      },
    );

    test(
      'DOCX actual document XML bytes defeat a forged-small ZIP size',
      () async {
        final actual = buildDocxText('x' * 512);
        final forged = patchZipEntryUncompressedSize(
          actual,
          'word/document.xml',
          16,
        );
        final docx = File(p.join(tempDir.path, 'forged-small.docx'))
          ..writeAsBytesSync(forged);

        final result = await extractDocument(
          docx.path,
          'docx',
          limits: const DocumentExtractionLimits(maxExpandedBytes: 128),
        );

        expect(result.extractedText, isNull);
        expect(result.warning?.code, 'expanded_size_limit');
        expect(result.warning?.format, 'docx');
        expect(result.warning?.expandedBytes, greaterThan(128));
        expect(result.warning?.limitBytes, 128);
      },
    );

    test(
      'DOCX entry-count and central-directory limits fail before expansion',
      () async {
        final bytes = buildDocxText(
          'bounded',
          extraEntries: {
            'word/styles.xml': utf8.encode('<styles/>'),
            'docProps/${'x' * 40}.xml': utf8.encode('<props/>'),
          },
        );
        final docx = File(p.join(tempDir.path, 'metadata.docx'))
          ..writeAsBytesSync(bytes);
        final directoryBytes = zipCentralDirectoryBytes(bytes);

        final exact = await extractDocument(
          docx.path,
          'docx',
          limits: DocumentExtractionLimits(
            maxEntries: 3,
            maxCentralDirectoryBytes: directoryBytes,
          ),
        );
        final entryOver = await extractDocument(
          docx.path,
          'docx',
          limits: const DocumentExtractionLimits(maxEntries: 2),
        );
        final metadataOver = await extractDocument(
          docx.path,
          'docx',
          limits: DocumentExtractionLimits(
            maxCentralDirectoryBytes: directoryBytes - 1,
          ),
        );

        expect(exact.warning, isNull);
        expect(entryOver.warning?.code, 'archive_entry_limit');
        expect(metadataOver.warning?.code, 'archive_metadata_limit');
      },
    );

    test('invalid ZIP missing document XML malformed XML and DOCTYPE return '
        'structured warnings', () async {
      final cases = <(String, List<int>, String)>[
        ('invalid', [0, 1, 2, 3], 'invalid_archive'),
        (
          'missing',
          buildZip({'README.md': utf8.encode('not a document')}),
          'document_xml_missing',
        ),
        (
          'malformed',
          buildDocx(documentXml: '<w:document><w:body>'),
          'malformed_document_xml',
        ),
        (
          'doctype',
          buildDocx(
            documentXml: '''<!DOCTYPE w:document [<!ENTITY x "amplified">]>
<w:document xmlns:w="urn:test"><w:body><w:p><w:r><w:t>&x;</w:t></w:r></w:p></w:body></w:document>''',
          ),
          'unsafe_document_xml',
        ),
      ];

      for (final (name, bytes, code) in cases) {
        final docx = File(p.join(tempDir.path, '$name.docx'))
          ..writeAsBytesSync(bytes);
        final result = await extractDocument(docx.path, 'docx');

        expect(result.extractedText, isNull, reason: name);
        expect(result.renderedMarkdown, isNull, reason: name);
        expect(result.warning?.code, code, reason: name);
        expect(result.warning?.format, 'docx', reason: name);
        expect(result.warning?.message, isNotEmpty, reason: name);
        expect(
          result.warning?.message,
          isNot(contains(docx.path)),
          reason: name,
        );
      }
    });

    test('text limit accepts exact boundary and warns at plus one', () async {
      final files = <(String, File)>[
        (
          'docx',
          File(p.join(tempDir.path, 'text.docx'))
            ..writeAsBytesSync(buildDocxText('abcd')),
        ),
        (
          'html',
          File(p.join(tempDir.path, 'text.html'))
            ..writeAsStringSync('<p>abcd</p>'),
        ),
      ];

      for (final (extension, file) in files) {
        final exact = await extractDocument(
          file.path,
          extension,
          limits: const DocumentExtractionLimits(maxExtractedTextCharacters: 4),
        );
        final over = await extractDocument(
          file.path,
          extension,
          limits: const DocumentExtractionLimits(maxExtractedTextCharacters: 3),
        );

        expect(exact.warning, isNull, reason: extension);
        expect(exact.extractedText, 'abcd', reason: extension);
        expect(over.extractedText, isNull, reason: extension);
        expect(over.warning?.code, 'text_size_limit', reason: extension);
        expect(over.warning?.format, extension, reason: extension);
        expect(over.warning?.limitBytes, 3, reason: extension);
      }
    });

    test(
      'parallel DOCX and HTML extraction returns isolated results',
      () async {
        final docx = File(p.join(tempDir.path, 'parallel.docx'))
          ..writeAsBytesSync(buildDocxText('alpha'));
        final html = File(p.join(tempDir.path, 'parallel.html'))
          ..writeAsStringSync('<p>beta</p>');

        final results = await Future.wait([
          extractDocument(docx.path, 'docx'),
          extractDocument(html.path, 'html'),
          extractDocument(docx.path, 'docx'),
          extractDocument(html.path, 'html'),
        ]);

        expect(results[0].extractedText, 'alpha');
        expect(results[1].extractedText, 'beta');
        expect(results[2].extractedText, 'alpha');
        expect(results[3].extractedText, 'beta');
        expect(results.map((result) => result.warning), everyElement(isNull));
      },
    );

    test('configured limits reject zero and values above hard maxima', () {
      for (final limits in [
        const DocumentExtractionLimits(maxSourceBytes: 0),
        const DocumentExtractionLimits(maxEntries: 0),
        const DocumentExtractionLimits(maxCentralDirectoryBytes: 0),
        const DocumentExtractionLimits(maxCompressedEntryBytes: 0),
        const DocumentExtractionLimits(maxExpandedBytes: 0),
        const DocumentExtractionLimits(maxExtractedTextCharacters: 0),
        const DocumentExtractionLimits(
          maxSourceBytes: DocumentExtractionLimits.hardMaxSourceBytes + 1,
        ),
        const DocumentExtractionLimits(
          maxEntries: DocumentExtractionLimits.hardMaxEntries + 1,
        ),
        const DocumentExtractionLimits(
          maxCentralDirectoryBytes:
              DocumentExtractionLimits.hardMaxCentralDirectoryBytes + 1,
        ),
        const DocumentExtractionLimits(
          maxCompressedEntryBytes:
              DocumentExtractionLimits.hardMaxCompressedEntryBytes + 1,
        ),
        const DocumentExtractionLimits(
          maxExpandedBytes: DocumentExtractionLimits.hardMaxExpandedBytes + 1,
        ),
        const DocumentExtractionLimits(
          maxExtractedTextCharacters:
              DocumentExtractionLimits.hardMaxExtractedTextCharacters + 1,
        ),
      ]) {
        expect(limits.validate, throwsArgumentError);
      }
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
      const eml = '''From: alice@example.invalid
To: bob@example.invalid
Subject: Test

This is the body.
Second line.''';
      final result = stripEmlBody(eml);
      expect(result, 'This is the body.\nSecond line.');
      expect(result, isNot(contains('From:')));
      expect(result, isNot(contains('Subject:')));
    });

    test('returns empty string when there is no body', () {
      const eml =
          'From: sender@example.invalid\nTo: recipient@example.invalid\n\n';
      final result = stripEmlBody(eml);
      expect(result.trim(), isEmpty);
    });

    test('handles email with no headers (body only)', () {
      const eml = '\nJust body text.';
      final result = stripEmlBody(eml);
      expect(result, 'Just body text.');
    });

    test('body text is preserved verbatim', () {
      const eml = 'From: sender@example.invalid\n\nLine one.\nLine two.';
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
