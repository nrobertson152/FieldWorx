// FieldWorx - the field companion to RevisionWorx
// Copyright (C) 2026 FieldWorx contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import 'platform/plugins.dart';
import 'screens/shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(FieldWorxBoot(services: PluginServices()));
}
