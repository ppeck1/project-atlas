import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../db/app_db.dart';

class DocumentPreview extends StatelessWidget {
  final Document document;

  const DocumentPreview({super.key, required this.document});

  Future<String?> _loadText() async {
    final stored = document.storedPath;
    if (stored == null || stored.isEmpty) return null;
    final file = File(stored);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  String get _extension =>
      (document.extension ?? document.originalFilename.split('.').last)
          .toLowerCase();

  @override
  Widget build(BuildContext context) {
    final parsed = document.renderedMarkdown ?? document.extractedText;
    return FutureBuilder<String?>(
      future: parsed == null || parsed.isEmpty ? _loadText() : null,
      builder: (context, snapshot) {
        final body = parsed ?? snapshot.data ?? '';
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        return _renderBody(context, body);
      },
    );
  }

  Widget _renderBody(BuildContext context, String body) {
    final ext = _extension;
    if (ext == 'md' || document.mimeType == 'text/markdown') {
      return Markdown(
        data: body.isEmpty ? '_No markdown content available._' : body,
        selectable: true,
        padding: const EdgeInsets.all(16),
      );
    }

    if (ext == 'json' || document.mimeType == 'application/json') {
      final pretty = _prettyJson(body);
      return _CodeBlock(
        text: pretty ?? body,
        empty: 'No JSON content available.',
      );
    }

    if (ext == 'txt' ||
        ext == 'csv' ||
        document.mimeType?.startsWith('text/') == true) {
      return _CodeBlock(text: body, empty: 'No text content available.');
    }

    if (ext == 'pdf' || ext == 'docx' || ext == 'doc') {
      return _UnsupportedDocumentStatus(document: document);
    }

    return _CodeBlock(
      text: body,
      empty: 'No preview is available for this document type yet.',
    );
  }

  String? _prettyJson(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}

class _CodeBlock extends StatelessWidget {
  final String text;
  final String empty;

  const _CodeBlock({required this.text, required this.empty});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        text.trim().isEmpty ? empty : text,
        style: const TextStyle(fontFamily: 'monospace', height: 1.45),
      ),
    );
  }
}

class _UnsupportedDocumentStatus extends StatelessWidget {
  final Document document;

  const _UnsupportedDocumentStatus({required this.document});

  @override
  Widget build(BuildContext context) {
    final stored = document.storedPath;
    final error = document.parseError;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                document.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Original file: ${stored == null || stored.isEmpty ? 'not stored' : stored}',
              ),
              const SizedBox(height: 8),
              Text(
                'Parsing status: ${error == null || error.isEmpty ? 'parser not implemented yet' : error}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
