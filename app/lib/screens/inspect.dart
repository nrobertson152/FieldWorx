// SPDX-License-Identifier: GPL-3.0-or-later
// Inspections: pick a controlled template, answer item by item (big targets, gloves on), add photos, complete.
// Every tap is a field record: nothing is overwritten, and answers made on two phones at once show as a conflict
// for a person to settle, never silently resolved.

import 'dart:io';

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../model/app_model.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/fx_icon.dart';
import 'entities.dart';

String statusName(String s) => switch (s) {
      'open' => 'Open',
      'completed' => 'Completed',
      'voided' => 'Voided',
      'conflict' => 'Status conflict',
      _ => s,
    };

Tone statusTone(String s) => switch (s) {
      'completed' => Tone.ok,
      'voided' => Tone.neutral,
      'conflict' => Tone.warn,
      _ => Tone.info,
    };

class InspectionRow extends StatelessWidget {
  const InspectionRow({super.key, required this.state});
  final Map<String, Object?> state;

  @override
  Widget build(BuildContext context) {
    if (state['valid'] != true) {
      return EntityRow(
        icon: 'warning',
        title: 'Unreadable inspection',
        subtitle: ((state['problems'] as List?) ?? const []).join('; '),
      );
    }
    final t = state['template']! as Map;
    final subject = state['subject']! as Map;
    final started = state['started']! as Map;
    final status = state['status']! as String;
    final outcome = state['outcome']! as String;
    final completion = state['completion'] as Map?;
    return EntityRow(
      icon: 'inspect',
      title: (state['title'] as String?)?.isNotEmpty == true ? state['title']! as String : t['title']! as String,
      subtitle: [
        '${t['id']}${(t['revision'] as String).isEmpty ? '' : ' rev ${t['revision']}'}',
        if ((subject['label'] as String).isNotEmpty) subject['label'] as String,
        shortTime(started['time']! as String),
        if ((started['actor'] as String).isNotEmpty) started['actor'] as String,
      ].join(' · '),
      chips: [
        StatusChip(statusName(status), tone: statusTone(status)),
        if (status != 'voided') StatusChip(outcomeName(outcome), tone: outcomeTone(outcome)),
        if (completion != null && completion['stale'] == true) const StatusChip('changed after completion', tone: Tone.warn),
      ],
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => InspectionScreen(id: state['entity']! as String))),
    );
  }
}

/// Choose a template (and confirm the subject), then open the new inspection.
Future<void> startInspectionFlow(BuildContext context, {Map<String, String>? subject, String titlePrefix = ''}) async {
  final m = AppScope.read(context);
  final templates = m.catalog.sortedTemplates();
  if (templates.isEmpty) {
    showMessage(context, 'No inspection templates in the installed packages.');
    return;
  }
  final chosen = await showModalBottomSheet<TemplateEntry>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), children: [
          Text(subject == null ? 'New inspection' : 'Inspect ${subject['label']}',
              style: TextStyle(color: ctx.fx.text, fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Choose the inspection and test plan to work to.', style: TextStyle(color: ctx.fx.muted)),
          const SizedBox(height: 12),
          RowsCard(children: [
            for (final t in templates)
              EntityRow(
                icon: 'inspect',
                title: '${t.id}${t.revision.isEmpty ? '' : ' rev ${t.revision}'}',
                subtitle: t.title,
                chips: [
                  if (!t.controlled)
                    const StatusChip('uncontrolled', tone: Tone.warn)
                  else if (t.state != 'released')
                    StatusChip(t.state, tone: Tone.warn),
                ],
                onTap: () => Navigator.of(ctx).pop(t),
              ),
          ]),
        ]),
      ),
    ),
  );
  if (chosen == null || !context.mounted) return;
  try {
    final title = [titlePrefix, chosen.title].where((s) => s.isNotEmpty).join(' · ');
    final id = await m.startInspection(chosen, title: title, subject: subject);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InspectionScreen(id: id)));
  } on Exception catch (e) {
    if (context.mounted) showMessage(context, explain(e), error: true);
  }
}

class InspectTab extends StatelessWidget {
  const InspectTab({super.key});

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final all = m.inspections();
    int rank(Map<String, Object?> s) => s['valid'] != true
        ? 0
        : s['status'] == 'open' || s['status'] == 'conflict' || (s['completion'] as Map?)?['stale'] == true
            ? 1
            : 2;
    all.sort((a, b) {
      final r = rank(a) - rank(b);
      if (r != 0) return r;
      final ta = ((a['started'] as Map?)?['time'] as String?) ?? '';
      final tb = ((b['started'] as Map?)?['time'] as String?) ?? '';
      return tb.compareTo(ta);
    });
    final open = all.where((s) => rank(s) <= 1).toList();
    final done = all.where((s) => rank(s) == 2).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Inspections')),
      floatingActionButton: m.catalog.templates.isEmpty || !m.canRecord
          ? null
          : FloatingActionButton.extended(
              onPressed: () => startInspectionFlow(context),
              icon: FxIcon('plus', color: context.fx.accentText, accent: context.fx.accentText),
              label: const Text('New inspection'),
            ),
      body: all.isEmpty
          ? Center(
              child: SingleChildScrollView(
                child: EmptyState(
                  icon: 'inspect',
                  title: 'No inspections yet',
                  body: m.catalog.templates.isEmpty
                      ? 'Inspection templates come in packages from engineering.'
                      : 'Scan a unit and choose “Start an inspection”, or start one here.',
                ),
              ),
            )
          : PageList(children: [
              if (!m.canRecord) NoticeBanner(m.store.fieldError!, tone: Tone.danger),
              if (m.unsent > 0)
                NoticeBanner('${m.unsent} record${m.unsent == 1 ? '' : 's'} not sent to the office yet.',
                    tone: Tone.info,
                    icon: 'export',
                    action: 'Send',
                    onAction: () => sendFieldLog(context)),
              if (open.isNotEmpty) ...[
                SectionHeader('Open (${open.length})'),
                RowsCard(children: [for (final s in open) InspectionRow(state: s)]),
              ],
              if (done.isNotEmpty) ...[
                SectionHeader('Done (${done.length})'),
                RowsCard(children: [for (final s in done) InspectionRow(state: s)]),
              ],
              const SizedBox(height: 70),
            ]),
    );
  }
}

/// Writes a field log and hands it to the share sheet.
Future<void> sendFieldLog(BuildContext context, {bool allPhotos = false}) async {
  final m = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final f = await m.exportFieldLog(allPhotos: allPhotos);
    await m.services.shareFile(f,
        subject: 'FieldWorx field log',
        text: 'Field records from ${m.userName.isEmpty ? 'FieldWorx' : m.userName}. Import with: '
            'fieldworx-bridge import ${f.uri.pathSegments.last}');
  } on Exception catch (e) {
    showMessageOn(messenger, explain(e), error: true);
  }
}

// ----------------------------------------------------------------------------------------- one inspection
class InspectionScreen extends StatefulWidget {
  const InspectionScreen({super.key, required this.id});
  final String id;

  @override
  State<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends State<InspectionScreen> {
  bool _saving = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await action();
      HapticFeedback.selectionClick();
    } on Exception catch (e) {
      if (mounted) showMessage(context, explain(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _ask(String title, String hint, {bool required = true, String action = 'Save'}) =>
      askText(context, title: title, hint: hint, required: required, action: action);

  Future<void> _photo({String item = ''}) async {
    final m = AppScope.read(context);
    final File? f;
    try {
      f = await m.services.takePhoto();
    } on Exception catch (e) {
      if (mounted) showMessage(context, 'The camera could not be opened: $e', error: true);
      return;
    }
    if (f == null) return;
    await _run(() => m.attachPhoto(widget.id, f!, item: item));
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    final s = m.inspection(widget.id);
    if (s['valid'] != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Inspection')),
        body: PageList(children: [
          NoticeBanner('This inspection can’t be shown: ${((s['problems'] as List?) ?? const []).join('; ')}',
              tone: Tone.danger),
        ]),
      );
    }
    final ev = m.store.log.entityEvents(widget.id).firstWhere((e) => e.type == 'inspection.start');
    final template = ev.body['template']! as Map<String, Object?>;
    final t = s['template']! as Map;
    final subject = s['subject']! as Map;
    final status = s['status']! as String;
    final outcome = s['outcome']! as String;
    final completion = s['completion'] as Map?;
    final items = {for (final i in (s['items']! as List).cast<Map<String, Object?>>()) i['id']! as String: i};
    final atts = (s['attachments']! as List).cast<Map<String, Object?>>();
    final notes = (s['notes']! as List).cast<Map<String, Object?>>();
    final problems = (s['problems']! as List).cast<String>();
    final locked = status == 'completed' || status == 'voided' || !m.canRecord;
    final openRequired = [
      for (final it in templateItems(template))
        if (it['required'] == true && (items[it['id']]?['outcome'] == 'open' || items[it['id']]?['outcome'] == 'photo-missing'))
          it,
    ];
    final conflicts = items.values.where((i) => i['outcome'] == 'conflict').length;

    Widget bottom;
    if (status == 'completed' && completion != null) {
      bottom = Row(children: [
        Expanded(
          child: Text(
            'Completed by ${completion['actor'] == '' ? 'someone' : completion['actor']} · ${shortTime(completion['time']! as String)}'
            ' · ${outcomeName(completion['result']! as String)}',
            style: TextStyle(color: fx.text, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(
          onPressed: !m.canRecord
              ? null
              : () async {
                  final why = await _ask('Reopen this inspection?', 'Why (kept with the record)', action: 'Reopen');
                  if (why != null) await _run(() => m.reopen(widget.id, why));
                },
          child: const Text('Reopen'),
        ),
      ]);
    } else if (status == 'voided') {
      bottom = Text('Voided. Nothing more can be recorded on it.', style: TextStyle(color: fx.muted));
    } else {
      final ready = openRequired.isEmpty && conflicts == 0 && (outcome == 'pass' || outcome == 'fail');
      bottom = PrimaryAction(
        ready
            ? 'Complete · ${outcomeName(outcome)}'
            : conflicts > 0
                ? 'Settle $conflicts conflict${conflicts == 1 ? '' : 's'} first'
                : '${openRequired.length} required item${openRequired.length == 1 ? '' : 's'} to go',
        icon: 'check',
        onPressed: !ready || _saving || !m.canRecord
            ? null
            : () async {
                final summary = await _ask(
                    outcome == 'pass' ? 'Complete as Pass?' : 'Complete as Fail?', 'Summary (optional)',
                    required: false, action: 'Complete');
                if (summary != null) await _run(() => m.complete(widget.id, outcome, summary));
              },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t['id'] as String),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'note') {
                final text = await _ask('Note on this inspection', 'What should the office know?');
                if (text != null) await _run(() => m.note(widget.id, text));
              } else if (v == 'photo') {
                await _photo();
              } else if (v == 'void') {
                final why = await _ask('Void this inspection?', 'Why (kept with the record)', action: 'Void');
                if (why != null) await _run(() => m.voidInspection(widget.id, why));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'note', enabled: m.canRecord && status != 'voided', child: const Text('Add a note')),
              PopupMenuItem(value: 'photo', enabled: !locked, child: const Text('Add a photo')),
              PopupMenuItem(value: 'void', enabled: !locked, child: const Text('Void inspection')),
            ],
          ),
        ],
      ),
      body: PageList(bottom: bottom, children: [
        StatusBlock(
          icon: 'inspect',
          kind: 'Inspection',
          title: (s['title'] as String).isEmpty ? t['title'] as String : s['title'] as String,
          subtitle: '${t['id']}${(t['revision'] as String).isEmpty ? '' : ' rev ${t['revision']}'} · ${t['title']}',
          chips: [
            StatusChip(statusName(status), tone: statusTone(status)),
            if (status != 'voided') StatusChip(outcomeName(outcome), tone: outcomeTone(outcome)),
            if ((subject['label'] as String).isNotEmpty) StatusChip(subject['label'] as String, icon: 'asset'),
          ],
        ),
        if ((subject['kind'] as String) == 'asset' && m.catalog.assets.containsKey(subject['id'])) ...[
          const SizedBox(height: 8),
          SecondaryAction('Open ${subject['label']}',
              icon: 'asset', onPressed: () => openEntity(context, ResultKind.asset, subject['id']! as String)),
        ],
        if (conflicts > 0) ...[
          const SizedBox(height: 10),
          NoticeBanner(
              '$conflicts item${conflicts == 1 ? ' was' : 's were'} answered on two devices without either seeing the '
              'other. Both answers are kept; choose the right one.',
              tone: Tone.warn),
        ],
        if (completion != null && completion['stale'] == true) ...[
          const SizedBox(height: 10),
          const NoticeBanner(
              'Answers or photos were recorded on another device that this completion didn’t see. Reopen it, check '
              'them, and complete it again.',
              tone: Tone.warn),
        ],
        if (status == 'conflict') ...[
          const SizedBox(height: 10),
          const NoticeBanner(
              'Two devices changed this inspection’s status without seeing each other (for example one completed '
              'it while another voided it). Reopen it to settle it.',
              tone: Tone.warn),
        ],
        for (final p in problems) ...[const SizedBox(height: 10), NoticeBanner(p, tone: Tone.info)],
        for (final sec in (template['sections']! as List).cast<Map<String, Object?>>()) ...[
          SectionHeader(sec['title']! as String),
          for (final it in (sec['items']! as List).cast<Map<String, Object?>>())
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ItemCard(
                item: it,
                state: items[it['id']]!,
                photos: [for (final a in atts) if (a['item'] == it['id']) a],
                notes: [for (final n in notes) if (n['item'] == it['id']) n],
                locked: locked || _saving,
                onAnswer: (v, {String note = ''}) =>
                    _run(() => m.answer(widget.id, it['id']! as String, v, note: note)),
                onPhoto: () => _photo(item: it['id']! as String),
                onNote: () async {
                  final text = await _ask('Note on ${it['id']}', 'What did you find?');
                  if (text != null) await _run(() => m.note(widget.id, text, item: it['id']! as String));
                },
              ),
            ),
        ],
        if (atts.any((a) => a['item'] == '')) ...[
          const SectionHeader('Photos'),
          _PhotoStrip(photos: [for (final a in atts) if (a['item'] == '') a]),
        ],
        if (notes.any((n) => n['item'] == '')) ...[
          const SectionHeader('Notes'),
          RowsCard(children: [
            for (final n in notes)
              if (n['item'] == '')
                EntityRow(
                    icon: 'note',
                    title: n['text']! as String,
                    subtitle: '${n['actor'] == '' ? 'unknown' : n['actor']} · ${shortTime(n['time']! as String)}'),
          ]),
        ],
        const SectionHeader('Record'),
        RowsCard(children: [
          KeyValueRow('Started', '${shortTime((s['started']! as Map)['time'] as String)} UTC by '
              '${((s['started']! as Map)['actor'] as String).isEmpty ? 'unknown' : (s['started']! as Map)['actor']}'),
          KeyValueRow('Template', '${t['id']} rev ${t['revision']} · digest ${(t['digest'] as String).substring(0, 16)}'),
          KeyValueRow('Record id', widget.id),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text('Names are as entered on each device. Times are the devices’ own clocks.',
              style: TextStyle(color: fx.muted, fontSize: 12.5)),
        ),
      ]),
    );
  }
}

typedef _Answer = Future<void> Function(Map<String, Object?> value, {String note});

class _ItemCard extends StatefulWidget {
  const _ItemCard({
    required this.item,
    required this.state,
    required this.photos,
    required this.notes,
    required this.locked,
    required this.onAnswer,
    required this.onPhoto,
    required this.onNote,
  });
  final Map<String, Object?> item, state;
  final List<Map<String, Object?>> photos, notes;
  final bool locked;
  final _Answer onAnswer;
  final VoidCallback onPhoto, onNote;

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  late final TextEditingController _text = TextEditingController(text: _current());
  final _focus = FocusNode();
  String? _inputError;

  List<Map<String, Object?>> get _values => (widget.state['values']! as List).cast<Map<String, Object?>>();

  String _current() {
    if (_values.length != 1) return '';
    final v = _values.single['value']! as Map;
    return (v['measured'] ?? v['text'] ?? '') as String;
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commitText();
    });
  }

  @override
  void didUpdateWidget(_ItemCard old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _text.text != _current()) _text.text = _current();
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _commitText() async {
    final kind = widget.item['kind'];
    final raw = _text.text.trim();
    if (raw == _current() || widget.locked) return;
    if (kind == 'measure') {
      if (raw.isEmpty) {
        await widget.onAnswer({});
        return;
      }
      final d = normalizeDecimalInput(raw);
      if (d == null) {
        setState(() => _inputError = 'Enter a number like 12.5 or -0.05');
        return;
      }
      setState(() => _inputError = null);
      _text.text = d;
      await widget.onAnswer({'measured': d});
    } else if (kind == 'text') {
      await widget.onAnswer(raw.isEmpty ? {} : {'text': raw});
    }
  }

  String _limits() {
    final it = widget.item;
    if (it['kind'] != 'measure') return '';
    final lo = it['min']! as String, hi = it['max']! as String, u = it['unit']! as String, nom = it['nominal']! as String;
    final range = lo.isNotEmpty && hi.isNotEmpty
        ? '$lo to $hi $u'
        : lo.isNotEmpty
            ? 'at least $lo $u'
            : hi.isNotEmpty
                ? 'at most $hi $u'
                : 'record the value';
    return nom.isEmpty ? range.trim() : '${range.trim()} (nominal $nom $u)'.replaceAll('  ', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    final it = widget.item;
    final kind = it['kind']! as String;
    final outcome = widget.state['outcome']! as String;
    final values = _values;
    final conflict = values.length > 1;
    final single = values.length == 1 ? values.single['value']! as Map : const {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['id']}  ', style: TextStyle(color: fx.muted, fontWeight: FontWeight.w700, fontSize: 15)),
            Expanded(
              child: Text('${it['prompt']}${it['required'] == true ? '' : ' (optional)'}',
                  style: TextStyle(color: fx.text, fontSize: 16, fontWeight: FontWeight.w600, height: 1.3)),
            ),
            if (outcome != 'open') ...[const SizedBox(width: 8), StatusChip(outcomeName(outcome), tone: outcomeTone(outcome))],
          ]),
          if (_limits().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_limits(), style: TextStyle(color: fx.muted, fontSize: 14)),
            ),
          if ((it['help'] as String).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(it['help']! as String, style: TextStyle(color: fx.muted, fontSize: 13.5, fontStyle: FontStyle.italic)),
            ),
          const SizedBox(height: 10),
          if (conflict)
            _ConflictChooser(item: it, values: values, locked: widget.locked, onChoose: (v) => widget.onAnswer(v))
          else if (kind == 'check')
            _Choices(
              options: const [('pass', 'Pass', Tone.ok), ('fail', 'Fail', Tone.danger), ('na', 'N/A', Tone.neutral)],
              selected: single['result'] as String?,
              locked: widget.locked,
              onSelect: (v) => widget.onAnswer(v == single['result'] ? {} : {'result': v}),
            )
          else if (kind == 'choice')
            _Choices(
              options: [for (final c in (it['choices']! as List).cast<String>()) (c, c, Tone.accent)],
              selected: single['choice'] as String?,
              locked: widget.locked,
              onSelect: (v) => widget.onAnswer(v == single['choice'] ? {} : {'choice': v}),
            )
          else if (kind == 'measure')
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  enabled: !widget.locked && single['result'] != 'na',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: single['result'] == 'na' ? 'N/A' : 'Measured',
                    suffixText: it['unit'] as String,
                    errorText: _inputError,
                  ),
                  onSubmitted: (_) => _commitText(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: widget.locked ? null : () => widget.onAnswer(single['result'] == 'na' ? {} : {'result': 'na'}),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: single['result'] == 'na' ? fx.selectBg : null,
                    foregroundColor: single['result'] == 'na' ? fx.selectFg : fx.text,
                  ),
                  child: const Text('N/A'),
                ),
              ),
            ])
          else
            TextField(
              controller: _text,
              focusNode: _focus,
              enabled: !widget.locked,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(hintText: 'Type here'),
            ),
          if (values.length == 1)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                [
                  values.single['actor'] == '' ? 'unknown' : values.single['actor'] as String,
                  shortTime(values.single['time']! as String),
                  if ((values.single['note'] as String).isNotEmpty) '“${values.single['note']}”',
                ].join(' · '),
                style: TextStyle(color: fx.muted, fontSize: 12.5),
              ),
            ),
          for (final n in widget.notes)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Note: ${n['text']} (${n['actor'] == '' ? 'unknown' : n['actor']})',
                  style: TextStyle(color: fx.text, fontSize: 14)),
            ),
          if (widget.photos.isNotEmpty) ...[const SizedBox(height: 8), _PhotoStrip(photos: widget.photos)],
          if (it['photo'] == 'required' && widget.photos.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('A photo is required.', style: TextStyle(color: fx.tone(Tone.warn), fontWeight: FontWeight.w600)),
            ),
          if (!widget.locked)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 4, children: [
                if (it['photo'] != 'none')
                  TextButton.icon(onPressed: widget.onPhoto, icon: const FxIcon('camera', size: 20), label: const Text('Photo')),
                TextButton.icon(onPressed: widget.onNote, icon: const FxIcon('note', size: 20), label: const Text('Note')),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _Choices extends StatelessWidget {
  const _Choices({required this.options, required this.selected, required this.locked, required this.onSelect});
  final List<(String, String, Tone)> options;
  final String? selected;
  final bool locked;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (value, label, tone) in options)
        SizedBox(
          height: 52,
          child: OutlinedButton(
            onPressed: locked ? null : () => onSelect(value),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(88, 52),
              backgroundColor: selected == value ? fx.toneBg(tone) : null,
              foregroundColor: selected == value ? fx.toneFg(tone) : fx.text,
              side: BorderSide(color: selected == value ? fx.tone(tone) : fx.borderStrong, width: selected == value ? 2 : 1),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            child: Semantics(selected: selected == value, child: Text(label)),
          ),
        ),
    ]);
  }
}

class _ConflictChooser extends StatelessWidget {
  const _ConflictChooser({required this.item, required this.values, required this.locked, required this.onChoose});
  final Map<String, Object?> item;
  final List<Map<String, Object?>> values;
  final bool locked;
  final ValueChanged<Map<String, Object?>> onChoose;

  String _show(Map<Object?, Object?> v) {
    if (v.isEmpty) return '(cleared)';
    if (v.containsKey('result')) return outcomeName(v['result']! as String);
    if (v.containsKey('measured')) return '${v['measured']} ${item['unit'] ?? ''}'.trim();
    return (v['text'] ?? v['choice'] ?? '$v') as String;
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return Container(
      decoration: BoxDecoration(color: fx.toneBg(Tone.warn), borderRadius: BorderRadius.circular(10)),
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Two answers, recorded without seeing each other:',
            style: TextStyle(color: fx.toneFg(Tone.warn), fontWeight: FontWeight.w600)),
        for (final v in values)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Expanded(
                child: Text(
                  '${_show(v['value']! as Map)} · ${v['actor'] == '' ? 'unknown' : v['actor']} · ${shortTime(v['time']! as String)}',
                  style: TextStyle(color: fx.toneFg(Tone.warn), fontSize: 15),
                ),
              ),
              TextButton(
                onPressed: locked ? null : () => onChoose(Map<String, Object?>.from(v['value']! as Map)),
                child: const Text('Use this'),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.photos});
  final List<Map<String, Object?>> photos;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = m.objectFile(photos[i]['object']! as String);
          final exists = f.existsSync();
          return GestureDetector(
            onTap: exists
                ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                          appBar: AppBar(title: Text((photos[i]['caption'] as String?)?.isNotEmpty == true ? photos[i]['caption']! as String : 'Photo')),
                          body: InteractiveViewer(maxScale: 8, child: Center(child: Image.file(f))),
                        )))
                : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 92,
                height: 92,
                color: fx.surface2,
                alignment: Alignment.center,
                child: exists
                    ? Image.file(f, width: 92, height: 92, fit: BoxFit.cover, cacheWidth: 276)
                    : Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text('Photo not on this phone', textAlign: TextAlign.center, style: TextStyle(color: fx.muted, fontSize: 11)),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}
