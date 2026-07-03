import 'package:flutter/material.dart';

import 'app/app.dart';
import 'mcp/atlas_mcp_stdio.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--mcp-stdio')) {
    await runAtlasMcpStdio(args);
    return;
  }
  runApp(const ProjectAtlasApp());
}
