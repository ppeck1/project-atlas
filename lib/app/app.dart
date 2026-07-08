import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../db/app_db.dart';
import '../shared/models/app_state.dart';
import '../shared/models/app_state_scope.dart';
import 'router.dart';
import 'theme.dart';

class ProjectAtlasApp extends StatefulWidget {
  const ProjectAtlasApp({super.key});

  @override
  State<ProjectAtlasApp> createState() => _ProjectAtlasAppState();
}

class _ProjectAtlasAppState extends State<ProjectAtlasApp> {
  late final AppDb _db;
  late final AppState _state;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _db = AppDb();
    _state = AppState(_db);
    _router = buildRouter();
  }

  @override
  void dispose() {
    _router.dispose();
    _state.dispose();
    unawaited(_db.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: _state,
      child: MaterialApp.router(
        title: 'Project Atlas',
        theme: buildAtlasTheme(),
        routerConfig: _router,
      ),
    );
  }
}
