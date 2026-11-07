// SPDX-License-Identifier: GPL-3.0-or-later
// Pages for what a label can point at: assets, parts, documents, projects. Each opens with its status block and
// one primary action, then everything related, with what's out of date said plainly.

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:material_ui/material_ui.dart';

import '../model/app_model.dart';
import '../platform/services.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/fx_icon.dart';
import 'inspect.dart';

/// Opens what a label or a search found. [revision] is the revision a scanned revision label named, for a document.
Future<void> openEntity(BuildContext context, ResultKind kind, String id, {String revision = ''}) {
  final Widget page = switch (kind) {
    ResultKind.asset => AssetScreen(id: id),
    ResultKind.part => PartScreen(id: id),
    ResultKind.document => DocumentScreen(id: id, labelled: revision),
    ResultKind.project => ProjectScreen(id: id),
    ResultKind.template => const SizedBox(),
  };
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

String kindIcon(ResultKind k) => switch (k) {
      ResultKind.asset => 'asset',
      ResultKind.part => 'part',
      ResultKind.document => 'document',
      ResultKind.project => 'project',
      ResultKind.template => 'inspect',
    };

String kindName(ResultKind k) => switch (k) {
      ResultKind.asset => 'Asset',
      ResultKind.part => 'Part',
      ResultKind.document => 'Document',
      ResultKind.project => 'Project',
      ResultKind.template => 'Template',
    };

/// Opens a revision's drawing, if the phone has a view of it.
void openRevision(BuildContext context, Revision r) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ViewerScreen(revisionId: r.id)));
}

String _extName(String ext) => switch (ext) {
      '.schematix' || '.osch' => 'an OpenSchematix project',
      '.draftworx' => 'a DraftWorx drawing',
      '.dxf' => 'a DXF drawing',
      '.dwg' => 'a DWG drawing',
      '.idw' || '.ipt' || '.iam' => 'an Inventor file',
      '.slddrw' || '.sldprt' || '.sldasm' => 'a SolidWorks file',
      '.step' || '.stp' => 'a STEP model',
      '.csv' || '.xlsx' => 'a table',
      _ => ext.isEmpty ? 'a file' : 'a ${ext.substring(1).toUpperCase()} file',
    };

Widget _notFound(BuildContext context, String what) => Scaffold(
      appBar: AppBar(),
      body: EmptyState(
          icon: 'warning',
          title: '$what is not on this phone',
          body: 'It may have been in a package that was removed or replaced.'),
    );

class _LabelAction extends StatelessWidget {
  const _LabelAction(this.kind, this.code, this.title);
  final ResultKind kind;
  final String code, title;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Show label',
        icon: const FxIcon('qr'),
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => LabelScreen(text: labelFor(kind, code), title: title))),
      );
}

// ------------------------------------------------------------------------------------------------ documents
class DocumentScreen extends StatelessWidget {
  const DocumentScreen({super.key, required this.id, this.labelled = ''});
  final String id;

  /// The revision a scanned revision label named (`FWX:R:<number>@<revision>`), when it was opened from one.
  final String labelled;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final c = m.catalog;
    final d = c.documents[id];
    if (d == null) return _notFound(context, 'This document');
    final cur = d.current;
    final released = d.released;
    final project = c.projects[d.projectId];
    final parts = [
      for (final p in c.parts.values)
        if (p.documents.any((l) => l.documentId == d.id)) p,
    ];
    final builtTo = <(Asset, Revision)>[
      for (final a in c.assets.values)
        for (final r in d.revisions)
          if (a.asBuilt.contains(r.id)) (a, r),
    ];
    final viewable = cur?.rendition != null && m.store.objectFile(cur!.rendition!.object).existsSync();
    return Scaffold(
      appBar: AppBar(title: Text(d.label), actions: [if (d.number.isNotEmpty) _LabelAction(ResultKind.document, d.number, d.label)]),
      body: PageList(
        bottom: viewable
            ? PrimaryAction('Open ${cur.ext == '.pdf' ? 'drawing' : 'view'} · rev ${cur.label}',
                icon: 'pdf', onPressed: () => openRevision(context, cur))
            : null,
        children: [
          StatusBlock(icon: 'document', kind: 'Document', title: d.label, subtitle: d.title, chips: [
            if (cur != null)
              StatusChip('rev ${cur.label} · ${cur.stateName.isEmpty ? cur.state : cur.stateName}',
                  tone: stateTone(cur.state)),
            if (d.type.isNotEmpty) StatusChip(d.type),
          ]),
          if (labelled.isNotEmpty) ...[
            const SizedBox(height: 10),
            _LabelledRevisionBanner(LabelledRevision(d, labelled)),
          ],
          if (released == null) ...[
            const SizedBox(height: 10),
            NoticeBanner(
                cur == null
                    ? 'No revision of this document is on the phone.'
                    : 'Not released. Revision ${cur.label} is ${cur.stateName.isEmpty ? cur.state : cur.stateName}; check '
                        'with engineering before working to it.',
                tone: Tone.warn),
          ],
          if (cur != null && cur.rendition == null) ...[
            const SizedBox(height: 10),
            NoticeBanner(
                'This is ${_extName(cur.ext)}, which the phone can’t show. Ask engineering to publish a PDF of it in '
                'RevisionWorx and it will appear in the next package.',
                tone: Tone.info,
                icon: 'info'),
          ],
          SectionHeader('Revisions (${d.revisions.length})'),
          RowsCard(children: [
            for (final r in d.revisions.reversed)
              EntityRow(
                icon: r.rendition != null ? 'pdf' : 'revision',
                title: 'Rev ${r.label}',
                subtitle: [
                  shortDate(r.created),
                  if (r.author.isNotEmpty) r.author,
                  if (r.description.isNotEmpty) r.description,
                ].join(' · '),
                chips: [
                  StatusChip(r.stateName.isEmpty ? r.state : r.stateName, tone: stateTone(r.state)),
                  if (r.rendition == null) const StatusChip('not on this phone'),
                ],
                onTap: r.rendition != null ? () => openRevision(context, r) : null,
              ),
          ]),
          if (builtTo.isNotEmpty) ...[
            const SectionHeader('Units built to it'),
            RowsCard(children: [
              for (final (a, r) in builtTo)
                EntityRow(
                  icon: 'asset',
                  title: a.label,
                  subtitle: '${a.name} · built to rev ${r.label}',
                  chips: [
                    if (released != null && released.id != r.id)
                      StatusChip('older than rev ${released.label}', tone: Tone.warn),
                  ],
                  onTap: () => openEntity(context, ResultKind.asset, a.id),
                ),
            ]),
          ],
          if (parts.isNotEmpty) ...[
            const SectionHeader('Parts'),
            RowsCard(children: [
              for (final p in parts)
                EntityRow(
                    icon: 'part',
                    title: p.number,
                    subtitle: p.description,
                    onTap: () => openEntity(context, ResultKind.part, p.id)),
            ]),
          ],
          if (project != null) ...[
            const SectionHeader('Project'),
            RowsCard(children: [
              EntityRow(
                  icon: 'project',
                  title: project.label,
                  subtitle: project.customer,
                  onTap: () => openEntity(context, ResultKind.project, project.id)),
            ]),
          ],
          const SectionHeader('Source'),
          RowsCard(children: [
            KeyValueRow('File', d.path),
            KeyValueRow('Package', '${d.package.title} · ${shortDate(d.package.created)}'),
            if (cur != null) KeyValueRow('SHA-256', cur.sha256),
          ]),
        ],
      ),
    );
  }
}

/// What a scanned revision label means here: the released revision, a superseded one (work to the released one), or one
/// this phone doesn't have.
class _LabelledRevisionBanner extends StatelessWidget {
  const _LabelledRevisionBanner(this.label);
  final LabelledRevision label;

  @override
  Widget build(BuildContext context) {
    final tone = label.isReleased ? Tone.ok : (label.isSuperseded ? Tone.danger : Tone.warn);
    final r = label.revision;
    if (r == null || label.isReleased || r.rendition == null) {
      return NoticeBanner(label.sentence, tone: tone, icon: label.isReleased ? 'check' : null);
    }
    // The labelled revision itself, to compare with the print; the page's main action stays the released one.
    return NoticeBanner(label.sentence, tone: tone, action: 'Open rev ${r.label}', onAction: () => openRevision(context, r));
  }
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.revisionId});
  final String revisionId;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final handle = ViewerHandle();
  final _find = TextEditingController();
  bool _finding = false;

  @override
  void initState() {
    super.initState();
    handle.addListener(_update);
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    handle.removeListener(_update);
    handle.dispose();
    _find.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    final r = m.catalog.revisions[widget.revisionId];
    if (r == null || r.rendition == null) return _notFound(context, 'This drawing');
    final file = m.objectFile(r.rendition!.object);
    final d = r.document;
    final released = d.released;
    String? warning;
    if (released != null && released.id != r.id) {
      warning = r.state == 'superseded' || r.state == 'obsolete'
          ? '${r.stateName.isEmpty ? r.state : r.stateName}. The current revision is ${released.label}.'
          : 'Not the released revision (rev ${released.label} is released).';
    } else if (released == null) {
      warning = 'Not released. Check with engineering before working to it.';
    }
    return Scaffold(
      appBar: AppBar(
        title: _finding
            ? TextField(
                controller: _find,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(hintText: 'Find text on the drawing', isDense: true),
                onSubmitted: handle.search,
              )
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(revisionSentence(r), overflow: TextOverflow.ellipsis),
                if (handle.pages > 0)
                  Text('Page ${handle.page} of ${handle.pages}',
                      style: TextStyle(fontSize: 13, color: fx.muted, fontWeight: FontWeight.w400)),
              ]),
        actions: [
          if (_finding) ...[
            if (handle.matchCount > 0)
              Center(child: Text('${handle.matchIndex + 1}/${handle.matchCount}', style: TextStyle(color: fx.muted))),
            IconButton(tooltip: 'Previous', onPressed: handle.previous, icon: const Icon(Icons.keyboard_arrow_up)),
            IconButton(tooltip: 'Next', onPressed: handle.next, icon: const Icon(Icons.keyboard_arrow_down)),
            IconButton(
                tooltip: 'Stop finding',
                onPressed: () => setState(() {
                      _finding = false;
                      _find.clear();
                      handle.clear();
                    }),
                icon: const FxIcon('close')),
          ] else ...[
            IconButton(tooltip: 'Find text', onPressed: () => setState(() => _finding = true), icon: const FxIcon('search')),
            IconButton(tooltip: 'Zoom in', onPressed: handle.zoomIn, icon: const Icon(Icons.zoom_in)),
            IconButton(tooltip: 'Zoom out', onPressed: handle.zoomOut, icon: const Icon(Icons.zoom_out)),
          ],
        ],
      ),
      body: Column(children: [
        if (warning != null)
          Container(
            width: double.infinity,
            color: fx.toneBg(r.state == 'superseded' || r.state == 'obsolete' ? Tone.danger : Tone.warn),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(warning,
                style: TextStyle(
                    color: fx.toneFg(r.state == 'superseded' || r.state == 'obsolete' ? Tone.danger : Tone.warn),
                    fontWeight: FontWeight.w600)),
          ),
        if (_finding && handle.searching == false && handle.matchCount == 0 && _find.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('No matches for “${_find.text}”.', style: TextStyle(color: fx.muted)),
          ),
        Expanded(
          child: file.existsSync()
              ? m.services.pdfViewer(file: file, handle: handle)
              : const EmptyState(
                  icon: 'error',
                  title: 'The drawing file is missing',
                  body: 'Remove the package and add it again.'),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------------------------------- parts
class PartScreen extends StatelessWidget {
  const PartScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final c = m.catalog;
    final p = c.parts[id];
    if (p == null) return _notFound(context, 'This part');
    final docs = c.documentsForPart(p);
    final children = c.children(p.id);
    final parents = c.parentsOf(p.id);
    final assets = c.assetsForPart(p.id);
    final drawing = docs.where((x) => x.$1.current?.rendition != null).firstOrNull;
    final st = p.stock;
    final inStock = st != null && compareDecimal(st.onHand, '0') > 0;
    return Scaffold(
      appBar: AppBar(title: Text(p.number), actions: [_LabelAction(ResultKind.part, p.number, p.number)]),
      body: PageList(
        bottom: drawing != null
            ? PrimaryAction('Open ${drawing.$2.isEmpty ? 'drawing' : drawing.$2} ${drawing.$1.label}',
                icon: 'pdf', onPressed: () => openRevision(context, drawing.$1.current!))
            : null,
        children: [
          StatusBlock(icon: 'part', kind: p.kind.isEmpty ? 'Part' : p.kind, title: p.number, subtitle: p.description, chips: [
            if (p.revision.isNotEmpty) StatusChip('rev ${p.revision}'),
            if (st != null)
              StatusChip('${st.onHand} ${st.unit} in stock${st.bin.isEmpty ? '' : ' · bin ${st.bin}'}',
                  tone: inStock ? Tone.ok : Tone.danger, icon: 'stock'),
            if (p.status.isNotEmpty && p.status != 'active') StatusChip(p.status, tone: Tone.warn),
          ]),
          if (st != null) ...[
            const SizedBox(height: 8),
            Text('Stock from ${st.source}, as of ${shortTime(st.asOf)} UTC. It isn’t live.',
                style: TextStyle(color: context.fx.muted, fontSize: 13)),
          ],
          if (docs.isNotEmpty) ...[
            const SectionHeader('Documents'),
            RowsCard(children: [
              for (final (d, role) in docs)
                EntityRow(
                  icon: d.current?.rendition != null ? 'pdf' : 'document',
                  title: d.label,
                  subtitle: [if (role.isNotEmpty) role, d.title].join(' · '),
                  chips: [
                    if (d.current != null)
                      StatusChip('rev ${d.current!.label} · ${d.current!.stateName}', tone: stateTone(d.current!.state)),
                  ],
                  onTap: () => openEntity(context, ResultKind.document, d.id),
                ),
            ]),
          ],
          if (children.isNotEmpty) ...[
            SectionHeader('Made from (${children.length})'),
            RowsCard(children: [
              for (final l in children) _BomRow(line: l, part: c.parts[l.childId], showChild: true),
            ]),
          ],
          if (parents.isNotEmpty) ...[
            SectionHeader('Used in (${parents.length})'),
            RowsCard(children: [
              for (final l in parents) _BomRow(line: l, part: c.parts[l.parentId], showChild: false),
            ]),
          ],
          if (assets.isNotEmpty) ...[
            const SectionHeader('Units'),
            RowsCard(children: [
              for (final a in assets)
                EntityRow(
                    icon: 'asset',
                    title: a.label,
                    subtitle: [a.name, a.location].where((x) => x.isNotEmpty).join(' · '),
                    onTap: () => openEntity(context, ResultKind.asset, a.id)),
            ]),
          ],
          if (p.manufacturers.isNotEmpty || p.vendors.isNotEmpty) ...[
            const SectionHeader('Buying it'),
            RowsCard(children: [
              for (final x in p.manufacturers) KeyValueRow(x.name.isEmpty ? 'Manufacturer' : x.name, x.code),
              for (final x in p.vendors) KeyValueRow(x.name.isEmpty ? 'Vendor' : x.name, x.code),
            ]),
          ],
          if (p.attributes.isNotEmpty) ...[
            const SectionHeader('Attributes'),
            RowsCard(children: [for (final e in p.attributes.entries) KeyValueRow(e.key, e.value)]),
          ],
          const SectionHeader('Details'),
          RowsCard(children: [
            KeyValueRow('Unit', p.unit),
            if (st != null) KeyValueRow('Bin', st.bin),
            KeyValueRow('Package', '${p.package.title} · ${shortDate(p.package.created)}'),
          ]),
        ],
      ),
    );
  }
}

class _BomRow extends StatelessWidget {
  const _BomRow({required this.line, required this.part, required this.showChild});
  final BomLine line;
  final Part? part;
  final bool showChild;

  @override
  Widget build(BuildContext context) {
    final p = part;
    final qty = '${line.quantity} ${line.unit}';
    return EntityRow(
      icon: 'part',
      title: p?.number ?? (showChild ? line.childId : line.parentId),
      subtitle: [
        if (line.findNumber.isNotEmpty) 'item ${line.findNumber}',
        qty,
        if (p != null && p.description.isNotEmpty) p.description,
        if (line.note.isNotEmpty) line.note,
      ].join(' · '),
      chips: [
        if (line.refdes.isNotEmpty) StatusChip(line.refdes.join(' '), tone: Tone.info),
        if (line.provenance == 'inferred' || line.provenance == 'unknown')
          const StatusChip('needs verification', tone: Tone.warn),
      ],
      onTap: p == null ? null : () => openEntity(context, ResultKind.part, p.id),
    );
  }
}

// --------------------------------------------------------------------------------------------------- assets
class AssetScreen extends StatelessWidget {
  const AssetScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final c = m.catalog;
    final a = c.asset(id);
    if (a == null) return _notFound(context, 'This asset');
    final part = c.parts[a.partId];
    final project = c.projects[a.projectId];
    final parent = a.parentId.isEmpty ? null : c.asset(a.parentId);
    final asBuilt = [
      for (final d in a.documents)
        if (d.applies && c.revisions[d.revisionId] != null) (d, c.revisions[d.revisionId]!),
    ];
    final notApplied = [
      for (final d in a.documents)
        if (!d.applies && c.documents[d.documentId] != null) c.documents[d.documentId]!,
    ];
    final history = m.inspectionsFor(a.id, also: a.aliases);
    final outOfDate =
        asBuilt.where((x) => x.$2.document.released != null && x.$2.document.released!.id != x.$2.id).length;
    final details = <Widget>[
      if (a.isUnit)
        for (final i in a.identifiers) KeyValueRow(_identifierName(i), i.issuer.isEmpty ? i.value : '${i.value} (${i.issuer})'),
      if (a.customer.isNotEmpty) KeyValueRow('Customer', a.customer),
      if (a.site.isNotEmpty) KeyValueRow('Site', a.site),
      if (a.location.isNotEmpty) KeyValueRow('Location', a.location),
      if (a.standardNumber.isNotEmpty)
        KeyValueRow('Build standard', [a.standardNumber, a.standardTitle].where((s) => s.isNotEmpty).join(' · ')),
      for (final k in milestoneNames)
        if (k != 'built' && (a.milestones[k] ?? '').isNotEmpty) KeyValueRow(_capitalised(k), a.milestones[k]!),
      if (a.notes.isNotEmpty) KeyValueRow('Notes', a.notes),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(a.label), actions: [_LabelAction(ResultKind.asset, a.labelCode, a.label)]),
      body: PageList(
        bottom: c.templates.isNotEmpty && m.canRecord
            ? PrimaryAction('Start an inspection',
                icon: 'inspect',
                onPressed: () => startInspectionFlow(context,
                    subject: {'kind': 'asset', 'id': a.id, 'label': a.label}, titlePrefix: a.label))
            : null,
        children: [
          StatusBlock(icon: 'asset', kind: a.isUnit ? 'Unit' : 'Asset', title: a.label, subtitle: a.name, chips: [
            if (a.serial.isNotEmpty && a.serial != a.label) StatusChip('S/N ${a.serial}'),
            if (a.isUnit && a.tag.isNotEmpty && a.tag != a.label) StatusChip(a.tag),
            if (a.status.isNotEmpty) StatusChip(a.status.replaceAll('-', ' '), tone: _statusTone(a.status)),
            if (a.built.isNotEmpty) StatusChip('built ${a.built}'),
            if (outOfDate > 0)
              StatusChip('$outOfDate drawing${outOfDate == 1 ? '' : 's'} revised since', tone: Tone.warn),
            if (a.outstandingChanges.isNotEmpty)
              StatusChip(
                  '${a.outstandingChanges.length} change${a.outstandingChanges.length == 1 ? '' : 's'} outstanding',
                  tone: Tone.warn),
          ]),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 10),
            RowsCard(children: details),
          ],
          if (asBuilt.isNotEmpty || notApplied.isNotEmpty) ...[
            const SectionHeader('As built'),
            RowsCard(children: [
              for (final (d, r) in asBuilt)
                EntityRow(
                  icon: r.rendition != null ? 'pdf' : 'document',
                  title: '${r.document.label} rev ${r.label}',
                  subtitle: r.document.title,
                  chips: [
                    StatusChip(r.stateName.isEmpty ? r.state : r.stateName, tone: stateTone(r.state)),
                    if (r.document.released != null && r.document.released!.id != r.id)
                      StatusChip('current is rev ${r.document.released!.label}', tone: Tone.warn),
                    if (a.isUnit && d.source == 'unit' && a.standardNumber.isNotEmpty)
                      const StatusChip('this unit only', tone: Tone.info),
                    if (a.isUnit) ..._basisChips(d.basis),
                  ],
                  onTap: r.rendition != null
                      ? () => openRevision(context, r)
                      : () => openEntity(context, ResultKind.document, r.document.id),
                ),
              for (final doc in notApplied)
                EntityRow(
                  icon: 'document',
                  title: doc.label,
                  subtitle: doc.title,
                  chips: const [StatusChip('doesn’t apply to this unit')],
                  onTap: () => openEntity(context, ResultKind.document, doc.id),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                  a.isUnit
                      ? 'These are the revisions that apply to this unit: its build standard’s, and any recorded for this '
                          'unit alone. They may be older than what is released now.'
                      : 'These are the revisions this unit was built to, which may be older than what is released now.',
                  style: TextStyle(color: context.fx.muted, fontSize: 13)),
            ),
          ],
          if (a.changes.isNotEmpty) ...[
            SectionHeader('Engineering changes (${a.changes.length})'),
            RowsCard(children: [
              for (final ch in a.changes)
                EntityRow(
                  icon: ch.outstanding ? 'warning' : 'revision',
                  title: ch.number,
                  subtitle: [
                    ch.title,
                    for (final (doc, from, to) in ch.documents) '$doc rev $from → $to',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  chips: [
                    StatusChip(ch.state.replaceAll('-', ' '),
                        tone: ch.outstanding
                            ? Tone.warn
                            : ch.state == 'verified'
                                ? Tone.ok
                                : Tone.neutral),
                    if (_changeKinds[ch.kind] != null) StatusChip(_changeKinds[ch.kind]!),
                    if (ch.since.isNotEmpty) StatusChip('since ${ch.since}'),
                  ],
                ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                  'Where each change stands, as RevisionWorx recorded it. It is settled there: record what you did as an '
                  'inspection, and engineering updates the unit.',
                  style: TextStyle(color: context.fx.muted, fontSize: 13)),
            ),
          ],
          if (a.parentId.isNotEmpty) ...[
            const SectionHeader('Fitted in'),
            RowsCard(children: [
              EntityRow(
                icon: 'asset',
                title: parent?.label ?? 'A unit that isn’t on this phone',
                subtitle: [if (parent != null) parent.name, 'position ${a.parentPosition}'].join(' · '),
                onTap: parent == null ? null : () => openEntity(context, ResultKind.asset, parent.id),
              ),
            ]),
          ],
          if (a.components.isNotEmpty) ...[
            SectionHeader('Fitted (${a.components.length})'),
            RowsCard(children: [for (final f in a.components) _componentRow(context, c, f)]),
          ],
          if (part != null) ...[
            const SectionHeader('Model'),
            RowsCard(children: [
              EntityRow(
                  icon: 'part',
                  title: part.number,
                  subtitle: part.description,
                  onTap: () => openEntity(context, ResultKind.part, part.id)),
            ]),
          ],
          SectionHeader('Inspections (${history.length})'),
          if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('Nothing recorded on this unit yet.', style: TextStyle(color: context.fx.muted)),
            )
          else
            RowsCard(children: [for (final s in history) InspectionRow(state: s)]),
          if (a.history.isNotEmpty) ...[
            SectionHeader('Record (${a.history.length})'),
            RowsCard(children: [
              for (final h in a.history.reversed)
                EntityRow(
                  icon: 'clock',
                  title: h.summary.isEmpty ? h.type : h.summary,
                  subtitle: [h.effective, h.actor].where((s) => s.isNotEmpty).join(' · '),
                  chips: [
                    if (h.voided) const StatusChip('voided', tone: Tone.warn),
                    ..._basisChips(h.basis),
                  ],
                ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text('From RevisionWorx’s unit register. Changes to it are made there, not on the phone.',
                  style: TextStyle(color: context.fx.muted, fontSize: 13)),
            ),
          ],
          if (project != null) ...[
            const SectionHeader('Project'),
            RowsCard(children: [
              EntityRow(
                  icon: 'project',
                  title: project.label,
                  subtitle: project.customer,
                  onTap: () => openEntity(context, ResultKind.project, project.id)),
            ]),
          ],
        ],
      ),
    );
  }
}

String _capitalised(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

const Map<String, String> _changeKinds = {
  'production': 'new units only',
  'retrofit-required': 'retrofit required',
  'retrofit-optional': 'retrofit optional',
  'unit': 'this unit',
  'documentation': 'documents only',
};

String _identifierName(AssetIdentifier i) {
  final name = switch (i.scheme) { 'tag' => 'asset tag', 'serial' => 'serial number', _ => 'code' };
  return _capitalised(i.active ? name : 'former $name');
}

Tone _statusTone(String status) => switch (status) {
      'in-service' || 'built' => Tone.ok,
      'out-of-service' => Tone.warn,
      _ => Tone.neutral,
    };

/// How well a fact is known, when it is less than verified.
List<Widget> _basisChips(String basis) => [
      if (basis == 'reported') const StatusChip('reported'),
      if (basis == 'declared') const StatusChip('declared'),
      if (basis == 'legacy') const StatusChip('from old records'),
    ];

Widget _componentRow(BuildContext context, Catalog c, AssetComponent f) {
  final unit = f.assetId.isEmpty ? null : c.asset(f.assetId);
  final part = c.parts[f.partId];
  final what = unit?.label ?? (f.number.isNotEmpty ? f.number : (part?.number ?? 'a part'));
  return EntityRow(
    icon: unit != null ? 'asset' : 'part',
    title: '${f.position} · $what',
    subtitle: [
      if (unit != null) unit.name else if (part != null) part.description,
      if (unit == null && f.serial.isNotEmpty) 'S/N ${f.serial}',
      if (f.lot.isNotEmpty) 'lot ${f.lot}',
      if (f.since.isNotEmpty) 'since ${f.since}',
    ].where((s) => s.isNotEmpty).join(' · '),
    chips: _basisChips(f.basis),
    onTap: unit != null
        ? () => openEntity(context, ResultKind.asset, unit.id)
        : part != null
            ? () => openEntity(context, ResultKind.part, part.id)
            : null,
  );
}

// ------------------------------------------------------------------------------------------------- projects
class ProjectScreen extends StatelessWidget {
  const ProjectScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context).catalog;
    final p = c.projects[id];
    if (p == null) return _notFound(context, 'This project');
    final docs = c.documentsForProject(p.id);
    final assets = c.assetsForProject(p.id);
    return Scaffold(
      appBar: AppBar(title: Text(p.number.isEmpty ? p.name : p.number)),
      body: PageList(children: [
        StatusBlock(icon: 'project', kind: 'Project', title: p.label, subtitle: p.customer),
        if (assets.isNotEmpty) ...[
          SectionHeader('Units (${assets.length})'),
          RowsCard(children: [
            for (final a in assets)
              EntityRow(icon: 'asset', title: a.label, subtitle: a.name, onTap: () => openEntity(context, ResultKind.asset, a.id)),
          ]),
        ],
        SectionHeader('Documents (${docs.length})'),
        RowsCard(children: [
          for (final d in docs)
            EntityRow(
              icon: d.current?.rendition != null ? 'pdf' : 'document',
              title: d.label,
              subtitle: d.title,
              chips: [
                if (d.current != null)
                  StatusChip('rev ${d.current!.label} · ${d.current!.stateName}', tone: stateTone(d.current!.state)),
              ],
              onTap: () => openEntity(context, ResultKind.document, d.id),
            ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------------------------------- labels
class LabelScreen extends StatelessWidget {
  const LabelScreen({super.key, required this.text, required this.title});
  final String text, title;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    return Scaffold(
      appBar: AppBar(title: Text('Label · $title')),
      body: PageList(children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(12)),
            child: m.services.qrCode(text, size: 240),
          ),
        ),
        const SizedBox(height: 14),
        Center(child: SelectableText(text, style: TextStyle(color: fx.text, fontSize: 20, fontWeight: FontWeight.w700))),
        const SizedBox(height: 16),
        Text(
          'Any phone with FieldWorx opens this page by scanning the code. The text under it works too: type it in, or '
          'scan it with a hardware scanner. FieldWorx labels never contain web addresses, so they mean the same thing '
          'offline and years from now.',
          style: TextStyle(color: fx.muted, fontSize: 14, height: 1.4),
        ),
      ]),
    );
  }
}
