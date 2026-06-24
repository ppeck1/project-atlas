import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/document_preview.dart';

const _bg = Color(0xFF0F1115);
const _panel = Color(0xFF151A22);
const _line = Color(0xFF273044);
const _primary = Color(0xFF79A7FF);
const _text87 = Color(0xDEFFFFFF);
const _text54 = Color(0x8AFFFFFF);
const _text38 = Color(0x61FFFFFF);
const _green = Color(0xFF4CAF50);

// ─────────────────────────────────────────────────────────────────────────────
// Unified model
// ─────────────────────────────────────────────────────────────────────────────

class _LibraryEntry {
  final String id;
  final String title;
  final bool isDraft;
  final bool isMedia;
  final String? projectId;
  final String? extension;
  final String? content;
  final DateTime createdAt;
  final String? kind;
  final String? storedPath;
  final String? mediaType;
  final String? caption;
  final Document? document;

  const _LibraryEntry({
    required this.id,
    required this.title,
    required this.isDraft,
    this.isMedia = false,
    this.projectId,
    this.extension,
    this.content,
    required this.createdAt,
    this.kind,
    this.storedPath,
    this.mediaType,
    this.caption,
    this.document,
  });

  static const _imageExts = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
  };

  static _LibraryEntry fromDocument(Document d) {
    final isImage = _imageExts.contains(d.extension?.toLowerCase());
    return _LibraryEntry(
      id: d.id,
      title: d.title,
      isDraft: false,
      isMedia: isImage,
      projectId: d.projectId,
      extension: d.extension,
      content: d.renderedMarkdown ?? d.extractedText,
      createdAt: d.createdAt,
      storedPath: d.storedPath,
      mediaType: isImage ? 'image' : null,
      document: d,
    );
  }

  static _LibraryEntry fromMedia(ProjectMediaItem m) => _LibraryEntry(
    id: m.id,
    title: m.title,
    isDraft: false,
    isMedia: true,
    projectId: m.projectId,
    extension: m.extension,
    content: m.caption,
    createdAt: m.createdAt,
    storedPath: m.storedPath,
    mediaType: m.mediaType,
    caption: m.caption,
  );

  static _LibraryEntry fromDraft(Draft d) => _LibraryEntry(
    id: d.id,
    title: d.title,
    isDraft: true,
    projectId: d.projectId,
    content: d.body,
    createdAt: d.createdAt,
    kind: d.kind,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class LibraryScreen extends StatefulWidget {
  /// When provided (e.g. from a deep link), the matching entry is pre-selected.
  final String? initialEntryId;
  final String? initialEntryType;

  const LibraryScreen({super.key, this.initialEntryId, this.initialEntryType});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String? _selectedId;
  bool _selectedIsDraft = false;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String? _filterProjectId;
  String _filterType = 'all';

  @override
  void initState() {
    super.initState();
    if (widget.initialEntryId != null) {
      _selectedId = widget.initialEntryId;
      _selectedIsDraft = widget.initialEntryType == 'draft';
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<_LibraryEntry> _filter(List<_LibraryEntry> all) {
    var list = all;
    if (_filterProjectId != null) {
      list = list.where((e) => e.projectId == _filterProjectId).toList();
    }
    if (_filterType == 'documents') {
      list = list.where((e) => !e.isDraft && !e.isMedia).toList();
    } else if (_filterType == 'media') {
      list = list.where((e) => e.isMedia).toList();
    } else if (_filterType == 'images') {
      list = list.where((e) => e.mediaType == 'image').toList();
    } else if (_filterType == 'drafts') {
      list = list.where((e) => e.isDraft).toList();
    }
    final q = _searchQuery.toLowerCase().trim();
    if (q.isNotEmpty) {
      list = list.where((e) {
        if (e.title.toLowerCase().contains(q)) return true;
        if (e.content?.toLowerCase().contains(q) == true) return true;
        return false;
      }).toList();
    }
    return list;
  }

  Future<void> _importByPath() async {
    final state = AppStateScope.of(context);
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: [
        'txt', 'md', 'json', 'csv',
        'log', 'xml', 'yaml', 'yml', 'ini', 'toml', 'rst',
        'pdf', 'docx', 'doc',
        'html', 'htm', 'eml',
        'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
        'svg',
      ],
    );
    final path = result?.files.single.path;
    if (path == null || path.trim().isEmpty) return;
    try {
      await state.importDocumentFromPath(path);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Document imported.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Future<void> _openFile(String path) async {
    try {
      await Process.start('explorer.exe', [path]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Open failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return StreamBuilder<List<Project>>(
      stream: state.watchProjects(),
      builder: (context, projectSnap) {
        final projects = projectSnap.data ?? const <Project>[];

        return StreamBuilder<List<Document>>(
          stream: state.watchDocuments(),
          builder: (context, docSnap) {
            return StreamBuilder<List<Draft>>(
              stream: state.watchDrafts(),
              builder: (context, draftSnap) {
                return StreamBuilder<List<ProjectMediaItem>>(
                  stream: state.watchAllProjectMedia(),
                  builder: (context, mediaSnap) {
                    final docs = docSnap.data ?? const <Document>[];
                    final drafts = draftSnap.data ?? const <Draft>[];
                    final media = mediaSnap.data ?? const <ProjectMediaItem>[];

                    final all = [
                      ...media.map(_LibraryEntry.fromMedia),
                      ...docs.map(_LibraryEntry.fromDocument),
                      ...drafts.map(_LibraryEntry.fromDraft),
                    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

                    final filtered = _filter(all);

                    final selected = filtered
                        .where(
                          (e) =>
                              e.id == _selectedId &&
                              e.isDraft == _selectedIsDraft,
                        )
                        .firstOrNull;

                    return Scaffold(
                      backgroundColor: _bg,
                      body: Column(
                        children: [
                          _Header(
                            projects: projects,
                            filterProjectId: _filterProjectId,
                            filterType: _filterType,
                            searchCtrl: _searchCtrl,
                            onSearch: (q) => setState(() => _searchQuery = q),
                            onProjectFilter: (pid) =>
                                setState(() => _filterProjectId = pid),
                            onTypeFilter: (t) =>
                                setState(() => _filterType = t),
                            onImport: _importByPath,
                            totalCount: all.length,
                            filteredCount: filtered.length,
                          ),
                          const Divider(height: 1, color: _line),
                          Expanded(
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 320,
                                  child: filtered.isEmpty
                                      ? Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(24),
                                            child: Text(
                                              _searchQuery.isNotEmpty ||
                                                      _filterProjectId !=
                                                          null ||
                                                      _filterType != 'all'
                                                  ? 'No items match the current filters.'
                                                  : 'No documents, media, or drafts yet.\nImport a file to get started.',
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                color: _text38,
                                              ),
                                            ),
                                          ),
                                        )
                                      : ListView.builder(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 8,
                                          ),
                                          itemCount: filtered.length,
                                          itemBuilder: (ctx, i) {
                                            final entry = filtered[i];
                                            final isSel =
                                                _selectedId == entry.id &&
                                                _selectedIsDraft ==
                                                    entry.isDraft;
                                            return _EntryTile(
                                              entry: entry,
                                              projects: projects,
                                              isSelected: isSel,
                                              onTap: () => setState(() {
                                                _selectedId = entry.id;
                                                _selectedIsDraft =
                                                    entry.isDraft;
                                              }),
                                            );
                                          },
                                        ),
                                ),
                                const VerticalDivider(width: 1, color: _line),
                                Expanded(
                                  child: selected == null
                                      ? const Center(
                                          child: Text(
                                            'Select an item to view it.',
                                            style: TextStyle(color: _text38),
                                          ),
                                        )
                                      : _EntryViewer(
                                          entry: selected,
                                          projects: projects,
                                          onOpenFile:
                                              selected.storedPath != null
                                              ? () => _openFile(
                                                  selected.storedPath!,
                                                )
                                              : null,
                                          onDeleteDraft: selected.isDraft
                                              ? () async {
                                                  final ok = await showDialog<bool>(
                                                    context: context,
                                                    builder: (ctx) => AlertDialog(
                                                      backgroundColor: _panel,
                                                      title: const Text(
                                                        'Delete draft?',
                                                      ),
                                                      content: const Text(
                                                        'This cannot be undone.',
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                false,
                                                              ),
                                                          child: const Text(
                                                            'Cancel',
                                                          ),
                                                        ),
                                                        FilledButton(
                                                          style:
                                                              FilledButton.styleFrom(
                                                                backgroundColor:
                                                                    Colors.red,
                                                              ),
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                true,
                                                              ),
                                                          child: const Text(
                                                            'Delete',
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                  if (ok == true && mounted) {
                                                    await state.deleteDraft(
                                                      selected.id,
                                                    );
                                                    setState(
                                                      () => _selectedId = null,
                                                    );
                                                  }
                                                }
                                              : null,
                                          onDeleteDoc: selected.document != null && !selected.isDraft
                                              ? () async {
                                                  final ok = await showDialog<bool>(
                                                    context: context,
                                                    builder: (ctx) => AlertDialog(
                                                      backgroundColor: _panel,
                                                      title: Text(
                                                        'Delete ${selected.title}?',
                                                      ),
                                                      content: const Text(
                                                        'This permanently removes the file from disk.',
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                false,
                                                              ),
                                                          child: const Text(
                                                            'Cancel',
                                                          ),
                                                        ),
                                                        FilledButton(
                                                          style:
                                                              FilledButton.styleFrom(
                                                                backgroundColor:
                                                                    Colors.red,
                                                              ),
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                true,
                                                              ),
                                                          child: const Text(
                                                            'Delete',
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                  if (ok == true && mounted) {
                                                    await state.deleteDocument(
                                                      selected.document!.id,
                                                    );
                                                    setState(
                                                      () => _selectedId = null,
                                                    );
                                                  }
                                                }
                                              : null,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header bar
// ─────────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final List<Project> projects;
  final String? filterProjectId;
  final String filterType;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onProjectFilter;
  final ValueChanged<String> onTypeFilter;
  final VoidCallback onImport;
  final int totalCount;
  final int filteredCount;

  const _Header({
    required this.projects,
    required this.filterProjectId,
    required this.filterType,
    required this.searchCtrl,
    required this.onSearch,
    required this.onProjectFilter,
    required this.onTypeFilter,
    required this.onImport,
    required this.totalCount,
    required this.filteredCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _panel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Text(
            'Library',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _text87,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: searchCtrl,
              onChanged: onSearch,
              style: const TextStyle(color: _text87, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search title and content...',
                hintStyle: const TextStyle(color: _text38, fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 18, color: _text54),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                isDense: true,
                filled: true,
                fillColor: _bg,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _primary),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _Dropdown<String?>(
            value: filterProjectId,
            items: [
              const DropdownMenuItem(value: null, child: Text('All projects')),
              ...projects.map(
                (p) => DropdownMenuItem(
                  value: p.id,
                  child: Text(p.title, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged: onProjectFilter,
            width: 160,
          ),
          const SizedBox(width: 8),
          _Dropdown<String>(
            value: filterType,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All types')),
              DropdownMenuItem(value: 'documents', child: Text('Documents')),
              DropdownMenuItem(value: 'media', child: Text('Media')),
              DropdownMenuItem(value: 'images', child: Text('Images')),
              DropdownMenuItem(value: 'drafts', child: Text('AI Drafts')),
            ],
            onChanged: (v) {
              if (v != null) onTypeFilter(v);
            },
            width: 130,
          ),
          const SizedBox(width: 12),
          filteredCount != totalCount
              ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _primary.withAlpha(30),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _primary.withAlpha(80)),
                  ),
                  child: Text(
                    '$filteredCount / $totalCount',
                    style: const TextStyle(fontSize: 11, color: _primary),
                  ),
                )
              : Text(
                  '$totalCount items',
                  style: const TextStyle(fontSize: 12, color: _text38),
                ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.upload_file, size: 16),
            label: const Text('Import'),
            style: FilledButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: _bg,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double width;

  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          style: const TextStyle(color: _text87, fontSize: 13),
          dropdownColor: _panel,
          isDense: true,
          iconSize: 16,
          iconEnabledColor: _text54,
          isExpanded: true,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry tile (list item)
// ─────────────────────────────────────────────────────────────────────────────

class _EntryTile extends StatelessWidget {
  final _LibraryEntry entry;
  final List<Project> projects;
  final bool isSelected;
  final VoidCallback onTap;

  const _EntryTile({
    required this.entry,
    required this.projects,
    required this.isSelected,
    required this.onTap,
  });

  IconData _icon() {
    if (entry.isDraft) return Icons.auto_awesome;
    if (entry.mediaType == 'image') return Icons.image_outlined;
    if (entry.isMedia) return Icons.perm_media_outlined;
    return switch (entry.extension?.toLowerCase()) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'md' => Icons.article_outlined,
      'docx' || 'doc' => Icons.description_outlined,
      'txt' => Icons.text_snippet_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final project = projects.where((p) => p.id == entry.projectId).firstOrNull;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? _primary.withAlpha(25) : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isSelected ? _primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                _icon(),
                size: 18,
                color: entry.isDraft ? _green : _text54,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: isSelected ? _primary : _text87,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (entry.isDraft) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: _green.withAlpha(35),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: _green.withAlpha(90)),
                          ),
                          child: const Text(
                            'AI Draft',
                            style: TextStyle(
                              fontSize: 9,
                              color: _green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      if (entry.isMedia) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: _primary.withAlpha(35),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: _primary.withAlpha(90)),
                          ),
                          child: Text(
                            entry.mediaType == 'image' ? 'Image' : 'Media',
                            style: const TextStyle(
                              fontSize: 9,
                              color: _primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (project != null) ...[
                        const Icon(Icons.folder_open, size: 11, color: _text38),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            project.title,
                            style: const TextStyle(
                              fontSize: 11,
                              color: _text38,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ] else
                        const Expanded(
                          child: Text(
                            'No project',
                            style: TextStyle(fontSize: 11, color: _text38),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry viewer (right pane)
// ─────────────────────────────────────────────────────────────────────────────

class _EntryViewer extends StatelessWidget {
  final _LibraryEntry entry;
  final List<Project> projects;
  final VoidCallback? onOpenFile;
  final VoidCallback? onDeleteDraft;
  final VoidCallback? onDeleteDoc;

  const _EntryViewer({
    required this.entry,
    required this.projects,
    this.onOpenFile,
    this.onDeleteDraft,
    this.onDeleteDoc,
  });

  String _formatDate(DateTime dt) {
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final project = projects.where((p) => p.id == entry.projectId).firstOrNull;
    final content = entry.content;
    final imageFile = entry.mediaType == 'image' && entry.storedPath != null
        ? File(entry.storedPath!)
        : null;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (entry.isDraft)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _green.withAlpha(35),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: _green.withAlpha(90)),
                        ),
                        child: Text(
                          'AI Draft${entry.kind != null ? ' · ${entry.kind}' : ''}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: _green,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Text(
                      entry.title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: _text87,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (project != null) ...[
                          const Icon(
                            Icons.folder_open,
                            size: 13,
                            color: _text38,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            project.title,
                            style: const TextStyle(
                              fontSize: 12,
                              color: _text54,
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        const Icon(Icons.schedule, size: 13, color: _text38),
                        const SizedBox(width: 4),
                        Text(
                          _formatDate(entry.createdAt),
                          style: const TextStyle(fontSize: 12, color: _text54),
                        ),
                        if (!entry.isDraft && entry.extension != null) ...[
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: _line,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '.${entry.extension!.toUpperCase()}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: _text54,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Action buttons
              Wrap(
                spacing: 8,
                children: [
                  if (onOpenFile != null)
                    _ActionBtn(
                      icon: Icons.open_in_new,
                      label: 'Open file',
                      onTap: onOpenFile!,
                    ),
                  if (content != null && content.isNotEmpty)
                    _ActionBtn(
                      icon: Icons.copy,
                      label: 'Copy',
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: content));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard.')),
                        );
                      },
                    ),
                  if (onDeleteDraft != null)
                    _ActionBtn(
                      icon: Icons.delete_outline,
                      label: 'Delete',
                      onTap: onDeleteDraft!,
                      danger: true,
                    ),
                  if (onDeleteDoc != null)
                    _ActionBtn(
                      icon: Icons.delete_outline,
                      label: 'Delete',
                      onTap: onDeleteDoc!,
                      danger: true,
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: _line),
          const SizedBox(height: 12),
          Expanded(
            child: imageFile != null
                ? Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: _panel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _line),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: imageFile.existsSync()
                        ? InteractiveViewer(
                            child: Image.file(imageFile, fit: BoxFit.contain),
                          )
                        : const Center(
                            child: Text(
                              'Image file is missing.',
                              style: TextStyle(color: _text38),
                            ),
                          ),
                  )
                : entry.document != null
                ? DocumentPreview(document: entry.document!)
                : content == null || content.isEmpty
                ? const Center(
                    child: Text(
                      'No content available.',
                      style: TextStyle(color: _text38),
                    ),
                  )
                : Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: _panel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _line),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: SelectableText(
                        content,
                        style: const TextStyle(
                          fontSize: 13,
                          color: _text87,
                          height: 1.65,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? Colors.red : _text54;
    final borderColor = danger ? Colors.red.withAlpha(80) : _line;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 14),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: borderColor),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        textStyle: const TextStyle(fontSize: 12),
      ),
    );
  }
}
