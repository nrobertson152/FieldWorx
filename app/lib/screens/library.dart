// SPDX-License-Identifier: GPL-3.0-or-later
// Library: the packages on this phone (what engineering sent, and how old it is), the field records waiting to go
// back, and settings. Adding a package or a field log checks the whole file before anything is kept.

import 'package:material_ui/material_ui.dart';

import '../model/app_model.dart';
import '../theme/theme.dart';
import '../version.dart';
import '../widgets/common.dart';
import '../widgets/fx_icon.dart';
import 'inspect.dart';

Future<void> addPackageFlow(BuildContext context, {bool demo = false}) async {
  final m = AppScope.read(context);
  try {
    final f = demo
        ? await m.services.demoPackage()
        : await m.services.pickFile(title: 'Add package', extensions: const ['fieldworx']);
    if (f == null || !context.mounted) return;
    final r = await m.installPackage(f);
    if (!context.mounted) return;
    showMessage(
        context,
        'Added “${r.package.title}”'
        '${r.replaced.isEmpty ? '' : ', replacing the older copy'}'
        '${r.newEvents == 0 ? '' : ', with ${r.newEvents} field record${r.newEvents == 1 ? '' : 's'}'}.');
  } on Exception catch (e) {
    if (context.mounted) showMessage(context, explain(e), error: true);
  }
}

Future<void> importFieldLogFlow(BuildContext context) async {
  final m = AppScope.read(context);
  try {
    final f = await m.services.pickFile(title: 'Import field log', extensions: const ['fieldlog']);
    if (f == null || !context.mounted) return;
    final r = await m.importFieldLog(f);
    if (!context.mounted) return;
    showMessage(context,
        '${r.newEvents} new record${r.newEvents == 1 ? '' : 's'}, ${r.knownEvents} already here, ${r.newObjects} photo${r.newObjects == 1 ? '' : 's'}.');
  } on Exception catch (e) {
    if (context.mounted) showMessage(context, explain(e), error: true);
  }
}

class NoPackage extends StatelessWidget {
  const NoPackage({super.key});

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: 'package',
        title: 'No package on this phone yet',
        body: 'Engineering makes a package (a .fieldworx file) from RevisionWorx with fieldworx-bridge. Copy it to the '
            'phone (USB, e-mail, a shared folder) and add it here. Everything then works offline.',
        actions: [
          PrimaryAction('Add a package', icon: 'import', onPressed: () => addPackageFlow(context)),
          SecondaryAction('Try the demo (HPU-75)', icon: 'asset', onPressed: () => addPackageFlow(context, demo: true)),
        ],
      );
}

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    final pkgs = [...m.catalog.packages]..sort((a, b) => b.created.compareTo(a.created));
    final mine = m.store.log.streams[m.store.deviceId]?.length ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: PageList(children: [
        for (final w in m.store.warnings) ...[NoticeBanner(w, tone: Tone.warn), const SizedBox(height: 8)],
        SectionHeader('Packages (${pkgs.length})', trailing: TextButton(onPressed: () => addPackageFlow(context), child: const Text('Add'))),
        if (pkgs.isEmpty)
          const NoPackage()
        else
          RowsCard(children: [
            for (final p in pkgs)
              EntityRow(
                icon: 'package',
                title: p.title,
                subtitle: [
                  if (p.sourceName.isNotEmpty) p.sourceName,
                  'made ${shortDate(p.created)}',
                ].join(' · '),
                chips: [
                  StatusChip(_age(p.created), tone: _ageTone(p.created)),
                  if (p.notices.isNotEmpty) StatusChip('${p.notices.length} note${p.notices.length == 1 ? '' : 's'}', tone: Tone.info),
                ],
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PackageScreen(id: p.id))),
              ),
          ]),
        const SectionHeader('Field records'),
        if (!m.canRecord) ...[NoticeBanner(m.store.fieldError!, tone: Tone.danger), const SizedBox(height: 8)],
        RowsCard(children: [
          KeyValueRow('On this phone', '${m.store.log.length} records ($mine made here)', selectable: false),
          KeyValueRow('Not sent yet', m.unsent == 0 ? 'none' : '${m.unsent} records', selectable: false),
        ]),
        const SizedBox(height: 10),
        PrimaryAction(m.unsent > 0 ? 'Send field log (${m.unsent} new)' : 'Send field log',
            icon: 'export', onPressed: m.store.log.length == 0 ? null : () => sendFieldLog(context)),
        const SizedBox(height: 8),
        SecondaryAction('Import a field log from another phone', icon: 'import', onPressed: () => importFieldLogFlow(context)),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'A field log holds every record on this phone and the photos not sent before. Sending it twice is harmless: '
            'records are only ever added, never overwritten. The office imports it with fieldworx-bridge.',
            style: TextStyle(color: fx.muted, fontSize: 13, height: 1.35),
          ),
        ),
        TextButton(
            onPressed: m.store.log.length == 0 ? null : () => sendFieldLog(context, allPhotos: true),
            child: const Text('Send again with every photo')),
        const SectionHeader('This phone'),
        RowsCard(children: [
          EntityRow(
            icon: 'person',
            title: m.userName.isEmpty ? 'Your name: not set' : m.userName,
            subtitle: 'Written into everything you record',
            onTap: () => editName(context),
          ),
          EntityRow(
            icon: 'theme',
            title: 'Theme',
            subtitle: fxThemes[m.theme]?.label ?? 'Modern Light',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ThemeScreen())),
          ),
          EntityRow(
            icon: 'info',
            title: 'About FieldWorx $appVersion',
            subtitle: 'GPL-3.0-or-later · offline · no accounts or telemetry',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
          ),
        ]),
      ]),
    );
  }
}

String _age(String created) {
  final t = DateTime.tryParse(created);
  if (t == null) return 'unknown age';
  final d = DateTime.now().toUtc().difference(t).inDays;
  return d <= 0 ? 'made today' : d == 1 ? '1 day old' : '$d days old';
}

Tone _ageTone(String created) {
  final t = DateTime.tryParse(created);
  if (t == null) return Tone.warn;
  final d = DateTime.now().toUtc().difference(t).inDays;
  return d > 30 ? Tone.warn : Tone.neutral;
}

Future<void> editName(BuildContext context) async {
  final m = AppScope.read(context);
  final ctl = TextEditingController(text: m.userName);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Your name'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctl, autofocus: true, textCapitalization: TextCapitalization.words),
        const SizedBox(height: 8),
        Text('It goes into every record you make. It isn’t an account and isn’t checked.',
            style: TextStyle(color: ctx.fx.muted, fontSize: 13)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
      ],
    ),
  );
  ctl.dispose();
  if (name != null) await m.setUserName(name);
}

class PackageScreen extends StatelessWidget {
  const PackageScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final p = m.catalog.packages.where((x) => x.id == id).firstOrNull;
    if (p == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: 'package', title: 'This package was removed'));
    }
    final c = m.catalog;
    int count(Iterable<dynamic> items) => items.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Package')),
      body: PageList(children: [
        StatusBlock(icon: 'package', kind: 'Package', title: p.title, subtitle: p.sourceName, chips: [
          StatusChip(_age(p.created), tone: _ageTone(p.created)),
          const StatusChip('verified when added', tone: Tone.ok, icon: 'check'),
        ]),
        if (_ageTone(p.created) == Tone.warn) ...[
          const SizedBox(height: 10),
          const NoticeBanner(
              'This package is more than a month old. Drawings may have been revised since; ask engineering for a new one.',
              tone: Tone.warn),
        ],
        if (p.notices.isNotEmpty) ...[
          const SectionHeader('What the package says about itself'),
          RowsCard(children: [for (final n in p.notices) EntityRow(icon: 'info', title: n)]),
        ],
        const SectionHeader('Contents'),
        RowsCard(children: [
          KeyValueRow('Documents', '${count(c.documents.values.where((d) => d.package.id == id))}', selectable: false),
          KeyValueRow('Parts', '${count(c.parts.values.where((x) => x.package.id == id))}', selectable: false),
          KeyValueRow('Units', '${count(c.assets.values.where((x) => x.package.id == id))}', selectable: false),
          KeyValueRow('Templates', '${count(c.templates.where((x) => x.package.id == id))}', selectable: false),
        ]),
        const SectionHeader('Where it came from'),
        RowsCard(children: [
          KeyValueRow('Made', '${shortTime(p.created)} UTC'),
          KeyValueRow('Made by', [p.createdBy['user'], p.createdBy['host'], p.createdBy['tool']].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
          for (final e in p.source.entries) KeyValueRow(e.key, '${e.value}'),
          KeyValueRow('Package id', p.id),
          KeyValueRow('Digest', p.digest),
        ]),
        const SizedBox(height: 16),
        SecondaryAction('Remove from this phone', icon: 'close', onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Remove this package?'),
              content: const Text('Its drawings and parts leave this phone. Field records stay: they are never removed.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
              ],
            ),
          );
          if (ok == true && context.mounted) {
            await m.removePackage(id);
            if (context.mounted) Navigator.of(context).pop();
          }
        }),
      ]),
    );
  }
}

class ThemeScreen extends StatelessWidget {
  const ThemeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Theme')),
      body: PageList(children: [
        Text('The same themes as OpenSchematix, RevisionWorx and OpenMeridian. High Contrast reads best in sunlight.',
            style: TextStyle(color: context.fx.muted)),
        const SizedBox(height: 12),
        RowsCard(children: [
          for (final e in fxThemes.entries)
            EntityRow(
              icon: 'theme',
              title: e.value.label,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final k in ['bg', 'surface', 'accent', 'text'])
                  Container(
                    width: 18,
                    height: 18,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: e.value.c(k),
                      shape: BoxShape.circle,
                      border: Border.all(color: context.fx.borderStrong),
                    ),
                  ),
                const SizedBox(width: 8),
                if (m.theme == e.key) const FxIcon('check', size: 22) else const SizedBox(width: 22),
              ]),
              onTap: () => m.setTheme(e.key),
            ),
        ]),
      ]),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: PageList(children: [
        const StatusBlock(icon: 'scan', kind: 'FieldWorx', title: 'FieldWorx $appVersion', subtitle: 'The field companion to RevisionWorx'),
        const SizedBox(height: 12),
        Text(
          'Engineering stays the authority: this phone shows a verified snapshot of released drawings, parts and BOMs, '
          'and records what happens in the field as permanent, attributed records that go back to the office. Nothing '
          'here can change an approved document; proposed changes go through RevisionWorx.\n\n'
          'Works offline. No accounts, no cloud, no telemetry. Free software under the GNU GPL v3 or later.',
          style: TextStyle(color: fx.text, fontSize: 15, height: 1.45),
        ),
        const SectionHeader('This phone'),
        RowsCard(children: [
          KeyValueRow('Device id', m.store.deviceId),
          KeyValueRow('Records', '${m.store.log.length}'),
        ]),
        const SizedBox(height: 12),
        SecondaryAction('Open-source licences',
            icon: 'library',
            onPressed: () => showLicensePage(
                context: context, applicationName: 'FieldWorx', applicationVersion: appVersion, applicationLegalese: 'GPL-3.0-or-later')),
      ]),
    );
  }
}
