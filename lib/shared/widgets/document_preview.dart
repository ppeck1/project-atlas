import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../db/app_db.dart';
import '../../db/document_extractor.dart'
    show DocumentExtractionLimits, shouldLoadDocumentText;

class DocumentPreview extends StatelessWidget {
  final Document document;

  const DocumentPreview({super.key, required this.document});

  Future<String?> _loadText() async {
    final stored = document.storedPath;
    if (stored == null || stored.isEmpty) return null;
    final file = File(stored);
    if (!await file.exists()) return null;
    const limits = DocumentExtractionLimits();
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, limits.maxSourceBytes + 1)) {
      bytes.addAll(chunk);
      if (bytes.length > limits.maxSourceBytes) return null;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  bool get _shouldLoadText => shouldLoadDocumentText(_extension);

  String? get _warningMessage {
    final raw = document.parseError?.trim();
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final message = decoded['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    } catch (_) {
      // Older rows may contain a plain-text parse error.
    }
    return raw;
  }

  String get _extension =>
      (document.extension ?? document.originalFilename.split('.').last)
          .toLowerCase();

  @override
  Widget build(BuildContext context) {
    final parsed = document.renderedMarkdown ?? document.extractedText;
    final warningMessage = _warningMessage;
    return FutureBuilder<String?>(
      future:
          warningMessage == null &&
              (parsed == null || parsed.isEmpty) &&
              _shouldLoadText
          ? _loadText()
          : null,
      builder: (context, snapshot) {
        final body = parsed ?? snapshot.data ?? '';
        if (snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final preview = _renderBody(context, body);
        if (warningMessage == null) return preview;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.amber.withAlpha(28),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.amber,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Text preview unavailable: $warningMessage',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: preview),
          ],
        );
      },
    );
  }

  Widget _renderBody(BuildContext context, String body) {
    final ext = _extension;
    if (ext == 'md' || ext == 'mdx' || document.mimeType == 'text/markdown') {
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

    if (ext == 'html' || ext == 'htm') {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Html(
          data: body.isEmpty ? '<p>No HTML content available.</p>' : body,
        ),
      );
    }

    if (ext == 'eml') {
      return _CodeBlock(text: body, empty: 'No email content available.');
    }

    if (ext == 'txt' ||
        ext == 'csv' ||
        document.mimeType?.startsWith('text/') == true) {
      return _CodeBlock(text: body, empty: 'No text content available.');
    }

    if (ext == 'pdf') {
      return _ExternalViewerPrompt(document: document);
    }

    if (ext == 'docx' || ext == 'doc') {
      return body.isNotEmpty
          ? _CodeBlock(text: body, empty: 'No text content available.')
          : _ExternalViewerPrompt(document: document);
    }

    if (ext == 'rtf') {
      return _ExternalViewerPrompt(document: document);
    }

    if (ext == 'svg') {
      return _ExternalViewerPrompt(document: document);
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

class _ExternalViewerPrompt extends StatelessWidget {
  final Document document;

  const _ExternalViewerPrompt({required this.document});

  @override
  Widget build(BuildContext context) {
    final stored = document.storedPath;
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
                'In-app preview is not available for this format.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (stored != null && stored.isNotEmpty) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => launchUrl(Uri.file(stored)),
                  child: const Text('Open in system viewer'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
