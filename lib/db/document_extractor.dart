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

/// Extensions that DocumentPreview will decode as text; all others show an
/// external-viewer prompt or skip the file-read entirely.
const textDocumentExtensions = {
  'txt',
  'md',
  'mdx',
  'json',
  'jsonc',
  'csv',
  'log',
  'xml',
  'yaml',
  'yml',
  'ini',
  'toml',
  'rst',
  'html',
  'htm',
  'eml',
};

/// Source-code and project text formats that can be copied into the document
/// library and previewed as monospace text.
const codeDocumentExtensions = {
  'astro',
  'bat',
  'bash',
  'c',
  'cc',
  'cfg',
  'cjs',
  'clj',
  'cljs',
  'cmake',
  'cmd',
  'conf',
  'cpp',
  'cs',
  'css',
  'cxx',
  'dart',
  'dockerfile',
  'erl',
  'ex',
  'exs',
  'fs',
  'fsx',
  'go',
  'gradle',
  'h',
  'hpp',
  'hrl',
  'hs',
  'java',
  'js',
  'jsx',
  'kt',
  'kts',
  'less',
  'lua',
  'mjs',
  'php',
  'properties',
  'ps1',
  'psm1',
  'py',
  'r',
  'rb',
  'rs',
  'sass',
  'scala',
  'scss',
  'sh',
  'sql',
  'svelte',
  'swift',
  'ts',
  'tsx',
  'vue',
  'zsh',
};

/// Returns true when [extension] (lowercase, no dot) is a text format that
/// can safely be decoded and displayed as a string.
bool shouldLoadDocumentText(String extension) =>
    textDocumentExtensions.contains(extension.toLowerCase()) ||
    codeDocumentExtensions.contains(extension.toLowerCase());

bool shouldExtractAsPlainText(String extension) =>
    shouldLoadDocumentText(extension) &&
    extension.toLowerCase() != 'md' &&
    extension.toLowerCase() != 'mdx' &&
    extension.toLowerCase() != 'html' &&
    extension.toLowerCase() != 'htm' &&
    extension.toLowerCase() != 'eml';

/// Strips HTML tags from a file at [path], returning plain text.
/// Returns null if the file cannot be read.
String? extractHtmlText(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    String raw;
    try {
      raw = utf8.decode(bytes);
    } catch (_) {
      raw = latin1.decode(bytes);
    }
    return raw
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  } catch (_) {
    return null;
  }
}

/// Extracts plain text from raw .docx bytes (ZIP containing word/document.xml).
/// Returns null if parsing fails.
String? extractDocxTextFromBytes(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.findFile('word/document.xml');
    if (entry == null) return null;
    final xml = XmlDocument.parse(utf8.decode(entry.content as List<int>));
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
