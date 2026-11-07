// SPDX-License-Identifier: GPL-3.0-or-later
// Find: one search box across units, parts (numbers, MPNs, order codes, reference designators), documents and
// projects; with nothing typed, browse by project.

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:material_ui/material_ui.dart';

import '../model/app_model.dart';
import '../widgets/common.dart';
import '../widgets/fx_icon.dart';
import 'entities.dart';

class FindTab extends StatelessWidget {
  const FindTab({super.key});

  @override
  Widget build(BuildContext context) => const SearchBody(initial: '', standalone: false);
}

class SearchBody extends StatefulWidget {
  const SearchBody({super.key, required this.initial, required this.standalone});
  final String initial;
  final bool standalone;

  @override
  State<SearchBody> createState() => _SearchBodyState();
}

class _SearchBodyState extends State<SearchBody> {
  late final _q = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final c = m.catalog;
    final results = c.search(_q.text);
    final field = TextField(
      controller: _q,
      autofocus: widget.standalone,
      autocorrect: false,
      textInputAction: TextInputAction.search,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: 'Number, description, MPN, serial, K1…',
        prefixIcon: const Padding(padding: EdgeInsets.all(12), child: FxIcon('search', size: 22)),
        suffixIcon: _q.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                onPressed: () => setState(_q.clear),
                icon: const FxIcon('close', size: 20),
              ),
      ),
    );
    final List<Widget> body;
    if (c.isEmpty) {
      body = [const EmptyState(icon: 'search', title: 'Nothing to search yet', body: 'Add a package in Library first.')];
    } else if (_q.text.trim().isEmpty) {
      final projects = c.projects.values.toList()..sort((a, b) => naturalCompare(a.label, b.label));
      body = [
        const SectionHeader('Browse'),
        RowsCard(children: [
          EntityRow(
              icon: 'asset',
              title: 'Units',
              subtitle: '${c.assets.length} built units with their as-built drawings',
              onTap: () => _browse(context, ResultKind.asset)),
          EntityRow(
              icon: 'part',
              title: 'Parts',
              subtitle: '${c.parts.length} parts',
              onTap: () => _browse(context, ResultKind.part)),
          EntityRow(
              icon: 'document',
              title: 'Documents',
              subtitle: '${c.documents.length} documents',
              onTap: () => _browse(context, ResultKind.document)),
        ]),
        if (projects.isNotEmpty) ...[
          const SectionHeader('Projects'),
          RowsCard(children: [
            for (final p in projects)
              EntityRow(
                  icon: 'project',
                  title: p.label,
                  subtitle: p.customer,
                  onTap: () => openEntity(context, ResultKind.project, p.id)),
          ]),
        ],
      ];
    } else if (results.isEmpty) {
      body = [
        EmptyState(
            icon: 'search',
            title: 'No matches',
            body: 'Nothing on this phone matches “${_q.text.trim()}”. Packages only hold the projects they were made for.'),
      ];
    } else {
      body = [
        const SizedBox(height: 10),
        RowsCard(children: [
          for (final r in results)
            EntityRow(
              icon: kindIcon(r.kind),
              title: r.title,
              subtitle: r.subtitle,
              chips: [StatusChip(kindName(r.kind)), if (r.why != kindName(r.kind).toLowerCase()) StatusChip(r.why)],
              onTap: () => openEntity(context, r.kind, r.id),
            ),
        ]),
      ];
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.standalone ? 'Search' : 'Find')),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 28), children: [field, ...body]),
    );
  }

  void _browse(BuildContext context, ResultKind kind) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BrowseScreen(kind: kind)));
}

class BrowseScreen extends StatelessWidget {
  const BrowseScreen({super.key, required this.kind});
  final ResultKind kind;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context).catalog;
    final rows = <Widget>[];
    switch (kind) {
      case ResultKind.asset:
        final list = c.assets.values.toList()..sort((a, b) => naturalCompare(a.label, b.label));
        rows.addAll([
          for (final a in list)
            EntityRow(icon: 'asset', title: a.label, subtitle: a.name, onTap: () => openEntity(context, kind, a.id)),
        ]);
      case ResultKind.part:
        final list = c.parts.values.toList()..sort((a, b) => naturalCompare(a.number, b.number));
        rows.addAll([
          for (final p in list)
            EntityRow(
              icon: 'part',
              title: p.number,
              subtitle: p.description,
              chips: [if (p.stock != null) StatusChip('${p.stock!.onHand} ${p.stock!.unit}')],
              onTap: () => openEntity(context, kind, p.id),
            ),
        ]);
      case ResultKind.document:
        final list = c.documents.values.toList()..sort((a, b) => naturalCompare(a.label, b.label));
        rows.addAll([
          for (final d in list)
            EntityRow(
              icon: d.current?.rendition != null ? 'pdf' : 'document',
              title: d.label,
              subtitle: d.title,
              chips: [
                if (d.current != null)
                  StatusChip('rev ${d.current!.label} · ${d.current!.stateName}', tone: stateTone(d.current!.state)),
              ],
              onTap: () => openEntity(context, kind, d.id),
            ),
        ]);
      case ResultKind.project:
      case ResultKind.template:
        break;
    }
    return Scaffold(
      appBar: AppBar(title: Text(switch (kind) {
        ResultKind.asset => 'Units',
        ResultKind.part => 'Parts',
        _ => 'Documents',
      })),
      body: rows.isEmpty
          ? const EmptyState(icon: 'search', title: 'None in the installed packages')
          : ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 28), children: [RowsCard(children: rows)]),
    );
  }
}
