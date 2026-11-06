// SPDX-License-Identifier: GPL-3.0-or-later
// Start-up, the first-run welcome, and the four tabs: Scan, Find, Inspect, Library.

import 'package:material_ui/material_ui.dart';

import '../model/app_model.dart';
import '../platform/services.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/fx_icon.dart';
import 'find.dart';
import 'inspect.dart';
import 'library.dart';
import 'scan.dart';

/// Opens the store, then shows the app. A store that can't be opened is explained, not hidden.
class FieldWorxBoot extends StatefulWidget {
  const FieldWorxBoot({super.key, required this.services});
  final FieldServices services;

  @override
  State<FieldWorxBoot> createState() => _FieldWorxBootState();
}

class _FieldWorxBootState extends State<FieldWorxBoot> {
  late final Future<AppModel> _model = AppModel.open(widget.services);

  @override
  Widget build(BuildContext context) => FutureBuilder<AppModel>(
        future: _model,
        builder: (context, snap) {
          if (snap.hasData) return FieldWorxApp(model: snap.data!);
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(defaultTheme),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: snap.hasError
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: NoticeBanner('FieldWorx could not open its files: ${snap.error}', tone: Tone.danger),
                        )
                      : const _Splash(),
                ),
              ),
            ),
          );
        },
      );
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        const FieldWorxMark(size: 88),
        const SizedBox(height: 16),
        Text('FieldWorx', style: TextStyle(color: context.fx.text, fontSize: 26, fontWeight: FontWeight.w700)),
      ]);
}

/// Placeholder mark until the Director supplies FieldWorx artwork: the family's rounded blue tile with the scan icon.
class FieldWorxMark extends StatelessWidget {
  const FieldWorxMark({super.key, this.size = 64});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2F74E0), Color(0xFF1D5FC9)],
          ),
          borderRadius: BorderRadius.circular(size * 0.22),
        ),
        child: FxIcon('scan', size: size * 0.62, color: const Color(0xFFFFFFFF), accent: const Color(0xFFFFFFFF)),
      );
}

class FieldWorxApp extends StatelessWidget {
  const FieldWorxApp({super.key, required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) => AppScope(
        model: model,
        child: ListenableBuilder(
          listenable: model,
          builder: (context, _) => MaterialApp(
            title: 'FieldWorx',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(model.theme),
            home: model.userName.isEmpty ? const WelcomeScreen() : const HomeShell(),
          ),
        ),
      );
}

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 48, 24, 24), children: [
          const Center(child: FieldWorxMark(size: 88)),
          const SizedBox(height: 20),
          Text('FieldWorx',
              textAlign: TextAlign.center, style: TextStyle(color: fx.text, fontSize: 30, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('Released drawings, parts and inspections, wherever the machine is.',
              textAlign: TextAlign.center, style: TextStyle(color: fx.muted, fontSize: 16)),
          const SizedBox(height: 36),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Your name'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _go(),
          ),
          const SizedBox(height: 8),
          Text(
            'It goes into the inspections you record, so the office knows who did them. There is no account: '
            'FieldWorx works offline and sends nothing anywhere by itself.',
            style: TextStyle(color: fx.muted, fontSize: 13.5, height: 1.4),
          ),
          const SizedBox(height: 24),
          PrimaryAction('Continue', icon: 'chevron_right', onPressed: _name.text.trim().isEmpty ? null : _go),
        ]),
      ),
    );
  }

  Future<void> _go() async {
    if (_name.text.trim().isEmpty) return;
    await AppScope.read(context).setUserName(_name.text);
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    Widget icon(String name, bool selected) => FxIcon(name, size: 24, color: selected ? fx.text : fx.muted);
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        ScanTab(active: _tab == 0),
        const FindTab(),
        const InspectTab(),
        const LibraryTab(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(icon: icon('scan', false), selectedIcon: icon('scan', true), label: 'Scan'),
          NavigationDestination(icon: icon('search', false), selectedIcon: icon('search', true), label: 'Find'),
          NavigationDestination(
            icon: Badge(isLabelVisible: m.unsent > 0, label: Text('${m.unsent}'), child: icon('inspect', false)),
            selectedIcon: Badge(isLabelVisible: m.unsent > 0, label: Text('${m.unsent}'), child: icon('inspect', true)),
            label: 'Inspect',
          ),
          NavigationDestination(icon: icon('library', false), selectedIcon: icon('library', true), label: 'Library'),
        ],
      ),
    );
  }
}
