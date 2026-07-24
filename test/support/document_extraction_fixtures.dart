import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

String documentXml(String text) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>$text</w:t></w:r></w:p></w:body>
</w:document>''';

List<int> buildDocx({
  required String documentXml,
  Map<String, List<int>> extraEntries = const {},
}) {
  final archive = Archive();
  final xmlBytes = utf8.encode(documentXml);
  archive.addFile(ArchiveFile('word/document.xml', xmlBytes.length, xmlBytes));
  for (final entry in extraEntries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive)!;
}

List<int> buildDocxText(
  String text, {
  Map<String, List<int>> extraEntries = const {},
}) => buildDocx(documentXml: documentXml(text), extraEntries: extraEntries);

List<int> buildZip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive)!;
}

List<int> patchZipEntryUncompressedSize(
  List<int> source,
  String path,
  int declaredBytes,
) {
  final bytes = List<int>.from(source);
  var patchedLocal = false;
  var patchedCentral = false;
  for (var offset = 0; offset + 46 <= bytes.length; offset++) {
    final signature = _readUint32(bytes, offset);
    if (signature == 0x04034b50) {
      final nameLength = _readUint16(bytes, offset + 26);
      final nameStart = offset + 30;
      if (nameStart + nameLength > bytes.length) continue;
      final name = utf8.decode(
        bytes.sublist(nameStart, nameStart + nameLength),
      );
      if (name == path) {
        _writeUint32(bytes, offset + 22, declaredBytes);
        patchedLocal = true;
      }
    } else if (signature == 0x02014b50) {
      final nameLength = _readUint16(bytes, offset + 28);
      final nameStart = offset + 46;
      if (nameStart + nameLength > bytes.length) continue;
      final name = utf8.decode(
        bytes.sublist(nameStart, nameStart + nameLength),
      );
      if (name == path) {
        _writeUint32(bytes, offset + 24, declaredBytes);
        patchedCentral = true;
      }
    }
  }
  expect(patchedLocal, isTrue);
  expect(patchedCentral, isTrue);
  return bytes;
}

int zipCentralDirectoryBytes(List<int> bytes) =>
    _readUint32(bytes, _findEocd(bytes) + 12);

int _findEocd(List<int> bytes) {
  for (var offset = bytes.length - 22; offset >= 0; offset--) {
    if (_readUint32(bytes, offset) == 0x06054b50) return offset;
  }
  throw StateError('EOCD not found');
}

int _readUint16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _readUint32(List<int> bytes, int offset) =>
    _readUint16(bytes, offset) | (_readUint16(bytes, offset + 2) << 16);

void _writeUint32(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
  bytes[offset + 3] = (value >> 24) & 0xff;
}
