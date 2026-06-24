import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:mime/mime.dart';
import 'package:xml/xml.dart';

/// Extracts plain text from a .docx file at [path] by reading word/document.xml.
/// Returns null if the file cannot be parsed.
String? extractDocxText(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    return extractDocxTextFromBytes(bytes);
  } catch (_) {
    return null;
  }
}

/// Returns the MIME type for a file extension, e.g. 'pdf' → 'application/pdf'.
String? mimeTypeForExtension(String? extension) {
  if (extension == null) return null;
  return lookupMimeType('file.$extension');
}

/// Strips RFC-2822 headers from an EML string, returning only the body.
String stripEmlBody(String raw) {
  final lines = raw.split('\n');
  var inBody = false;
  final body = <String>[];
  for (final line in lines) {
    if (!inBody && line.trim().isEmpty) {
      inBody = true;
      continue;
    }
    if (inBody) body.add(line);
  }
  return body.join('\n').trim();
}

/// Extracts plain text from raw .docx bytes (ZIP containing word/document.xml).
/// Returns null if parsing fails.
String? extractDocxTextFromBytes(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.findFile('word/document.xml');
    if (entry == null) return null;
    final xml = XmlDocument.parse(
      utf8.decode(entry.content as List<int>),
    );
    final buffer = StringBuffer();
    for (final node in xml.descendants.whereType<XmlElement>()) {
      if (node.localName == 't') {
        buffer.write(node.innerText);
        buffer.write(' ');
      } else if (node.localName == 'p') {
        buffer.write('\n');
      }
    }
    return buffer.toString().trim();
  } catch (_) {
    return null;
  }
}
