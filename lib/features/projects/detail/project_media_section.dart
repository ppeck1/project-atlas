import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../db/app_db.dart';
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

class ProjectMediaSection extends StatefulWidget {
  final String projectId;
  final VoidCallback onImportMedia;

  const ProjectMediaSection({
    super.key,
    required this.projectId,
    required this.onImportMedia,
  });

  @override
  State<ProjectMediaSection> createState() => _ProjectMediaSectionState();
}

class _ProjectMediaSectionState extends State<ProjectMediaSection> {
  Stream<List<ProjectMediaItem>>? _watchMedia;
  Stream<List<Document>>? _watchDocuments;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchMedia ??=
        AppStateScope.of(context).watchProjectMedia(widget.projectId);
    _watchDocuments ??=
        AppStateScope.of(context).watchDocumentsForProject(widget.projectId);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return StreamBuilder<List<ProjectMediaItem>>(
      stream: _watchMedia,
      builder: (context, mediaSnap) {
        final media = mediaSnap.data ?? const <ProjectMediaItem>[];
        final cover = media.where((item) => item.isCover).firstOrNull;
        return StreamBuilder<List<Document>>(
          stream: _watchDocuments,
          builder: (context, docSnap) {
            final docs = docSnap.data ?? const <Document>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cover != null && cover.mediaType == 'image') ...[
                  _CoverImage(item: cover),
                  const SizedBox(height: 12),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: widget.onImportMedia,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 16,
                      ),
                      label: const Text('Add image/file'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          context.go(libraryRouteForProject(widget.projectId)),
                      icon: const Icon(Icons.library_books_outlined, size: 16),
                      label: const Text('Open Library'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (media.isEmpty && docs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'No media or documents linked to this project yet.',
                      style: TextStyle(fontSize: 13, color: Colors.white38),
                    ),
                  ),
                if (media.isNotEmpty) ...[
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 190,
                          mainAxisExtent: 190,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: media.length,
                    itemBuilder: (context, i) => _MediaTile(
                      item: media[i],
                      onSetCover: () => state.setProjectCoverMedia(
                          widget.projectId, media[i].id),
                      onDelete: () => state.deleteProjectMedia(media[i].id),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (docs.isNotEmpty)
                  ...docs.map(
                    (d) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: () => context.go(
                          libraryRouteForProject(
                            widget.projectId,
                            entryType: 'document',
                            entryId: d.id,
                          ),
                        ),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(
                                Icons.description_outlined,
                                size: 16,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      d.title,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      d.originalFilename,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right,
                                size: 16,
                                color: Colors.white24,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _CoverImage extends StatelessWidget {
  final ProjectMediaItem item;

  const _CoverImage({required this.item});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    final file = File(item.storedPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 16 / 7,
        child: file.existsSync()
            ? Image.file(file, fit: BoxFit.cover)
            : Container(
                color: colors.bg,
                alignment: Alignment.center,
                child: const Text(
                  'Cover file is missing',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  final ProjectMediaItem item;
  final VoidCallback onSetCover;
  final VoidCallback onDelete;

  const _MediaTile({
    required this.item,
    required this.onSetCover,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    final file = File(item.storedPath);
    final isImage = item.mediaType == 'image';
    return Container(
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.all(color: item.isCover ? colors.primary : colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              // TODO(paul): near-miss of AtlasColors.surfaceDeep (0xFF10141B).
              color: const Color(0xFF10151E),
              child: isImage && file.existsSync()
                  ? Image.file(file, fit: BoxFit.cover)
                  : Icon(
                      isImage
                          ? Icons.broken_image_outlined
                          : item.mediaType == 'folder'
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                      color: Colors.white38,
                      size: 32,
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ((item.caption ?? '').isNotEmpty)
                  Text(
                    item.caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                Row(
                  children: [
                    if (!item.isCover)
                      IconButton(
                        tooltip: 'Use as cover',
                        onPressed: isImage ? onSetCover : null,
                        icon: const Icon(Icons.wallpaper, size: 16),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Remove media',
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 16),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
