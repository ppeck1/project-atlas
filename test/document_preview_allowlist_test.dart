import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/document_extractor.dart';

void main() {
  group('shouldLoadDocumentText', () {
    const textExts = {
      'txt', 'md', 'json', 'csv', 'log', 'xml', 'yaml', 'yml',
      'ini', 'toml', 'rst', 'html', 'htm', 'eml',
    };
    const binaryExts = {
      'pdf', 'doc', 'docx', 'rtf', 'svg',
      'jpg', 'png', 'gif', 'webp', 'bmp',
    };

    test('returns true for all text-format extensions', () {
      for (final ext in textExts) {
        expect(
          shouldLoadDocumentText(ext),
          isTrue,
          reason: '.$ext should be loadable as text',
        );
      }
    });

    test('returns false for binary and external-viewer formats', () {
      for (final ext in binaryExts) {
        expect(
          shouldLoadDocumentText(ext),
          isFalse,
          reason: '.$ext is binary and must not be decoded as text',
        );
      }
    });

    test('is case-insensitive', () {
      expect(shouldLoadDocumentText('TXT'), isTrue);
      expect(shouldLoadDocumentText('HTML'), isTrue);
      expect(shouldLoadDocumentText('PDF'), isFalse);
    });
  });
}
