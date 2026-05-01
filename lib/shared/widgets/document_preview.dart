import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../db/app_db.dart';

class DocumentPreview extends StatelessWidget {
  final Document document;

  const DocumentPreview({super.key, required this.document});

  @override
  Widget build(BuildContext context) {
    final ext = (document.extension ?? '').toLowerCase();
    final text = document.extractedText ?? document.renderedMarkdown;

    if (document.parseError != null) {
      return SelectableText('Parse failed:\n${document.parseError}');
    }

    if (ext == 'md') {
      return MarkdownBody(data: text ?? 'No markdown preview available.');
    }

    if (ext == 'json') {
      return SelectableText(_prettyJson(text));
    }

    if (ext == 'txt' || ext == 'csv') {
      return SelectableText(text ?? 'No text preview available.');
    }

    if (ext == 'pdf' || ext == 'docx') {
      return SelectableText(
        [
          'Stored original file.',
          'Status: ${document.status}',
          if (document.storedPath != null) 'Path: ${document.storedPath}',
          'Parser preview is not implemented yet.',
        ].join('\n'),
      );
    }

    return SelectableText(
      document.renderedMarkdown ?? 'No renderable preview available.',
    );
  }

  String _prettyJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 'No JSON preview available.';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }
}
