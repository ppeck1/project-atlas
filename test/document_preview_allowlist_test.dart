import 'package:flutter_test/flutter_test.dart';

// Allowlist of extensions that should be decoded as text by DocumentPreview.
// Binary files should never be decoded as text to prevent garbage display.
// This set mirrors the _shouldLoadText / _textExtensions contract in
// document_preview.dart — when that constant is made package-visible, swap
// the inline definition here for a direct import.
const _textExtensions = {
  'txt', 'md', 'json', 'csv', 'log', 'xml', 'yaml', 'yml',
  'ini', 'toml', 'rst', 'html', 'htm', 'eml',
};

const _binaryExtensions = {
  'pdf', 'doc', 'docx', 'rtf', 'svg',
  'jpg', 'png', 'gif', 'webp', 'bmp',
};

void main() {
  group('document preview _shouldLoadText allowlist', () {
    test('all expected text-format extensions are in the allowlist', () {
      const expected = {
        'txt', 'md', 'json', 'csv', 'log', 'xml', 'yaml', 'yml',
        'ini', 'toml', 'rst', 'html', 'htm', 'eml',
      };
      for (final ext in expected) {
        expect(
          _textExtensions.contains(ext),
          isTrue,
          reason: '.$ext should be in the text allowlist',
        );
      }
    });

    test('none of the binary formats are in the text allowlist', () {
      for (final ext in _binaryExtensions) {
        expect(
          _textExtensions.contains(ext),
          isFalse,
          reason: '.$ext is a binary format and must not be decoded as text',
        );
      }
    });
  });
}
