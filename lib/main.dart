import 'dart:io';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'mcp/atlas_mcp_stdio.dart';
import 'services/atlas_live_recovery_service.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--mcp-stdio')) {
    await runAtlasMcpStdio(args);
    return;
  }
  final recoveryIndex = args.indexOf('--apply-live-recovery');
  if (recoveryIndex >= 0 && recoveryIndex + 1 < args.length) {
    final plan = File(args[recoveryIndex + 1]);
    final liveRecovery = AtlasLiveRecoveryService();
    try {
      await liveRecovery.applyPlan(plan);
      // Never execute a path supplied by the mutable handoff plan. Relaunch the
      // same trusted binary that is currently applying recovery.
      await Process.start(Platform.resolvedExecutable, const []);
      exit(0);
    } catch (error) {
      await File(
        '${plan.path}.failed.txt',
      ).writeAsString('Live recovery did not apply: $error\n', flush: true);
      exitCode = 1;
      return;
    }
  }
  runApp(const ProjectAtlasApp());
}
