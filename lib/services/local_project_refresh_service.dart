import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class LocalProjectRefreshPlan {
  final String profile;
  final String rootPath;
  final List<LocalProjectRefreshAction> actions;
  final List<String> warnings;

  const LocalProjectRefreshPlan({
    required this.profile,
    required this.rootPath,
    required this.actions,
    required this.warnings,
  });
}

class LocalProjectRefreshAction {
  final String sourceKind;
  final String sourceKey;
  final String targetType;
  final String title;
  final String detail;
  final String fingerprint;
  final Map<String, Object?> payload;

  const LocalProjectRefreshAction({
    required this.sourceKind,
    required this.sourceKey,
    required this.targetType,
    required this.title,
    required this.detail,
    required this.fingerprint,
    required this.payload,
  });

  String get id => '$sourceKind::$sourceKey';
}

class LocalProjectRefreshPreview {
  final String registryId;
  final String projectId;
  final String localPath;
  final String profile;
  final String? branch;
  final String? headSha;
  final int? dirtyCount;
  final String? remoteUrl;
  final DateTime? observedAt;
  final List<LocalProjectRefreshPreviewEntry> entries;
  final List<String> warnings;

  const LocalProjectRefreshPreview({
    required this.registryId,
    required this.projectId,
    required this.localPath,
    required this.profile,
    required this.entries,
    required this.warnings,
    this.branch,
    this.headSha,
    this.dirtyCount,
    this.remoteUrl,
    this.observedAt,
  });
}

class LocalProjectRefreshPreviewEntry {
  final LocalProjectRefreshAction action;
  final String status;
  final String? existingTargetId;

  const LocalProjectRefreshPreviewEntry({
    required this.action,
    required this.status,
    this.existingTargetId,
  });

  bool get shouldApplyByDefault => status == 'new' || status == 'changed';
}

class LocalProjectRefreshApplyResult {
  final int created;
  final int updated;
  final int unchanged;
  final int skipped;
  final List<String> warnings;

  const LocalProjectRefreshApplyResult({
    required this.created,
    required this.updated,
    required this.unchanged,
    required this.skipped,
    required this.warnings,
  });
}

class LocalProjectRefreshService {
  const LocalProjectRefreshService();

  static const int maxImportedDocumentBytes = 2 * 1024 * 1024;
  static const int maxRefreshDocumentActions = 10000;

  static const int maxSourceFileBytes = 256 * 1024;
  static const int maxCardSourceBytes = 1024 * 1024;
  static const int maxSourceFileActions = 250;
  static const int maxCardActions = 250;

  static const List<String> operationDocNames = [
    'README.md',
    'ACTIVE_TASK.md',
    'CURRENT_STATE.md',
    'HANDOFF.md',
    'AGENTS.md',
    'CLAUDE.md',
    'DECISIONS.md',
    'ROADMAP.md',
    'ACCEPTANCE.md',
    'OPERATIONS.md',
    'VARIABLE_MATRIX.md',
    'CHANGELOG_AGENT.md',
    'EXPORT_MANIFEST.md',
  ];

  static const String projectManifestRelativePath = '.project/launchpad.json';

  static const Set<String> mediaExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'tif',
    'tiff',
    'svg',
    'mp4',
    'mov',
    'avi',
    'mkv',
    'webm',
    'm4v',
    'wmv',
    'mp3',
    'wav',
    'm4a',
    'aac',
    'ogg',
    'flac',
  };

  static const Set<String> sourceFileExtensions = {
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
    'html',
    'htm',
    'java',
    'js',
    'json',
    'jsonc',
    'jsx',
    'kt',
    'kts',
    'less',
    'lua',
    'md',
    'mdx',
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
    'toml',
    'ts',
    'tsx',
    'txt',
    'vue',
    'xml',
    'yaml',
    'yml',
    'zsh',
  };

  static const Set<String> commonDocumentExtensions = {
    'csv',
    'doc',
    'docx',
    'eml',
    'html',
    'htm',
    'json',
    'md',
    'mdx',
    'pdf',
    'rtf',
    'rst',
    'txt',
    'yaml',
    'yml',
  };

  static const Set<String> safeExtensionlessSourceNames = {
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    'CMakeLists.txt',
    'Containerfile',
    'Dockerfile',
    'Makefile',
  };

  static const Set<String> softwareMarkerNames = {
    'package.json',
    'pubspec.yaml',
    'pyproject.toml',
    'Cargo.toml',
    'go.mod',
    'pom.xml',
    'build.gradle',
    'CMakeLists.txt',
    'requirements.txt',
  };

  static const Set<String> softwareSourceExtensions = {
    'bat',
    'bash',
    'c',
    'cc',
    'cjs',
    'cmd',
    'cpp',
    'cs',
    'css',
    'cxx',
    'dart',
    'go',
    'gradle',
    'graphql',
    'h',
    'hpp',
    'htm',
    'html',
    'java',
    'js',
    'jsx',
    'kt',
    'kts',
    'less',
    'm',
    'mjs',
    'mm',
    'php',
    'proto',
    'ps1',
    'psm1',
    'py',
    'rb',
    'rs',
    'sass',
    'scss',
    'sh',
    'sql',
    'swift',
    'toml',
    'ts',
    'tsx',
    'xml',
    'yaml',
    'yml',
    'json',
  };

  Future<LocalProjectRefreshPlan> buildPlan(String rootPath) async {
    final root = Directory(rootPath);
    final warnings = <String>[];
    if (!await root.exists()) {
      return LocalProjectRefreshPlan(
        profile: 'unknown',
        rootPath: rootPath,
        actions: const [],
        warnings: ['Local path does not exist: $rootPath'],
      );
    }

    final manifest = await _readLaunchpadManifest(root, warnings);
    final files = <String, File>{};
    Future<void> addDocumentPath(String relativePath) async {
      final normalized = _normalizeRelativePath(relativePath);
      if (normalized == null) return;
      final file = File(p.join(root.path, normalized));
      if (await file.exists()) files[normalized] = file;
    }

    for (final name in operationDocNames) {
      await addDocumentPath(name);
    }
    if (manifest != null) {
      for (final docPath in _manifestDocPaths(manifest)) {
        await addDocumentPath(docPath);
      }
    }
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('HANDOFF_REPORT') && name.endsWith('.md')) {
        files[name] = entity;
      }
    }

    final textByPath = <String, String>{};
    for (final entry in files.entries) {
      try {
        textByPath[entry.key] = await entry.value.readAsString();
      } catch (error) {
        warnings.add('${entry.key}: could not read text: $error');
      }
    }
    final docsByName = _canonicalDocsByName(textByPath);
    final scannedFiles = _scanRefreshFiles(root, warnings);

    final actions = <LocalProjectRefreshAction>[
      ..._docActions(files),
      ..._mediaActions(scannedFiles),
      ..._sourceFileActions(
        scannedFiles,
        warnings,
        excludedRelativePaths: {...files.keys, projectManifestRelativePath},
      ),
      ..._cardLibraryActions(scannedFiles, warnings),
      ..._projectMetaActions(manifest, docsByName),
      ..._decisionActions(_docText(docsByName, 'DECISIONS.md')?.text),
      ..._activeTaskActions(_docText(docsByName, 'ACTIVE_TASK.md')?.text),
      ..._roadmapActions(_docText(docsByName, 'ROADMAP.md')?.text),
      ..._currentStateActions(_docText(docsByName, 'CURRENT_STATE.md')?.text),
      ..._handoffActions(_docText(docsByName, 'HANDOFF.md')),
    ];

    return LocalProjectRefreshPlan(
      profile: _looksLikeBoh(docsByName, root.path) ? 'boh' : 'generic',
      rootPath: root.path,
      actions: actions,
      warnings: warnings,
    );
  }

  List<LocalProjectRefreshAction> _docActions(Map<String, File> files) {
    final actions = <LocalProjectRefreshAction>[];
    final names = files.keys.toList()..sort();
    for (final name in names) {
      final file = files[name]!;
      final stat = file.statSync();
      final fingerprint = _fingerprint('$name|${stat.size}|${stat.modified}');
      actions.add(
        LocalProjectRefreshAction(
          sourceKind: 'document',
          sourceKey: name,
          targetType: 'document',
          title: name,
          detail: file.path,
          fingerprint: fingerprint,
          payload: {
            'path': file.path,
            'filename': name,
            'title': name,
            'source': 'local_refresh:document:$name',
            'metadataJson': jsonEncode({
              'refreshSourceKind': 'document',
              'relativePath': name,
            }),
          },
        ),
      );
    }
    return actions;
  }

  List<LocalProjectRefreshAction> _mediaActions(List<_RefreshFile> files) {
    return files
        .where((file) => mediaExtensions.contains(file.extension))
        .map((file) {
          final filename = p.basename(file.file.path);
          return LocalProjectRefreshAction(
            sourceKind: 'media',
            sourceKey: file.relativePath,
            targetType: 'media',
            title: filename,
            detail: file.relativePath,
            fingerprint: _fingerprint(
              '${file.relativePath}|${file.stat.size}|${file.stat.modified.toIso8601String()}',
            ),
            payload: {
              'path': file.file.path,
              'filename': filename,
              'title': filename,
              'relativePath': file.relativePath,
            },
          );
        })
        .toList(growable: false);
  }

  List<LocalProjectRefreshAction> _sourceFileActions(
    List<_RefreshFile> files,
    List<String> warnings, {
    Set<String> excludedRelativePaths = const {},
  }) {
    final actions = <LocalProjectRefreshAction>[];
    var skippedLarge = 0;
    var skippedByCap = 0;

    for (final file in files) {
      if (!softwareSourceExtensions.contains(file.extension)) continue;
      if (excludedRelativePaths.contains(file.relativePath)) continue;
      if (_isProjectManifestPath(file.relativePath)) continue;
      if (_isFixtureLikeSourceDuplicate(file.relativePath)) continue;
      if (_looksLikeCardLibrarySource(file.relativePath)) continue;
      if (file.stat.size > maxSourceFileBytes) {
        skippedLarge++;
        continue;
      }
      if (actions.length >= maxSourceFileActions) {
        skippedByCap++;
        continue;
      }
      actions.add(
        LocalProjectRefreshAction(
          sourceKind: 'source_file',
          sourceKey: file.relativePath,
          targetType: 'document',
          title: file.relativePath,
          detail: 'Software source file (${file.stat.size} bytes).',
          fingerprint: _fingerprint(
            'source_file|${file.relativePath}|${file.stat.size}|${file.stat.modified.toIso8601String()}',
          ),
          payload: {
            'path': file.file.path,
            'filename': file.relativePath,
            'title': file.relativePath,
            'relativePath': file.relativePath,
            'source': 'local_refresh:source_file:${file.relativePath}',
            'metadataJson': jsonEncode({
              'refreshSourceKind': 'source_file',
              'relativePath': file.relativePath,
              'byteSize': file.stat.size,
              'modifiedAt': file.stat.modified.toIso8601String(),
            }),
            'sourceCategory': 'software_source',
            'byteSize': file.stat.size,
          },
        ),
      );
    }

    if (skippedLarge > 0) {
      warnings.add(
        'Skipped $skippedLarge source file(s) over ${_formatBytes(maxSourceFileBytes)}.',
      );
    }
    if (skippedByCap > 0) {
      warnings.add(
        'Source file refresh plan capped at $maxSourceFileActions actions; skipped $skippedByCap additional candidate(s).',
      );
    }
    return actions;
  }

  List<LocalProjectRefreshAction> _cardLibraryActions(
    List<_RefreshFile> files,
    List<String> warnings,
  ) {
    final actions = <LocalProjectRefreshAction>[];
    var skippedLarge = 0;
    var skippedByCap = 0;

    void add(LocalProjectRefreshAction action) {
      if (actions.length >= maxCardActions) {
        skippedByCap++;
        return;
      }
      actions.add(action);
    }

    for (final file in files) {
      if (!_looksLikeCardLibrarySource(file.relativePath)) continue;
      if (file.stat.size > maxCardSourceBytes) {
        skippedLarge++;
        continue;
      }

      String text;
      try {
        text = file.file.readAsStringSync();
      } catch (error) {
        warnings.add(
          '${file.relativePath}: could not read card source: $error',
        );
        continue;
      }

      if (_isTradeCraftCardMarkdown(file.relativePath)) {
        add(
          _generatedDocumentAction(
            file: file,
            sourceKey: '${file.relativePath}#card',
            library: 'trade_craft',
            pattern: 'cards/*.md',
            format: 'markdown',
            title:
                _markdownTitle(text) ?? _titleFromFilename(file.relativePath),
            body: text,
          ),
        );
      } else if (_isProductivityGoalCard(file.relativePath)) {
        add(
          _generatedDocumentAction(
            file: file,
            sourceKey: '${file.relativePath}#card',
            library: 'productivity',
            pattern: '*.goalcard.md',
            format: 'markdown',
            title:
                _markdownTitle(text) ?? _titleFromFilename(file.relativePath),
            body: text,
          ),
        );
      } else if (_isPhilosophyJsonCards(file.relativePath)) {
        for (final action in _philosophyJsonCardActions(file, text, warnings)) {
          add(action);
        }
      } else if (_isPreIndustrializationHtml(file.relativePath)) {
        for (final action in _preIndustrializationHtmlActions(file, text)) {
          add(action);
        }
      }
    }

    if (skippedLarge > 0) {
      warnings.add(
        'Skipped $skippedLarge card source file(s) over ${_formatBytes(maxCardSourceBytes)}.',
      );
    }
    if (skippedByCap > 0) {
      warnings.add(
        'Atlas/card refresh plan capped at $maxCardActions actions; skipped $skippedByCap additional candidate(s).',
      );
    }
    return actions;
  }

  List<LocalProjectRefreshAction> _philosophyJsonCardActions(
    _RefreshFile file,
    String text,
    List<String> warnings,
  ) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (error) {
      warnings.add(
        '${file.relativePath}: could not parse philosophy JSON: $error',
      );
      return const [];
    }

    final cards = _jsonCardObjects(decoded);
    final actions = <LocalProjectRefreshAction>[];
    for (var i = 0; i < cards.length; i++) {
      final card = cards[i];
      final id = _stringField(card, const ['id', 'slug', 'key', 'cardId']);
      final title =
          _stringField(card, const ['title', 'name', 'label', 'heading']) ??
          id ??
          'Philosophy card ${i + 1}';
      final body =
          _stringField(card, const [
            'body',
            'text',
            'summary',
            'description',
            'content',
          ]) ??
          const JsonEncoder.withIndent('  ').convert(card);
      final keySuffix = _sourceFragment(id ?? '${i + 1}');
      actions.add(
        _generatedDocumentAction(
          file: file,
          sourceKey: '${file.relativePath}#card-$keySuffix',
          library: 'philosophy',
          pattern: 'json_card_array',
          format: 'json',
          title: title,
          body: body,
          extraPayload: {'cardIndex': i, 'cardId': id, 'cardJson': card},
        ),
      );
    }
    return actions;
  }

  List<LocalProjectRefreshAction> _preIndustrializationHtmlActions(
    _RefreshFile file,
    String text,
  ) {
    final actions = <LocalProjectRefreshAction>[];
    for (final fragment in _htmlFragments(text, 'details')) {
      actions.add(
        _generatedDocumentAction(
          file: file,
          sourceKey: '${file.relativePath}#details-${fragment.index}',
          library: 'pre_industrialization',
          pattern: 'html_details',
          format: 'html_fragment',
          title:
              _htmlTagText(fragment.html, 'summary') ??
              'Pre-Industrialization details ${fragment.index}',
          body: fragment.html,
          extraPayload: {
            'fragmentTag': 'details',
            'fragmentIndex': fragment.index,
          },
        ),
      );
    }
    for (final fragment in _htmlFragments(text, 'section')) {
      actions.add(
        _generatedDocumentAction(
          file: file,
          sourceKey: '${file.relativePath}#section-${fragment.index}',
          library: 'pre_industrialization',
          pattern: 'html_section',
          format: 'html_fragment',
          title:
              _firstHtmlHeading(fragment.html) ??
              'Pre-Industrialization section ${fragment.index}',
          body: fragment.html,
          extraPayload: {
            'fragmentTag': 'section',
            'fragmentIndex': fragment.index,
          },
        ),
      );
    }
    return actions;
  }

  LocalProjectRefreshAction _generatedDocumentAction({
    required _RefreshFile file,
    required String sourceKey,
    required String library,
    required String pattern,
    required String format,
    required String title,
    required String body,
    Map<String, Object?> extraPayload = const {},
  }) {
    final normalizedTitle = title.trim().isEmpty
        ? _titleFromFilename(file.relativePath)
        : title.trim();
    return LocalProjectRefreshAction(
      sourceKind: 'atlas_card',
      sourceKey: sourceKey,
      targetType: 'document',
      title: normalizedTitle,
      detail: '$library $pattern card source from ${file.relativePath}.',
      fingerprint: _fingerprint(
        'atlas_card|$sourceKey|${file.stat.size}|${file.stat.modified.toIso8601String()}|$body',
      ),
      payload: {
        'library': library,
        'pattern': pattern,
        'format': format,
        'sourcePath': file.file.path,
        'relativePath': file.relativePath,
        'filename': '${_safeFileStem(sourceKey)}.md',
        'extension': 'md',
        'title': normalizedTitle,
        'generatedText': _cardMarkdown(
          title: normalizedTitle,
          library: library,
          pattern: pattern,
          sourcePath: file.relativePath,
          body: body,
        ),
        'source': 'local_refresh:atlas_card:$sourceKey',
        'metadataJson': jsonEncode({
          'refreshSourceKind': 'atlas_card',
          'library': library,
          'pattern': pattern,
          'format': format,
          'relativePath': file.relativePath,
          'sourceKey': sourceKey,
          ...extraPayload,
        }),
        'byteSize': file.stat.size,
      },
    );
  }

  List<LocalProjectRefreshAction> _projectMetaActions(
    _ProjectManifest? manifest,
    Map<String, _DocText> docsByName,
  ) {
    final currentState = _docText(docsByName, 'CURRENT_STATE.md')?.text;
    if (manifest == null) {
      if (currentState == null) return const [];
      final purpose = _sectionText(currentState, 'Project Purpose');
      if (purpose == null || purpose.trim().isEmpty) return const [];
      final normalizedPurpose = purpose.trim();
      return [
        LocalProjectRefreshAction(
          sourceKind: 'project_meta',
          sourceKey: 'CURRENT_STATE.md#project-purpose',
          targetType: 'project',
          title: 'Project purpose from CURRENT_STATE.md',
          detail: normalizedPurpose,
          fingerprint: _fingerprint(normalizedPurpose),
          payload: {'description': normalizedPurpose},
        ),
      ];
    }

    final readme = _docText(docsByName, 'README.md')?.text;
    final handoff = _docText(docsByName, 'HANDOFF.md')?.text;
    final title =
        _stringField(manifest.fields, const [
          'title',
          'name',
          'displayName',
          'display_name',
          'projectName',
        ]) ??
        _projectLineValue(currentState, 'Project') ??
        (readme == null ? null : _markdownTitle(readme));
    final manifestDescription =
        _stringField(manifest.fields, const [
          'description',
          'summary',
          'purpose',
          'notes',
        ]) ??
        _stringField(manifest.fields, const ['note']);
    final currentPurpose = currentState == null
        ? null
        : _sectionTextAny(currentState, const [
            'Project Purpose',
            'What This Project Is',
            'Purpose',
            'Overview',
          ]);
    final readmeSummary = readme == null
        ? null
        : _firstMarkdownParagraph(readme);
    final description = _joinParagraphs([
      manifestDescription,
      currentPurpose,
      readmeSummary,
    ]);
    final scopeIncluded = _joinLines([
      ..._manifestScopeLines(manifest),
      if (currentState != null)
        _sectionListSummary(currentState, 'Existing References'),
      if (readme != null) _sectionText(readme, 'Repository Layout'),
    ]);
    final scopeExcluded = _joinParagraphs([
      if (currentState != null) _sectionText(currentState, 'Maintenance Rule'),
      if (handoff != null) _sectionText(handoff, 'Boundary'),
    ]);
    final validationSummary = _manifestValidationSummary(manifest);
    final tags = _stringListField(manifest.fields, const [
      'tags',
      'keywords',
      'labels',
    ]);
    final payload = <String, Object?>{'metadataSource': manifest.relativePath};
    void addPayload(String key, Object? value) {
      if (value != null) payload[key] = value;
    }

    addPayload('title', title);
    addPayload('description', description);
    addPayload('scopeIncluded', scopeIncluded);
    addPayload('scopeExcluded', scopeExcluded);
    addPayload('outcomeSummary', validationSummary);
    if (tags.isNotEmpty) payload['manifestTags'] = tags;
    addPayload('manifestType', _stringField(manifest.fields, const ['type']));
    addPayload('manifestGroup', _stringField(manifest.fields, const ['group']));
    if (payload.length == 1) return const [];
    final detail = description ?? title ?? 'Project metadata manifest.';
    return [
      LocalProjectRefreshAction(
        sourceKind: 'project_meta',
        sourceKey: '${manifest.relativePath}#project-metadata',
        targetType: 'project',
        title: 'Project metadata from ${manifest.relativePath}',
        detail: detail,
        fingerprint: _fingerprint(jsonEncode(payload)),
        payload: payload,
      ),
    ];
  }

  List<LocalProjectRefreshAction> _handoffActions(_DocText? handoff) {
    if (handoff == null) return const [];
    final actions = <LocalProjectRefreshAction>[];
    final seenTitles = <String>{};
    for (final heading in const [
      'Next Verification',
      'Next Steps',
      'Next Actions',
      'Next Work',
      'Next',
    ]) {
      final section = _sectionText(handoff.text, heading);
      if (section == null) continue;
      var index = 0;
      for (final title in _markdownListItems(section)) {
        if (title.isEmpty || !seenTitles.add(title.toLowerCase())) continue;
        index++;
        final slug = _sourceFragment(heading);
        actions.add(
          _workAction(
            sourceKey: '${handoff.relativePath}#$slug-$index',
            title: title,
            detail: '${handoff.relativePath} $heading item.',
            status: 'next',
            blockedReason: null,
          ),
        );
      }
    }
    return actions;
  }

  List<LocalProjectRefreshAction> _decisionActions(String? text) {
    if (text == null) return const [];
    final matches = RegExp(
      r'^##\s+(DEC-\d+)\s+-\s+(.+)$',
      multiLine: true,
    ).allMatches(text).toList();
    final actions = <LocalProjectRefreshAction>[];
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final start = match.end;
      final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
      final id = match.group(1)!.trim();
      final heading = match.group(2)!.trim();
      final body = text.substring(start, end).trim();
      final title = '$id - $heading';
      final sourceKey = 'DECISIONS.md#${id.toLowerCase()}';
      final detail = body.isEmpty
          ? 'Decision imported from DECISIONS.md.'
          : body;
      actions.add(
        LocalProjectRefreshAction(
          sourceKind: 'decision',
          sourceKey: sourceKey,
          targetType: 'decision',
          title: title,
          detail: detail,
          fingerprint: _fingerprint('$title\n$detail'),
          payload: {
            'title': title,
            'ctx': detail,
            'decider': _extractDecider(body),
          },
        ),
      );
    }
    return actions;
  }

  List<LocalProjectRefreshAction> _activeTaskActions(String? text) {
    if (text == null) return const [];
    final upper = text.toUpperCase();
    if (!upper.contains('IDLE') && !upper.contains('NO ACTIVE WORK ORDER')) {
      return const [];
    }
    const title = 'Await owner-authorized BOH work order';
    const detail =
        'ACTIVE_TASK.md reports IDLE / no active work order. Do not treat roadmap drafts as active implementation.';
    return [
      LocalProjectRefreshAction(
        sourceKind: 'work_item',
        sourceKey: 'ACTIVE_TASK.md#idle',
        targetType: 'work_item',
        title: title,
        detail: detail,
        fingerprint: _fingerprint('$title\n$detail'),
        payload: {
          'title': title,
          'description': detail,
          'status': 'waiting',
          'priority': 'normal',
          'blockedReason': 'Owner authorization required.',
          'source': 'local_refresh:ACTIVE_TASK.md#idle',
        },
      ),
    ];
  }

  List<LocalProjectRefreshAction> _roadmapActions(String? text) {
    if (text == null) return const [];
    final actions = <LocalProjectRefreshAction>[];
    final next = _sectionText(text, 'Next');
    if (next != null) {
      final lines = next.split('\n');
      var index = 0;
      for (final line in lines) {
        final match = RegExp(r'^\s*\d+\.\s+(.+)$').firstMatch(line);
        if (match == null) continue;
        index++;
        final title = _cleanMarkdown(match.group(1)!);
        final sourceKey = 'ROADMAP.md#next-$index';
        actions.add(
          _workAction(
            sourceKey: sourceKey,
            title: title,
            detail: 'ROADMAP.md Next item.',
            status: 'next',
            blockedReason: null,
          ),
        );
      }
    }

    final proposed = _sectionText(text, 'Proposed next work orders');
    if (proposed != null) {
      var index = 0;
      for (final line in proposed.split('\n')) {
        final match = RegExp(r'^\s*-\s+(.+)$').firstMatch(line);
        if (match == null) continue;
        final cleaned = _cleanMarkdown(match.group(1)!);
        if (cleaned.isEmpty) continue;
        index++;
        actions.add(
          _workAction(
            sourceKey: 'ROADMAP.md#proposed-$index',
            title: cleaned,
            detail: 'ROADMAP.md proposed work order; not owner-authorized.',
            status: 'waiting',
            blockedReason: 'Owner authorization required.',
          ),
        );
      }
    }
    return actions;
  }

  List<LocalProjectRefreshAction> _currentStateActions(String? text) {
    if (text == null) return const [];
    final actions = <LocalProjectRefreshAction>[];
    if (text.contains('boh_runtime_launch_origin_audit_v0_1')) {
      actions.add(
        _workAction(
          sourceKey: 'CURRENT_STATE.md#boh-runtime-launch-origin-audit-v0-1',
          title: 'boh_runtime_launch_origin_audit_v0_1',
          detail:
              'CURRENT_STATE.md names this as an operational item before production server validation or unattended use.',
          status: 'waiting',
          blockedReason: 'Separate BOH work order required.',
        ),
      );
    }

    final knownRisks = _sectionText(text, 'Known Risks');
    if (knownRisks != null) {
      var index = 0;
      for (final line in knownRisks.split('\n')) {
        final match = RegExp(r'^\s*-\s+(.+)$').firstMatch(line);
        if (match == null) continue;
        final title = _cleanMarkdown(match.group(1)!);
        if (title.isEmpty) continue;
        index++;
        actions.add(
          LocalProjectRefreshAction(
            sourceKind: 'risk',
            sourceKey: 'CURRENT_STATE.md#known-risk-$index',
            targetType: 'risk',
            title: title,
            detail: 'Imported from CURRENT_STATE.md Known Risks.',
            fingerprint: _fingerprint(title),
            payload: {
              'title': title,
              'desc': 'Imported from CURRENT_STATE.md Known Risks.',
              'severity': 'medium',
            },
          ),
        );
      }
    }
    return actions;
  }

  LocalProjectRefreshAction _workAction({
    required String sourceKey,
    required String title,
    required String detail,
    required String status,
    String? blockedReason,
  }) {
    return LocalProjectRefreshAction(
      sourceKind: 'work_item',
      sourceKey: sourceKey,
      targetType: 'work_item',
      title: title,
      detail: detail,
      fingerprint: _fingerprint('$title\n$detail\n$status\n$blockedReason'),
      payload: {
        'title': title,
        'description': detail,
        'status': status,
        'priority': 'normal',
        'blockedReason': blockedReason,
        'source': 'local_refresh:$sourceKey',
      },
    );
  }

  String? _projectLineValue(String? text, String label) {
    if (text == null) return null;
    final match = RegExp(
      '^\\s*${RegExp.escape(label)}\\s*:\\s*(.+)\$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(text);
    return match?.group(1)?.trim();
  }

  String? _firstMarkdownParagraph(String text) {
    final lines = text.split('\n');
    final paragraph = <String>[];
    var inFence = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      if (line.isEmpty) {
        if (paragraph.isNotEmpty) break;
        continue;
      }
      if (line.startsWith('#') ||
          line.startsWith('![') ||
          line.startsWith('- ') ||
          line.startsWith('* ') ||
          RegExp(r'^\d+[.)]\s+').hasMatch(line)) {
        if (paragraph.isNotEmpty) break;
        continue;
      }
      paragraph.add(_cleanMarkdown(line));
    }
    return paragraph.isEmpty ? null : paragraph.join(' ').trim();
  }

  Iterable<String> _markdownListItems(String text) sync* {
    for (final line in text.split('\n')) {
      final match = RegExp(
        r'^\s*(?:[-*+]\s+|\d+[.)]\s+|\[[ xX]\]\s+)(.+)$',
      ).firstMatch(line);
      if (match == null) continue;
      final cleaned = _cleanMarkdown(match.group(1)!);
      if (cleaned.isNotEmpty) yield cleaned;
    }
  }

  String? _joinParagraphs(Iterable<String?> values) {
    final seen = <String>{};
    final parts = <String>[];
    for (final value in values) {
      final normalized = value?.trim();
      if (normalized == null || normalized.isEmpty) continue;
      final key = normalized.toLowerCase();
      if (seen.add(key)) parts.add(normalized);
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  String? _joinLines(Iterable<String?> values) {
    final seen = <String>{};
    final parts = <String>[];
    for (final value in values) {
      final normalized = value?.trim();
      if (normalized == null || normalized.isEmpty) continue;
      for (final line in normalized.split('\n')) {
        final clean = line.trim();
        if (clean.isEmpty) continue;
        if (seen.add(clean.toLowerCase())) parts.add(clean);
      }
    }
    return parts.isEmpty ? null : parts.join('\n');
  }

  String? _sectionListSummary(String text, String heading) {
    final section = _sectionText(text, heading);
    if (section == null) return null;
    final items = _markdownListItems(section).toList(growable: false);
    return items.isEmpty ? section : items.map((item) => '- $item').join('\n');
  }

  Iterable<String> _manifestScopeLines(_ProjectManifest manifest) sync* {
    final type = _stringField(manifest.fields, const ['type']);
    if (type != null) yield 'Manifest type: $type';
    final group = _stringField(manifest.fields, const ['group']);
    if (group != null) yield 'Launchpad group: $group';
    final tags = _stringListField(manifest.fields, const [
      'tags',
      'keywords',
      'labels',
    ]);
    if (tags.isNotEmpty) yield 'Tags: ${tags.join(', ')}';
    final commands = _manifestMapKeys(manifest, 'commands');
    if (commands.isNotEmpty) yield 'Commands: ${commands.join(', ')}';
    final docs = _manifestMapKeys(manifest, 'docs');
    if (docs.isNotEmpty) yield 'Manifest docs: ${docs.join(', ')}';
    final urls = _stringListField(manifest.fields, const ['urls']);
    if (urls.isNotEmpty) yield 'URLs: ${urls.join(', ')}';
    final health = _stringListField(manifest.fields, const [
      'healthcheck_urls',
      'healthcheckUrls',
      'healthChecks',
    ]);
    if (health.isNotEmpty) yield 'Health checks: ${health.join(', ')}';
  }

  List<String> _manifestMapKeys(_ProjectManifest manifest, String key) {
    final value = _mapValue(manifest.fields, key);
    if (value is Map) {
      return value.keys
          .map((key) => '$key')
          .where((key) => key.isNotEmpty)
          .toList(growable: false);
    }
    return _stringListFromValue(value);
  }

  String? _manifestValidationSummary(_ProjectManifest manifest) {
    final validation = _mapValue(manifest.fields, 'validation');
    if (validation is! Map) return null;
    final parts = <String>[];
    for (final entry in validation.entries) {
      final value = entry.value;
      if (value == null) continue;
      parts.add('${entry.key}: $value');
    }
    return parts.isEmpty ? null : 'Validation: ${parts.join('; ')}';
  }

  List<String> _manifestDocPaths(_ProjectManifest manifest) {
    final docs = _mapValue(manifest.fields, 'docs');
    return _stringListFromValue(
      docs,
    ).map(_normalizeRelativePath).whereType<String>().toList(growable: false);
  }

  List<String> _stringListField(Map<String, Object?> value, List<String> keys) {
    for (final key in keys) {
      final list = _stringListFromValue(_mapValue(value, key));
      if (list.isNotEmpty) return list;
    }
    return const [];
  }

  List<String> _stringListFromValue(Object? value) {
    if (value == null) return const [];
    if (value is String) {
      return value
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    if (value is Iterable) {
      return value
          .map((item) => '$item'.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    if (value is Map) {
      return value.values
          .map((item) => '$item'.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return ['$value'];
  }

  Future<_ProjectManifest?> _readLaunchpadManifest(
    Directory root,
    List<String> warnings,
  ) async {
    final file = File(p.join(root.path, projectManifestRelativePath));
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(_stripBom(raw));
      if (decoded is! Map) {
        warnings.add(
          '$projectManifestRelativePath: manifest is not an object.',
        );
        return null;
      }
      return _ProjectManifest(
        relativePath: projectManifestRelativePath,
        fields: _stringKeyedMap(decoded),
      );
    } catch (error) {
      warnings.add(
        '$projectManifestRelativePath: could not parse manifest: $error',
      );
      return null;
    }
  }

  String _stripBom(String value) =>
      value.startsWith('\uFEFF') ? value.substring(1) : value;

  String? _normalizeRelativePath(String value) {
    final normalized = value.trim().replaceAll('\\', '/');
    if (normalized.isEmpty || p.isAbsolute(normalized)) return null;
    final parts = normalized
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .toList(growable: false);
    if (parts.isEmpty || parts.any((part) => part == '..')) return null;
    return parts.join('/');
  }

  Map<String, _DocText> _canonicalDocsByName(Map<String, String> textByPath) {
    final entries = textByPath.entries.toList()
      ..sort((a, b) {
        final depth = a.key
            .split('/')
            .length
            .compareTo(b.key.split('/').length);
        if (depth != 0) return depth;
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
    final docs = <String, _DocText>{};
    for (final entry in entries) {
      final name = _basenameFromRelativePath(entry.key).toUpperCase();
      docs.putIfAbsent(
        name,
        () => _DocText(relativePath: entry.key, text: entry.value),
      );
    }
    return docs;
  }

  _DocText? _docText(Map<String, _DocText> docsByName, String name) =>
      docsByName[name.toUpperCase()];

  String _basenameFromRelativePath(String relativePath) {
    final segments = relativePath.replaceAll('\\', '/').split('/');
    return segments.isEmpty ? relativePath : segments.last;
  }

  bool _isProjectManifestPath(String relativePath) =>
      relativePath.toLowerCase() == projectManifestRelativePath;

  bool _isFixtureLikeSourceDuplicate(String relativePath) {
    final lower = relativePath.toLowerCase();
    final segments = lower.split('/');
    if (!segments.contains('fixtures')) return false;
    if (!commonDocumentExtensions.contains(
      p.extension(lower).replaceFirst('.', ''),
    )) {
      return false;
    }
    return segments.contains('test') ||
        segments.contains('tests') ||
        segments.contains('spec') ||
        segments.contains('specs');
  }

  bool _isReleaseArchiveBinaryPath(String relativePath) {
    final lower = relativePath.toLowerCase();
    final segments = lower.split('/');
    final ext = p.extension(lower).replaceFirst('.', '');
    if (!_artifactBinaryExtensions.contains(ext)) return false;
    return segments.length == 1 ||
        segments.contains('release') ||
        segments.contains('releases') ||
        segments.contains('archive') ||
        segments.contains('archives');
  }

  Set<String> get _artifactBinaryExtensions => const {
    '7z',
    'appx',
    'bz2',
    'dmg',
    'exe',
    'gz',
    'jar',
    'msi',
    'pkg',
    'rar',
    'tar',
    'tgz',
    'war',
    'whl',
    'xz',
    'zip',
  };

  void _addArtifactWarning(
    List<String> warnings,
    String relativePath,
    FileStat stat,
  ) {
    warnings.add(
      'Artifact not imported as source: $relativePath (${_formatBytes(stat.size)}).',
    );
  }

  String? _sectionTextAny(String text, List<String> headings) {
    for (final heading in headings) {
      final section = _sectionText(text, heading);
      if (section != null && section.trim().isNotEmpty) return section;
    }
    return null;
  }

  String? _sectionText(String text, String heading) {
    final escaped = RegExp.escape(heading);
    final match = RegExp(
      '^(#{1,6})\\s+$escaped\\s*#*\\s*\$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    final level = match.group(1)!.length;
    final next = RegExp(
      '^#{1,$level}\\s+',
      multiLine: true,
    ).firstMatch(text.substring(match.end));
    final end = next == null ? text.length : match.end + next.start;
    return text.substring(match.end, end).trim();
  }

  String _cleanMarkdown(String value) {
    return value
        .replaceAll('**', '')
        .replaceAll('`', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String? _extractDecider(String body) {
    final match = RegExp(
      r'Decision\s*\(([^)]+)\)',
      caseSensitive: false,
    ).firstMatch(body);
    return match?.group(1)?.trim();
  }

  bool _looksLikeBoh(Map<String, _DocText> docsByName, String rootPath) {
    if (p.basename(rootPath).toLowerCase().contains('bag.of.holding')) {
      return true;
    }
    final current = _docText(docsByName, 'CURRENT_STATE.md')?.text ?? '';
    return current.contains('Bag of Holding') || current.contains('BOH MCP');
  }

  List<_RefreshFile> _scanRefreshFiles(Directory root, List<String> warnings) {
    final files = <_RefreshFile>[];
    final stack = <Directory>[root];
    while (stack.isNotEmpty) {
      final dir = stack.removeLast();
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          final relativePath = p
              .relative(entity.path, from: root.path)
              .replaceAll('\\', '/');
          if (entity is Directory) {
            if (!_isExcludedRefreshDirectoryName(p.basename(entity.path))) {
              stack.add(entity);
            }
            continue;
          }
          try {
            if (entity is! File) continue;
            final stat = entity.statSync();
            if (_isReleaseArchiveBinaryPath(relativePath)) {
              _addArtifactWarning(warnings, relativePath, stat);
              continue;
            }
            if (_isExcludedRefreshPath(relativePath)) continue;
            files.add(
              _RefreshFile(
                file: entity,
                relativePath: relativePath,
                stat: stat,
              ),
            );
          } on FileSystemException catch (error) {
            warnings.add(
              '$relativePath: could not stat file: ${error.message}',
            );
          }
        }
      } on FileSystemException catch (error) {
        warnings.add(
          '${dir.path}: could not scan refresh files: ${error.message}',
        );
      }
    }
    files.sort(
      (a, b) =>
          a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()),
    );
    return files;
  }

  bool _isExcludedRefreshPath(String relativePath) {
    final segments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return true;
    for (final segment in segments.take(segments.length - 1)) {
      if (_isExcludedRefreshDirectoryName(segment)) return true;
    }
    return _isExcludedRefreshFileName(segments.last);
  }

  bool _isExcludedRefreshDirectoryName(String name) {
    final lower = name.toLowerCase();
    return lower == '.atlas_backups' ||
        lower == '.cache' ||
        lower == '.claude' ||
        lower == '.dart_tool' ||
        lower == '.git' ||
        lower == '.gradle' ||
        lower == '.idea' ||
        lower == '.mypy_cache' ||
        lower == '.next' ||
        lower == '.nuxt' ||
        lower == '.pytest_cache' ||
        lower == '.svn' ||
        lower == '.svelte-kit' ||
        lower == '.tox' ||
        lower == '.turbo' ||
        lower == '.venv' ||
        lower == '.vs' ||
        lower == '__pycache__' ||
        lower == 'bin' ||
        lower == 'build' ||
        lower == 'coverage' ||
        lower == 'deriveddata' ||
        lower == 'dist' ||
        lower == 'env' ||
        lower == 'ephemeral' ||
        lower == 'gen' ||
        lower == 'generated' ||
        lower == 'node_modules' ||
        lower == 'obj' ||
        lower == 'out' ||
        lower == 'packages' ||
        lower == 'pods' ||
        lower == 'target' ||
        lower == 'vendor' ||
        lower == 'venv' ||
        lower.endsWith('.egg-info');
  }

  bool _isExcludedRefreshFileName(String name) {
    final lower = name.toLowerCase();
    if (lower.isEmpty) return true;
    if (_isGeneratedFileName(lower)) return true;
    if (_isSecretLikeFileName(lower)) return true;
    if (_isDependencyLockFile(lower)) return true;

    final ext = p.extension(lower).replaceFirst('.', '');
    return const {
      '7z',
      'a',
      'apk',
      'appx',
      'bz2',
      'class',
      'db',
      'dll',
      'dylib',
      'exe',
      'gz',
      'jar',
      'keystore',
      'lock',
      'o',
      'p12',
      'pem',
      'pfx',
      'pyc',
      'pyo',
      'rar',
      'so',
      'sqlite',
      'sqlite3',
      'tar',
      'tgz',
      'war',
      'xz',
      'zip',
    }.contains(ext);
  }

  bool _isGeneratedFileName(String lowerName) {
    return lowerName.endsWith('.g.dart') ||
        lowerName.endsWith('.freezed.dart') ||
        lowerName.endsWith('.gen.dart') ||
        lowerName.endsWith('.gr.dart') ||
        lowerName.endsWith('.mocks.dart') ||
        lowerName.endsWith('.pb.dart') ||
        lowerName.endsWith('.pbenum.dart') ||
        lowerName.endsWith('.pbgrpc.dart') ||
        lowerName.endsWith('.pbjson.dart') ||
        lowerName.contains('.generated.');
  }

  bool _isSecretLikeFileName(String lowerName) {
    if (lowerName == '.env' ||
        lowerName.startsWith('.env.') ||
        lowerName.endsWith('.env') ||
        lowerName == 'id_dsa' ||
        lowerName == 'id_ecdsa' ||
        lowerName == 'id_ed25519' ||
        lowerName == 'id_rsa') {
      return true;
    }
    return RegExp(
      r'(^|[._-])(api[_-]?key|credential|credentials|passwd|password|private[_-]?key|secret|secrets|token|tokens)([._-]|$)',
    ).hasMatch(lowerName);
  }

  bool _isDependencyLockFile(String lowerName) {
    return lowerName == 'cargo.lock' ||
        lowerName == 'composer.lock' ||
        lowerName == 'flake.lock' ||
        lowerName == 'package-lock.json' ||
        lowerName == 'pnpm-lock.yaml' ||
        lowerName == 'pubspec.lock' ||
        lowerName == 'yarn.lock';
  }

  bool _looksLikeCardLibrarySource(String relativePath) {
    return _isTradeCraftCardMarkdown(relativePath) ||
        _isProductivityGoalCard(relativePath) ||
        _isPhilosophyJsonCards(relativePath) ||
        _isPreIndustrializationHtml(relativePath);
  }

  bool _isTradeCraftCardMarkdown(String relativePath) {
    final lower = relativePath.toLowerCase();
    if (!lower.endsWith('.md')) return false;
    final segments = lower.split('/');
    return segments.contains('cards') &&
        (lower.contains('trade_craft') ||
            lower.contains('trade-craft') ||
            lower.contains('trade craft') ||
            lower.contains('tradecraft'));
  }

  bool _isProductivityGoalCard(String relativePath) {
    return relativePath.toLowerCase().endsWith('.goalcard.md');
  }

  bool _isPhilosophyJsonCards(String relativePath) {
    final lower = relativePath.toLowerCase();
    return lower.endsWith('.json') && lower.contains('philosophy');
  }

  bool _isPreIndustrializationHtml(String relativePath) {
    final lower = relativePath.toLowerCase();
    return (lower.endsWith('.html') || lower.endsWith('.htm')) &&
        (lower.contains('pre_industrialization') ||
            lower.contains('pre-industrialization') ||
            lower.contains('preindustrialization'));
  }

  List<Map<String, Object?>> _jsonCardObjects(Object? value) {
    final cards = <Map<String, Object?>>[];
    final seen = <String>{};

    void add(Map<String, Object?> card) {
      if (!_looksLikeJsonCard(card)) return;
      final key = jsonEncode(card);
      if (seen.add(key)) cards.add(card);
    }

    void collect(Object? candidate) {
      if (candidate is List) {
        for (final item in candidate) {
          if (item is Map) add(_stringKeyedMap(item));
        }
        return;
      }
      if (candidate is! Map) return;
      final map = _stringKeyedMap(candidate);
      for (final key in const ['cards', 'items', 'entries', 'nodes']) {
        collect(_mapValue(map, key));
      }
      for (final entry in map.entries) {
        if (entry.key.toLowerCase().contains('card')) {
          collect(entry.value);
        }
      }
    }

    collect(value);
    return cards;
  }

  bool _looksLikeJsonCard(Map<String, Object?> value) {
    return _stringField(value, const [
          'title',
          'name',
          'label',
          'heading',
          'id',
          'slug',
        ]) !=
        null;
  }

  Map<String, Object?> _stringKeyedMap(Map<dynamic, dynamic> value) {
    return value.map((key, value) => MapEntry('$key', value));
  }

  Object? _mapValue(Map<String, Object?> value, String key) {
    for (final entry in value.entries) {
      if (entry.key.toLowerCase() == key.toLowerCase()) return entry.value;
    }
    return null;
  }

  String? _stringField(Map<String, Object?> value, List<String> keys) {
    for (final key in keys) {
      final candidate = _mapValue(value, key);
      if (candidate is String && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
      if (candidate is num || candidate is bool) return '$candidate';
    }
    return null;
  }

  Iterable<_HtmlFragment> _htmlFragments(String text, String tag) sync* {
    final pattern = RegExp(
      '<$tag\\b[^>]*>[\\s\\S]*?</$tag>',
      caseSensitive: false,
    );
    var index = 0;
    for (final match in pattern.allMatches(text)) {
      final html = match.group(0);
      if (html == null || html.trim().isEmpty) continue;
      index++;
      yield _HtmlFragment(index, html);
    }
  }

  String? _htmlTagText(String html, String tag) {
    final match = RegExp(
      '<$tag\\b[^>]*>([\\s\\S]*?)</$tag>',
      caseSensitive: false,
    ).firstMatch(html);
    final raw = match?.group(1);
    if (raw == null) return null;
    final cleaned = _cleanHtmlText(raw);
    return cleaned.isEmpty ? null : cleaned;
  }

  String? _firstHtmlHeading(String html) {
    final match = RegExp(
      r'<h[1-6]\b[^>]*>([\s\S]*?)</h[1-6]>',
      caseSensitive: false,
    ).firstMatch(html);
    final raw = match?.group(1);
    if (raw == null) return null;
    final cleaned = _cleanHtmlText(raw);
    return cleaned.isEmpty ? null : cleaned;
  }

  String _cleanHtmlText(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String? _markdownTitle(String text) {
    for (final line in text.split('\n')) {
      final match = RegExp(r'^\s*#\s+(.+)$').firstMatch(line);
      final title = match?.group(1)?.trim();
      if (title != null && title.isNotEmpty) return _cleanMarkdown(title);
    }
    return null;
  }

  String _titleFromFilename(String relativePath) {
    final basename = p.basename(relativePath);
    final lower = basename.toLowerCase();
    final stem = lower.endsWith('.goalcard.md')
        ? basename.substring(0, basename.length - '.goalcard.md'.length)
        : p.basenameWithoutExtension(basename);
    return _cleanMarkdown(stem.replaceAll('_', ' ').replaceAll('-', ' '));
  }

  String _safeFileStem(String value) {
    final stem = value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (stem.isEmpty) return 'card';
    return stem.length <= 120 ? stem : stem.substring(0, 120);
  }

  String _cardMarkdown({
    required String title,
    required String library,
    required String pattern,
    required String sourcePath,
    required String body,
  }) {
    final buffer = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln('Source library: $library')
      ..writeln('Source pattern: $pattern')
      ..writeln('Source path: `$sourcePath`');
    final normalizedBody = body.trim();
    if (normalizedBody.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(normalizedBody);
    }
    return buffer.toString().trimRight();
  }

  String _sourceFragment(String value) {
    final fragment = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return fragment.isEmpty ? 'item' : fragment;
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 && bytes % (1024 * 1024) == 0) {
      return '${bytes ~/ (1024 * 1024)} MB';
    }
    if (bytes >= 1024 && bytes % 1024 == 0) {
      return '${bytes ~/ 1024} KB';
    }
    return '$bytes bytes';
  }

  String _fingerprint(String input) {
    var hash = 0xcbf29ce484222325;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

class _RefreshFile {
  final File file;
  final String relativePath;
  final FileStat stat;

  const _RefreshFile({
    required this.file,
    required this.relativePath,
    required this.stat,
  });

  String get extension =>
      p.extension(relativePath).replaceFirst('.', '').toLowerCase();
}

class _ProjectManifest {
  final String relativePath;
  final Map<String, Object?> fields;

  const _ProjectManifest({required this.relativePath, required this.fields});
}

class _DocText {
  final String relativePath;
  final String text;

  const _DocText({required this.relativePath, required this.text});
}

class _HtmlFragment {
  final int index;
  final String html;

  const _HtmlFragment(this.index, this.html);
}
