import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:mime/mime.dart';
import 'package:xml/xml.dart';

const documentExtractionWarningSchema = 'atlas.document_extraction_warning.v1';

class DocumentExtractionLimits {
  static const int hardMaxSourceBytes = 64 * 1024 * 1024;
  static const int hardMaxEntries = 16384;
  static const int hardMaxCentralDirectoryBytes = 16 * 1024 * 1024;
  static const int hardMaxCompressedEntryBytes = 64 * 1024 * 1024;
  static const int hardMaxExpandedBytes = 128 * 1024 * 1024;
  static const int hardMaxExtractedTextCharacters = 32 * 1024 * 1024;

  final int maxSourceBytes;
  final int maxEntries;
  final int maxCentralDirectoryBytes;
  final int maxCompressedEntryBytes;
  final int maxExpandedBytes;
  final int maxExtractedTextCharacters;

  const DocumentExtractionLimits({
    this.maxSourceBytes = 10 * 1024 * 1024,
    this.maxEntries = 2048,
    this.maxCentralDirectoryBytes = 4 * 1024 * 1024,
    this.maxCompressedEntryBytes = 10 * 1024 * 1024,
    this.maxExpandedBytes = 32 * 1024 * 1024,
    this.maxExtractedTextCharacters = 16 * 1024 * 1024,
  });

  void validate() {
    _validateBound('maxSourceBytes', maxSourceBytes, hardMaxSourceBytes);
    _validateBound('maxEntries', maxEntries, hardMaxEntries);
    _validateBound(
      'maxCentralDirectoryBytes',
      maxCentralDirectoryBytes,
      hardMaxCentralDirectoryBytes,
    );
    _validateBound(
      'maxCompressedEntryBytes',
      maxCompressedEntryBytes,
      hardMaxCompressedEntryBytes,
    );
    _validateBound('maxExpandedBytes', maxExpandedBytes, hardMaxExpandedBytes);
    _validateBound(
      'maxExtractedTextCharacters',
      maxExtractedTextCharacters,
      hardMaxExtractedTextCharacters,
    );
    if (maxCentralDirectoryBytes > maxSourceBytes) {
      throw ArgumentError.value(
        maxCentralDirectoryBytes,
        'maxCentralDirectoryBytes',
        'must be no greater than maxSourceBytes',
      );
    }
    if (maxCompressedEntryBytes > maxSourceBytes) {
      throw ArgumentError.value(
        maxCompressedEntryBytes,
        'maxCompressedEntryBytes',
        'must be no greater than maxSourceBytes',
      );
    }
  }

  Map<String, int> toMessage() => {
    'maxSourceBytes': maxSourceBytes,
    'maxEntries': maxEntries,
    'maxCentralDirectoryBytes': maxCentralDirectoryBytes,
    'maxCompressedEntryBytes': maxCompressedEntryBytes,
    'maxExpandedBytes': maxExpandedBytes,
    'maxExtractedTextCharacters': maxExtractedTextCharacters,
  };

  static DocumentExtractionLimits fromMessage(Map<Object?, Object?> message) =>
      DocumentExtractionLimits(
        maxSourceBytes: message['maxSourceBytes']! as int,
        maxEntries: message['maxEntries']! as int,
        maxCentralDirectoryBytes: message['maxCentralDirectoryBytes']! as int,
        maxCompressedEntryBytes: message['maxCompressedEntryBytes']! as int,
        maxExpandedBytes: message['maxExpandedBytes']! as int,
        maxExtractedTextCharacters:
            message['maxExtractedTextCharacters']! as int,
      );

  static void _validateBound(String name, int value, int hardMaximum) {
    if (value <= 0 || value > hardMaximum) {
      throw ArgumentError.value(
        value,
        name,
        'must be positive and no greater than $hardMaximum',
      );
    }
  }
}

class DocumentExtractionWarning {
  final String code;
  final String format;
  final String message;
  final int? sourceBytes;
  final int? expandedBytes;
  final int? limitBytes;

  const DocumentExtractionWarning({
    required this.code,
    required this.format,
    required this.message,
    this.sourceBytes,
    this.expandedBytes,
    this.limitBytes,
  });

  Map<String, Object?> toJson() => {
    'schema': documentExtractionWarningSchema,
    'code': code,
    'format': format,
    'message': message,
    if (sourceBytes != null) 'sourceBytes': sourceBytes,
    if (expandedBytes != null) 'expandedBytes': expandedBytes,
    if (limitBytes != null) 'limitBytes': limitBytes,
  };

  String encode() => jsonEncode(toJson());

  static DocumentExtractionWarning fromMessage(Map<Object?, Object?> message) =>
      DocumentExtractionWarning(
        code: message['code']! as String,
        format: message['format']! as String,
        message: message['message']! as String,
        sourceBytes: message['sourceBytes'] as int?,
        expandedBytes: message['expandedBytes'] as int?,
        limitBytes: message['limitBytes'] as int?,
      );
}

class DocumentExtractionResult {
  final String? extractedText;
  final String? renderedMarkdown;
  final DocumentExtractionWarning? warning;
  final int sourceBytes;
  final int? expandedBytes;

  const DocumentExtractionResult({
    required this.extractedText,
    required this.renderedMarkdown,
    required this.warning,
    required this.sourceBytes,
    required this.expandedBytes,
  });

  bool get succeeded => warning == null;

  static DocumentExtractionResult fromMessage(Map<Object?, Object?> message) =>
      DocumentExtractionResult(
        extractedText: message['extractedText'] as String?,
        renderedMarkdown: message['renderedMarkdown'] as String?,
        warning: message['warning'] is Map
            ? DocumentExtractionWarning.fromMessage(
                message['warning']! as Map<Object?, Object?>,
              )
            : null,
        sourceBytes: message['sourceBytes']! as int,
        expandedBytes: message['expandedBytes'] as int?,
      );
}

/// Extracts DOCX or HTML text in a dedicated isolate.
///
/// Malformed, hostile, missing, or oversized sources produce a structured
/// warning and no extracted text. Invalid caller-supplied limits still throw
/// [ArgumentError].
Future<DocumentExtractionResult> extractDocument(
  String path,
  String extension, {
  DocumentExtractionLimits limits = const DocumentExtractionLimits(),
}) async {
  limits.validate();
  final format = extension.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
  if (format != 'docx' && format != 'html' && format != 'htm') {
    return DocumentExtractionResult(
      extractedText: null,
      renderedMarkdown: null,
      warning: DocumentExtractionWarning(
        code: 'unsupported_extension',
        format: format,
        message: 'Only DOCX and HTML document extraction is supported.',
      ),
      sourceBytes: 0,
      expandedBytes: null,
    );
  }
  final request = <String, Object?>{
    'path': path,
    'format': format,
    'limits': limits.toMessage(),
  };
  try {
    final response = await Isolate.run<Map<String, Object?>>(
      () => _documentExtractionWorker(request),
      debugName: 'atlas-document-extraction',
    );
    return DocumentExtractionResult.fromMessage(response);
  } catch (_) {
    return DocumentExtractionResult(
      extractedText: null,
      renderedMarkdown: null,
      warning: DocumentExtractionWarning(
        code: 'worker_failure',
        format: format,
        message: 'The isolated document extraction worker failed.',
      ),
      sourceBytes: 0,
      expandedBytes: null,
    );
  }
}

/// Extracts plain text from a .docx file at [path] by reading word/document.xml.
/// Returns null if the file cannot be parsed.
String? extractDocxText(String path) {
  try {
    final limits = const DocumentExtractionLimits()..validate();
    final stamp = _validateSource(path, 'docx', limits);
    return _extractDocx(path, stamp, limits).extractedText;
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
    final limits = const DocumentExtractionLimits()..validate();
    final stamp = _validateSource(path, 'html', limits);
    return _extractHtml(path, stamp, limits).extractedText;
  } catch (_) {
    return null;
  }
}

/// Extracts plain text from raw .docx bytes (ZIP containing word/document.xml).
/// Returns null if parsing fails.
String? extractDocxTextFromBytes(List<int> bytes) {
  const limits = DocumentExtractionLimits();
  Archive? archive;
  try {
    limits.validate();
    if (!_preflightLegacyDocxBytes(bytes, limits)) return null;
    archive = ZipDecoder().decodeBytes(bytes, verify: false);
    if (archive.length > limits.maxEntries) return null;
    final matches = archive.files
        .where((entry) => entry.name == _documentXmlPath)
        .toList(growable: false);
    if (matches.length != 1) return null;
    final entry = matches.single;
    if (entry.size < 0 ||
        entry.size > limits.maxExpandedBytes ||
        entry.rawContent == null ||
        entry.rawContent!.length > limits.maxCompressedEntryBytes ||
        (entry.compressionType != ArchiveFile.STORE &&
            entry.compressionType != ArchiveFile.DEFLATE)) {
      return null;
    }
    final output = _BoundedCaptureSink(limits.maxExpandedBytes);
    if (entry.compressionType == ArchiveFile.DEFLATE) {
      Inflate.stream(entry.rawContent!, output);
    } else {
      output.writeInputStream(entry.rawContent!);
    }
    if (output.length != entry.size ||
        (entry.crc32 != null && getCrc32(output.bytes) != entry.crc32)) {
      return null;
    }
    return _parseDocumentXml(output.bytes, limits);
  } catch (_) {
    return null;
  } finally {
    if (archive != null) {
      for (final entry in archive.files) {
        entry.closeSync();
      }
    }
  }
}

const _documentXmlPath = 'word/document.xml';

bool _preflightLegacyDocxBytes(
  List<int> bytes,
  DocumentExtractionLimits limits,
) {
  const minimumEocdBytes = 22;
  const maximumCommentBytes = 0xffff;
  if (bytes.length < minimumEocdBytes || bytes.length > limits.maxSourceBytes) {
    return false;
  }
  final tailStart = math.max(
    0,
    bytes.length - minimumEocdBytes - maximumCommentBytes,
  );
  for (
    var offset = bytes.length - minimumEocdBytes;
    offset >= tailStart;
    offset--
  ) {
    if (_uint32(bytes, offset) != 0x06054b50) continue;
    final commentBytes = _uint16(bytes, offset + 20);
    if (offset + minimumEocdBytes + commentBytes != bytes.length) continue;
    final disk = _uint16(bytes, offset + 4);
    final directoryDisk = _uint16(bytes, offset + 6);
    final entriesOnDisk = _uint16(bytes, offset + 8);
    final entryCount = _uint16(bytes, offset + 10);
    final directoryBytes = _uint32(bytes, offset + 12);
    final directoryOffset = _uint32(bytes, offset + 16);
    if (disk != 0 ||
        directoryDisk != 0 ||
        entriesOnDisk != entryCount ||
        entryCount == 0xffff ||
        entryCount > limits.maxEntries ||
        directoryBytes == 0xffffffff ||
        directoryBytes > limits.maxCentralDirectoryBytes ||
        directoryOffset == 0xffffffff ||
        directoryOffset + directoryBytes != offset) {
      return false;
    }
    return true;
  }
  return false;
}

Map<String, Object?> _documentExtractionWorker(Map<String, Object?> request) {
  final path = request['path']! as String;
  final format = request['format']! as String;
  final limits = DocumentExtractionLimits.fromMessage(
    request['limits']! as Map<Object?, Object?>,
  );
  var sourceBytes = 0;
  try {
    limits.validate();
    final stamp = _validateSource(path, format, limits);
    sourceBytes = stamp.size;
    final result = format == 'docx'
        ? _extractDocx(path, stamp, limits)
        : _extractHtml(path, stamp, limits);
    return _resultMessage(result);
  } on _ExtractionFailure catch (failure) {
    return _warningMessage(
      format,
      failure,
      sourceBytes: failure.sourceBytes ?? sourceBytes,
    );
  } on FileSystemException {
    return _warningMessage(
      format,
      const _ExtractionFailure(
        'io_failure',
        'The document source could not be read safely.',
      ),
      sourceBytes: sourceBytes,
    );
  } catch (_) {
    return _warningMessage(
      format,
      const _ExtractionFailure(
        'worker_failure',
        'The isolated document extraction worker failed.',
      ),
      sourceBytes: sourceBytes,
    );
  }
}

_SourceStamp _validateSource(
  String path,
  String format,
  DocumentExtractionLimits limits,
) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw const _ExtractionFailure(
      'source_not_regular',
      'The document source is missing, linked, or not a regular file.',
    );
  }
  final stat = File(path).statSync();
  if (stat.size > limits.maxSourceBytes) {
    throw _ExtractionFailure(
      'source_size_limit',
      'The document source exceeds the extraction size limit.',
      sourceBytes: stat.size,
      limitBytes: limits.maxSourceBytes,
    );
  }
  return _SourceStamp(stat.size, stat.modified.microsecondsSinceEpoch);
}

void _revalidateSource(String path, _SourceStamp before) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _ExtractionFailure(
      'source_changed',
      'The document source changed during extraction.',
    );
  }
  final after = File(path).statSync();
  if (after.size != before.size ||
      after.modified.microsecondsSinceEpoch != before.modifiedMicros) {
    throw _ExtractionFailure(
      'source_changed',
      'The document source changed during extraction.',
      sourceBytes: after.size,
    );
  }
}

DocumentExtractionResult _extractHtml(
  String path,
  _SourceStamp stamp,
  DocumentExtractionLimits limits,
) {
  final input = File(path).openSync();
  final builder = BytesBuilder(copy: false);
  try {
    while (builder.length <= limits.maxSourceBytes) {
      final remaining = limits.maxSourceBytes + 1 - builder.length;
      if (remaining <= 0) break;
      final chunk = input.readSync(math.min(64 * 1024, remaining));
      if (chunk.isEmpty) break;
      builder.add(chunk);
    }
  } finally {
    input.closeSync();
  }
  final bytes = builder.takeBytes();
  if (bytes.length > limits.maxSourceBytes) {
    throw _ExtractionFailure(
      'source_size_limit',
      'The document source exceeds the extraction size limit.',
      sourceBytes: bytes.length,
      limitBytes: limits.maxSourceBytes,
    );
  }
  _revalidateSource(path, stamp);
  String raw;
  try {
    raw = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    raw = latin1.decode(bytes);
  }
  final text = raw
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r' {2,}'), ' ')
      .trim();
  if (text.length > limits.maxExtractedTextCharacters) {
    throw _ExtractionFailure(
      'text_size_limit',
      'The extracted HTML text exceeds the extracted-text limit.',
      sourceBytes: stamp.size,
      expandedBytes: text.length,
      limitBytes: limits.maxExtractedTextCharacters,
    );
  }
  return DocumentExtractionResult(
    extractedText: text,
    renderedMarkdown: raw,
    warning: null,
    sourceBytes: stamp.size,
    expandedBytes: bytes.length,
  );
}

DocumentExtractionResult _extractDocx(
  String path,
  _SourceStamp stamp,
  DocumentExtractionLimits limits,
) {
  final preflight = _preflightDocx(path, stamp.size, limits);
  final input = InputFileStream(path);
  InputStreamBase? raw;
  try {
    input.position = preflight.dataOffset;
    raw = input.readBytes(preflight.compressedBytes);
    if (raw.length != preflight.compressedBytes) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX document XML payload is truncated.',
      );
    }
    final output = _BoundedCaptureSink(limits.maxExpandedBytes);
    try {
      if (preflight.compression == ArchiveFile.DEFLATE) {
        Inflate.stream(raw, output);
      } else if (preflight.compression == ArchiveFile.STORE) {
        output.writeInputStream(raw);
      } else {
        throw const _ExtractionFailure(
          'invalid_archive',
          'The DOCX document XML uses unsupported compression.',
        );
      }
    } on _ExtractionFailure {
      rethrow;
    } catch (_) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX document XML could not be decompressed.',
      );
    }
    if (output.length != preflight.expandedBytes) {
      throw _ExtractionFailure(
        'invalid_archive',
        'The DOCX document XML expanded length does not match its directory.',
        expandedBytes: output.length,
      );
    }
    if (getCrc32(output.bytes) != preflight.crc32) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX document XML failed its CRC integrity check.',
      );
    }
    _revalidateSource(path, stamp);
    final text = _parseDocumentXml(output.bytes, limits);
    return DocumentExtractionResult(
      extractedText: text,
      renderedMarkdown: null,
      warning: null,
      sourceBytes: stamp.size,
      expandedBytes: output.length,
    );
  } finally {
    raw?.closeSync();
    input.closeSync();
  }
}

_DocxPreflight _preflightDocx(
  String path,
  int sourceBytes,
  DocumentExtractionLimits limits,
) {
  const minimumEocdBytes = 22;
  const maximumCommentBytes = 0xffff;
  if (sourceBytes < minimumEocdBytes) {
    throw const _ExtractionFailure(
      'invalid_archive',
      'The DOCX source is not a complete ZIP archive.',
    );
  }
  final input = File(path).openSync();
  try {
    final tailBytes = math.min(
      sourceBytes,
      minimumEocdBytes + maximumCommentBytes,
    );
    input.setPositionSync(sourceBytes - tailBytes);
    final tail = input.readSync(tailBytes);
    var eocd = -1;
    for (var offset = tail.length - minimumEocdBytes; offset >= 0; offset--) {
      if (_uint32(tail, offset) != 0x06054b50) continue;
      final commentBytes = _uint16(tail, offset + 20);
      if (sourceBytes - tailBytes + offset + minimumEocdBytes + commentBytes ==
          sourceBytes) {
        eocd = offset;
        break;
      }
    }
    if (eocd < 0) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX ZIP directory is missing or malformed.',
      );
    }
    final disk = _uint16(tail, eocd + 4);
    final directoryDisk = _uint16(tail, eocd + 6);
    final entriesOnDisk = _uint16(tail, eocd + 8);
    final entryCount = _uint16(tail, eocd + 10);
    final directoryBytes = _uint32(tail, eocd + 12);
    final directoryOffset = _uint32(tail, eocd + 16);
    final absoluteEocd = sourceBytes - tailBytes + eocd;
    if (disk != 0 || directoryDisk != 0 || entriesOnDisk != entryCount) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'Multi-disk DOCX ZIP archives are unsupported.',
      );
    }
    if (entryCount == 0xffff ||
        directoryBytes == 0xffffffff ||
        directoryOffset == 0xffffffff) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'ZIP64 DOCX archives are unsupported.',
      );
    }
    if (entryCount > limits.maxEntries) {
      throw _ExtractionFailure(
        'archive_entry_limit',
        'The DOCX archive exceeds the entry-count limit.',
        sourceBytes: sourceBytes,
        limitBytes: limits.maxEntries,
      );
    }
    if (directoryBytes > limits.maxCentralDirectoryBytes) {
      throw _ExtractionFailure(
        'archive_metadata_limit',
        'The DOCX central directory exceeds the metadata limit.',
        sourceBytes: sourceBytes,
        expandedBytes: directoryBytes,
        limitBytes: limits.maxCentralDirectoryBytes,
      );
    }
    if (directoryOffset < 0 ||
        directoryOffset + directoryBytes != absoluteEocd) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX ZIP directory has an invalid extent.',
      );
    }
    input.setPositionSync(directoryOffset);
    final directory = input.readSync(directoryBytes);
    if (directory.length != directoryBytes) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX ZIP directory is truncated.',
      );
    }

    final entries = <_DocxCentralEntry>[];
    var offset = 0;
    while (offset < directory.length) {
      if (directory.length - offset < 46 ||
          _uint32(directory, offset) != 0x02014b50) {
        throw const _ExtractionFailure(
          'invalid_archive',
          'The DOCX central directory contains an invalid record.',
        );
      }
      final nameLength = _uint16(directory, offset + 28);
      final extraLength = _uint16(directory, offset + 30);
      final commentLength = _uint16(directory, offset + 32);
      final recordLength = 46 + nameLength + extraLength + commentLength;
      if (offset + recordLength > directory.length) {
        throw const _ExtractionFailure(
          'invalid_archive',
          'A DOCX central-directory record exceeds its bounds.',
        );
      }
      if (entries.length >= limits.maxEntries) {
        throw _ExtractionFailure(
          'archive_entry_limit',
          'The DOCX archive exceeds the entry-count limit.',
          sourceBytes: sourceBytes,
          limitBytes: limits.maxEntries,
        );
      }
      final compressedBytes = _uint32(directory, offset + 20);
      final expandedBytes = _uint32(directory, offset + 24);
      final localOffset = _uint32(directory, offset + 42);
      if (compressedBytes == 0xffffffff ||
          expandedBytes == 0xffffffff ||
          localOffset == 0xffffffff ||
          _uint16(directory, offset + 34) != 0) {
        throw const _ExtractionFailure(
          'invalid_archive',
          'ZIP64 or multi-disk DOCX entries are unsupported.',
        );
      }
      entries.add(
        _DocxCentralEntry(
          flags: _uint16(directory, offset + 8),
          compression: _uint16(directory, offset + 10),
          crc32: _uint32(directory, offset + 16),
          compressedBytes: compressedBytes,
          expandedBytes: expandedBytes,
          localOffset: localOffset,
          nameBytes: Uint8List.fromList(
            directory.sublist(offset + 46, offset + 46 + nameLength),
          ),
        ),
      );
      offset += recordLength;
    }
    if (offset != directory.length ||
        entries.length != entryCount ||
        entries.length != entriesOnDisk) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX ZIP entry count does not match its directory.',
      );
    }
    final targets = entries
        .where(
          (entry) => _sameBytes(entry.nameBytes, utf8.encode(_documentXmlPath)),
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      throw const _ExtractionFailure(
        'document_xml_missing',
        'The DOCX archive does not contain word/document.xml.',
      );
    }
    if (targets.length != 1) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX archive contains duplicate word/document.xml entries.',
      );
    }
    final target = targets.single;
    if ((target.flags & 0x1) != 0) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'Encrypted DOCX document XML is unsupported.',
      );
    }
    if (target.compression != ArchiveFile.STORE &&
        target.compression != ArchiveFile.DEFLATE) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX document XML uses unsupported compression.',
      );
    }
    if (target.compressedBytes > limits.maxCompressedEntryBytes) {
      throw _ExtractionFailure(
        'archive_metadata_limit',
        'The compressed DOCX document XML exceeds its limit.',
        sourceBytes: sourceBytes,
        expandedBytes: target.compressedBytes,
        limitBytes: limits.maxCompressedEntryBytes,
      );
    }
    if (target.expandedBytes > limits.maxExpandedBytes) {
      throw _ExtractionFailure(
        'expanded_size_limit',
        'The DOCX document XML exceeds the expanded-size limit.',
        sourceBytes: sourceBytes,
        expandedBytes: target.expandedBytes,
        limitBytes: limits.maxExpandedBytes,
      );
    }

    entries.sort((a, b) => a.localOffset.compareTo(b.localOffset));
    if (entries.isNotEmpty && entries.first.localOffset < 0) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX archive contains an invalid local offset.',
      );
    }
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final nextOffset = index + 1 < entries.length
          ? entries[index + 1].localOffset
          : directoryOffset;
      if (entry.localOffset + 30 > nextOffset || nextOffset > directoryOffset) {
        throw const _ExtractionFailure(
          'invalid_archive',
          'A DOCX ZIP entry has an invalid local extent.',
        );
      }
      input.setPositionSync(entry.localOffset);
      final local = input.readSync(30);
      if (local.length != 30 || _uint32(local, 0) != 0x04034b50) {
        throw const _ExtractionFailure(
          'invalid_archive',
          'A DOCX ZIP local header is invalid.',
        );
      }
      final localNameLength = _uint16(local, 26);
      final localExtraLength = _uint16(local, 28);
      final dataOffset =
          entry.localOffset + 30 + localNameLength + localExtraLength;
      if (_uint16(local, 6) != entry.flags ||
          _uint16(local, 8) != entry.compression ||
          dataOffset < entry.localOffset ||
          dataOffset + entry.compressedBytes > nextOffset) {
        throw const _ExtractionFailure(
          'invalid_archive',
          'A DOCX ZIP local header conflicts with its directory.',
        );
      }
      input.setPositionSync(entry.localOffset + 30);
      final localName = input.readSync(localNameLength);
      if (!_sameBytes(localName, entry.nameBytes)) {
        throw const _ExtractionFailure(
          'invalid_archive',
          'A DOCX ZIP local filename conflicts with its directory.',
        );
      }
      final dataEnd = dataOffset + entry.compressedBytes;
      if ((entry.flags & 0x08) != 0) {
        final descriptorBytes = nextOffset - dataEnd;
        if (descriptorBytes != 12 && descriptorBytes != 16) {
          throw const _ExtractionFailure(
            'invalid_archive',
            'A DOCX ZIP data descriptor has an invalid extent.',
          );
        }
        input.setPositionSync(dataEnd);
        final descriptor = input.readSync(descriptorBytes);
        final hasSignature =
            descriptorBytes == 16 && _uint32(descriptor, 0) == 0x08074b50;
        if ((!hasSignature && descriptorBytes != 12) ||
            _uint32(descriptor, hasSignature ? 4 : 0) != entry.crc32 ||
            _uint32(descriptor, hasSignature ? 8 : 4) !=
                entry.compressedBytes ||
            _uint32(descriptor, hasSignature ? 12 : 8) != entry.expandedBytes) {
          throw const _ExtractionFailure(
            'invalid_archive',
            'A DOCX ZIP data descriptor conflicts with its directory.',
          );
        }
      } else if (_uint32(local, 14) != entry.crc32 ||
          _uint32(local, 18) != entry.compressedBytes ||
          _uint32(local, 22) != entry.expandedBytes ||
          dataEnd != nextOffset) {
        throw const _ExtractionFailure(
          'invalid_archive',
          'A DOCX ZIP payload extent conflicts with its directory.',
        );
      }
      entry.dataOffset = dataOffset;
    }
    return _DocxPreflight(
      dataOffset: target.dataOffset,
      flags: target.flags,
      compression: target.compression,
      crc32: target.crc32,
      compressedBytes: target.compressedBytes,
      expandedBytes: target.expandedBytes,
    );
  } finally {
    input.closeSync();
  }
}

String _parseDocumentXml(List<int> bytes, DocumentExtractionLimits limits) {
  String raw;
  try {
    raw = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw _ExtractionFailure(
      'malformed_document_xml',
      'The DOCX document XML is not valid UTF-8.',
      expandedBytes: bytes.length,
    );
  }
  if (raw.contains(RegExp(r'<!DOCTYPE', caseSensitive: false))) {
    throw _ExtractionFailure(
      'unsafe_document_xml',
      'DOCX document XML containing a document type is unsupported.',
      expandedBytes: bytes.length,
    );
  }
  XmlDocument document;
  try {
    document = XmlDocument.parse(raw);
  } catch (_) {
    throw _ExtractionFailure(
      'malformed_document_xml',
      'The DOCX document XML is malformed.',
      expandedBytes: bytes.length,
    );
  }
  final output = StringBuffer();
  for (final node in document.descendants.whereType<XmlElement>()) {
    if (node.localName == 't') {
      output.write(node.innerText);
      output.write(' ');
    } else if (node.localName == 'p') {
      output.write('\n');
    }
  }
  final extracted = output.toString().trim();
  if (extracted.length > limits.maxExtractedTextCharacters) {
    throw _ExtractionFailure(
      'text_size_limit',
      'The extracted DOCX text exceeds its character limit.',
      expandedBytes: extracted.length,
      limitBytes: limits.maxExtractedTextCharacters,
    );
  }
  return extracted;
}

Map<String, Object?> _resultMessage(DocumentExtractionResult result) => {
  'extractedText': result.extractedText,
  'renderedMarkdown': result.renderedMarkdown,
  'sourceBytes': result.sourceBytes,
  'expandedBytes': result.expandedBytes,
  'warning': result.warning?.toJson(),
};

Map<String, Object?> _warningMessage(
  String format,
  _ExtractionFailure failure, {
  required int sourceBytes,
}) => {
  'extractedText': null,
  'renderedMarkdown': null,
  'sourceBytes': sourceBytes,
  'expandedBytes': failure.expandedBytes,
  'warning': DocumentExtractionWarning(
    code: failure.code,
    format: format,
    message: failure.message,
    sourceBytes: failure.sourceBytes ?? sourceBytes,
    expandedBytes: failure.expandedBytes,
    limitBytes: failure.limitBytes,
  ).toJson(),
};

int _uint16(List<int> bytes, int offset) {
  if (offset < 0 || offset + 2 > bytes.length) {
    throw const _ExtractionFailure(
      'invalid_archive',
      'The DOCX ZIP structure is truncated.',
    );
  }
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _uint32(List<int> bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw const _ExtractionFailure(
      'invalid_archive',
      'The DOCX ZIP structure is truncated.',
    );
  }
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class _SourceStamp {
  final int size;
  final int modifiedMicros;

  const _SourceStamp(this.size, this.modifiedMicros);
}

class _ExtractionFailure implements Exception {
  final String code;
  final String message;
  final int? sourceBytes;
  final int? expandedBytes;
  final int? limitBytes;

  const _ExtractionFailure(
    this.code,
    this.message, {
    this.sourceBytes,
    this.expandedBytes,
    this.limitBytes,
  });
}

class _DocxCentralEntry {
  final int flags;
  final int compression;
  final int crc32;
  final int compressedBytes;
  final int expandedBytes;
  final int localOffset;
  final Uint8List nameBytes;
  int dataOffset = -1;

  _DocxCentralEntry({
    required this.flags,
    required this.compression,
    required this.crc32,
    required this.compressedBytes,
    required this.expandedBytes,
    required this.localOffset,
    required this.nameBytes,
  });
}

class _DocxPreflight {
  final int dataOffset;
  final int flags;
  final int compression;
  final int crc32;
  final int compressedBytes;
  final int expandedBytes;

  const _DocxPreflight({
    required this.dataOffset,
    required this.flags,
    required this.compression,
    required this.crc32,
    required this.compressedBytes,
    required this.expandedBytes,
  });
}

class _BoundedCaptureSink extends OutputStreamBase {
  final int maximum;
  final List<int> _bytes = <int>[];

  _BoundedCaptureSink(this.maximum);

  List<int> get bytes => _bytes;

  @override
  int get length => _bytes.length;

  @override
  void flush() {}

  @override
  void writeByte(int value) => writeBytes([value]);

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    final count = len ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX inflater produced an invalid byte count.',
      );
    }
    if (_bytes.length + count > maximum) {
      throw _ExtractionFailure(
        'expanded_size_limit',
        'The DOCX document XML exceeds the actual expanded-size limit.',
        expandedBytes: _bytes.length + count,
        limitBytes: maximum,
      );
    }
    if (count == bytes.length) {
      _bytes.addAll(bytes);
    } else {
      _bytes.addAll(bytes.take(count));
    }
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    const chunkSize = 64 * 1024;
    while (!stream.isEOS) {
      final count = math.min(chunkSize, stream.length);
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  /// `archive`'s inflater calls this dynamically for DEFLATE back-references.
  List<int> subset(int start, [int? end]) {
    final absoluteStart = start < 0 ? _bytes.length + start : start;
    final absoluteEnd = end == null
        ? _bytes.length
        : end < 0
        ? _bytes.length + end
        : end;
    if (absoluteStart < 0 ||
        absoluteEnd < absoluteStart ||
        absoluteEnd > _bytes.length) {
      throw const _ExtractionFailure(
        'invalid_archive',
        'The DOCX DEFLATE stream contains an invalid history reference.',
      );
    }
    return _bytes.sublist(absoluteStart, absoluteEnd);
  }

  @override
  void writeUint16(int value) {
    writeByte(value);
    writeByte(value >> 8);
  }

  @override
  void writeUint32(int value) {
    writeUint16(value);
    writeUint16(value >> 16);
  }

  @override
  void writeUint64(int value) {
    writeUint32(value);
    writeUint32(value >> 32);
  }
}
