import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/document_preview.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  Document? _selected;
  String _status = '';

  Future<void> _importByPath() async {
    final c = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import document'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(
            labelText: 'Local file path',
            hintText: r'C:\Users\you\Documents\spec.md',
          ),
          autofocus: true,
          onSubmitted: (_) => Navigator.of(context).pop(c.text.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(c.text.trim()), child: const Text('Import')),
        ],
      ),
    );
    if (path == null || path.trim().isEmpty) return;
    if (!mounted) return;
    final state = AppStateScope.of(context);
    setState(() => _status = 'Importing...');
    try {
      await state.importDocumentFromPath(path);
      if (mounted) setState(() => _status = 'Imported document.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Import failed: $e');
    }
  }

  Future<void> _openOriginal(Document doc) async {
    final path = doc.storedPath;
    if (path == null || path.isEmpty) return;
    try {
      await Process.start('explorer.exe', [path]);
      if (mounted) setState(() => _status = 'Opened original file.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Open failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          FilledButton.icon(onPressed: _importByPath, icon: const Icon(Icons.upload_file), label: const Text('Import')),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 340,
            child: StreamBuilder<List<Document>>(
              stream: state.watchDocuments(),
              builder: (context, snap) {
                final docs = snap.data ?? const <Document>[];
                if (docs.isEmpty) {
                  return const Center(child: Text('No documents imported yet.'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    return Card(
                      child: ListTile(
                        selected: _selected?.id == d.id,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${d.status}${d.extension != null ? ' · .${d.extension}' : ''}'),
                        onTap: () => setState(() => _selected = d),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _selected == null
                  ? const Center(child: Text('Select a document.'))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_selected!.title, style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 6),
                        Text('Status: ${_selected!.status} | Stored: ${_selected!.storedPath ?? 'n/a'}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        if (_status.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(_status, style: const TextStyle(fontSize: 12)),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(onPressed: () => _openOriginal(_selected!), icon: const Icon(Icons.open_in_new), label: const Text('Open original')),
                            OutlinedButton.icon(
                              onPressed: (_selected!.extractedText ?? _selected!.renderedMarkdown) == null
                                  ? null
                                  : () {
                                      Clipboard.setData(ClipboardData(text: _selected!.extractedText ?? _selected!.renderedMarkdown ?? ''));
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied document text.')));
                                    },
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy text'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(color: Colors.white.withAlpha(8), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
                            child: SingleChildScrollView(
                              child: DocumentPreview(document: _selected!),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
