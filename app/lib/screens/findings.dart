// SPDX-License-Identifier: GPL-3.0-or-later
// Findings (docs/PROTOCOL.md section 11): what someone found or changed on a unit. The phone records a finding as a
// proposal; someone in the office accepts it into RevisionWorx's unit register, or doesn't. Nothing here changes the
// unit's record.

import 'dart:io';

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../model/app_model.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import 'inspect.dart' show ChoiceButtons, PhotoStrip;

/// What a finding can be, in the order the phone offers them.
const List<(String, String)> findingChoices = [
  ('replaced', 'Replaced a part'),
  ('found', 'What is fitted'),
  ('change', 'Carried out a change'),
  ('note', 'Something else'),
];

/// Where a part that came out went (RevisionWorx's dispositions).
const List<(String, String)> dispositionChoices = [
  ('repair', 'For repair'),
  ('returned', 'Returned'),
  ('scrapped', 'Scrapped'),
  ('stock', 'To stock'),
  ('reused', 'Reused'),
  ('unknown', 'Not known'),
];

String _partWords(Object? p) {
  if (p is! Map) return '';
  final number = (p['number'] as String?) ?? '';
  final serial = (p['serial'] as String?) ?? '';
  final lot = (p['lot'] as String?) ?? '';
  return [
    if (number.isNotEmpty) number,
    if (serial.isNotEmpty) 'S/N $serial',
    if (lot.isNotEmpty) 'lot $lot',
  ].join(' ');
}

/// One line saying what a finding is.
String findingSummary(Map<String, Object?> s) {
  if (s['valid'] != true) return 'Can’t be read: ${((s['problems'] as List?) ?? const <Object?>[]).join('; ')}';
  final position = s['position']! as String;
  switch (s['what']) {
    case 'replaced':
      final out = _partWords(s['removed']);
      return 'Replaced at $position: ${out.isEmpty ? 'what was there' : out} out, ${_partWords(s['fitted'])} in';
    case 'found':
      return 'At $position: ${_partWords(s['fitted'])}';
    case 'change':
      return 'Carried out ${s['change']}';
    default:
      return (s['text']! as String).split('\n').first;
  }
}

/// A unit's findings, from this phone and any its packages brought, and the way to report one.
class FindingsSection extends StatelessWidget {
  const FindingsSection({super.key, required this.asset});
  final Asset asset;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    final list = m.findingsFor(asset.id, also: asset.aliases);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('Findings (${list.length})'),
      if (list.isNotEmpty) RowsCard(children: [for (final s in list) FindingRow(state: s)]),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(
            'A part replaced, what is fitted, a change carried out: the office decides what goes into RevisionWorx.',
            style: TextStyle(color: fx.muted, fontSize: 13)),
      ),
      if (m.canRecord)
        SecondaryAction('Report a finding',
            icon: 'note',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ReportFindingScreen(assetId: asset.id)))),
    ]);
  }
}

class FindingRow extends StatelessWidget {
  const FindingRow({super.key, required this.state});
  final Map<String, Object?> state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final who = (s['recorded'] as Map?) ?? const <Object?, Object?>{};
    final photos = ((s['attachments'] as List?) ?? const <Object?>[]).length;
    return EntityRow(
      icon: 'note',
      title: findingSummary(s),
      subtitle: [
        if ((s['on'] as String?)?.isNotEmpty == true) s['on']! as String else shortDate((who['time'] as String?) ?? ''),
        if ((who['actor'] as String?)?.isNotEmpty == true) who['actor']! as String,
      ].join(' · '),
      chips: [
        if (s['status'] == 'voided') const StatusChip('voided', tone: Tone.warn) else const StatusChip('reported'),
        if (photos > 0) StatusChip(photos == 1 ? '1 photo' : '$photos photos'),
      ],
      onTap: s['valid'] == true
          ? () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => FindingScreen(id: s['entity']! as String)))
          : null,
    );
  }
}

// ------------------------------------------------------------------------------------------------ reporting one
class ReportFindingScreen extends StatefulWidget {
  const ReportFindingScreen({super.key, required this.assetId});
  final String assetId;

  @override
  State<ReportFindingScreen> createState() => _ReportFindingScreenState();
}

class _ReportFindingScreenState extends State<ReportFindingScreen> {
  String _what = '';
  String _disposition = 'repair';
  String? _filledFrom;          // the position whose register entry filled "taken out", while it still holds it
  bool _saving = false;
  String? _problem;
  final List<File> _photos = [];
  final _position = TextEditingController();
  final _outNumber = TextEditingController(), _outSerial = TextEditingController(), _outLot = TextEditingController();
  final _inNumber = TextEditingController(), _inSerial = TextEditingController(), _inLot = TextEditingController();
  final _change = TextEditingController();
  final _on = TextEditingController(text: utcNow().substring(0, 10));
  final _text = TextEditingController();

  @override
  void dispose() {
    for (final c in [_position, _outNumber, _outSerial, _outLot, _inNumber, _inSerial, _inLot, _change, _on, _text]) {
      c.dispose();
    }
    super.dispose();
  }

  /// What the register says is at the position typed, so "taken out" starts as that; cleared again if the position
  /// changes to one the register has nothing at. What the person typed themselves is left alone.
  void _fillFromRegister(Asset a) {
    final p = _position.text.trim().toLowerCase();
    for (final c in a.components) {
      if (c.position.toLowerCase() == p) {
        _outNumber.text = c.number;
        _outSerial.text = c.serial;
        _outLot.text = c.lot;
        _filledFrom = c.position;
        return;
      }
    }
    if (_filledFrom != null) {
      _outNumber.clear();
      _outSerial.clear();
      _outLot.clear();
      _filledFrom = null;
    }
  }

  Map<String, String> _part(TextEditingController n, TextEditingController s, TextEditingController l) =>
      {'number': n.text.trim(), 'serial': s.text.trim(), 'lot': l.text.trim()};

  Map<String, Object?> _body(Asset a, String package) {
    final part = _what == 'replaced' || _what == 'found';
    return {
      'asset': a.id,
      'what': _what,
      'position': part ? _position.text.trim() : '',
      'removed': _what == 'replaced' ? _part(_outNumber, _outSerial, _outLot) : null,
      'fitted': part ? _part(_inNumber, _inSerial, _inLot) : null,
      'disposition': _what == 'replaced' ? _disposition : '',
      'change': _what == 'change' ? _change.text.trim() : '',
      'on': _on.text.trim(),
      'text': _text.text.trim(),
      'package': package,
    };
  }

  Future<void> _photo() async {
    final m = AppScope.read(context);
    final File? f;
    try {
      f = await m.services.takePhoto();
    } on Exception catch (e) {
      if (mounted) showMessage(context, 'The camera could not be opened: $e', error: true);
      return;
    }
    if (f != null && mounted) setState(() => _photos.add(f!));
  }

  Future<void> _record(Asset a, String package) async {
    if (_saving) return;
    final body = _body(a, package);
    try {
      checkFindingRecord(body);
    } on FindingError catch (e) {
      setState(() => _problem = _say(e.message));
      return;
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    final m = AppScope.read(context);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final id = await m.recordFinding(body);
      for (final p in _photos) {
        await m.attachFindingPhoto(id, p);
      }
      HapticFeedback.selectionClick();
      showMessageOn(messenger, 'Recorded. Send a field log so the office sees it.');
      nav.pop();
    } on Exception catch (e) {
      if (mounted) showMessage(context, explain(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The checker's words, as a person filling the form needs them.
  String _say(String problem) => switch (problem) {
        'position is empty' => 'Say where on the unit (the position, like P1).',
        'say what is fitted: a part number or a serial' => 'Say what is fitted now: its part number or serial.',
        'change is empty' => 'Choose the change, or type its number.',
        'text is empty' => 'Say what you found.',
        'on is a date like 2026-11-03, or empty' => 'The date is year-month-day, like 2026-11-03.',
        _ => 'This can’t be recorded: $problem.',
      };

  Widget _field(TextEditingController c, String label,
          {TextInputType? keyboard,
          TextCapitalization caps = TextCapitalization.characters,
          ValueChanged<String>? onChanged}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          keyboardType: keyboard,
          textCapitalization: caps,
          onChanged: onChanged,
          decoration: InputDecoration(labelText: label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    final a = m.catalog.asset(widget.assetId);
    if (a == null) {
      return Scaffold(
          appBar: AppBar(), body: const EmptyState(icon: 'warning', title: 'This unit is not on this phone'));
    }
    final package = a.package.id;
    final changes = a.outstandingChanges;
    return Scaffold(
      appBar: AppBar(title: Text('Report on ${a.label}')),
      body: PageList(
        bottom: _what.isEmpty
            ? null
            : PrimaryAction(_saving ? 'Recording…' : 'Record finding',
                icon: 'check', onPressed: _saving ? null : () => _record(a, package)),
        children: [
          Text('What happened?', style: TextStyle(color: fx.text, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ChoiceButtons(
            options: [for (final (v, label) in findingChoices) (v, label, Tone.accent)],
            selected: _what.isEmpty ? null : _what,
            locked: _saving,
            onSelect: (v) => setState(() {
              _what = v;
              _problem = null;
            }),
          ),
          const SizedBox(height: 16),
          if (_what == 'replaced' || _what == 'found') ...[
            _field(_position, 'Position on the unit (like P1)', onChanged: (_) {
              if (_what == 'replaced') setState(() => _fillFromRegister(a));
            }),
            if (_what == 'replaced') ...[
              SectionHeader('Taken out'),
              _field(_outNumber, 'Part number'),
              _field(_outSerial, 'Serial'),
              _field(_outLot, 'Lot'),
              Text('Where it went', style: TextStyle(color: fx.muted, fontSize: 13)),
              const SizedBox(height: 6),
              ChoiceButtons(
                options: [for (final (v, label) in dispositionChoices) (v, label, Tone.neutral)],
                selected: _disposition,
                locked: _saving,
                onSelect: (v) => setState(() => _disposition = v),
              ),
              const SizedBox(height: 8),
            ],
            SectionHeader(_what == 'replaced' ? 'Fitted in its place' : 'Fitted there now'),
            _field(_inNumber, 'Part number'),
            _field(_inSerial, 'Serial'),
            _field(_inLot, 'Lot'),
          ],
          if (_what == 'change') ...[
            if (changes.isNotEmpty) ...[
              Text('Changes due on this unit', style: TextStyle(color: fx.muted, fontSize: 13)),
              const SizedBox(height: 6),
              ChoiceButtons(
                options: [for (final c in changes) (c.number, c.number, Tone.accent)],
                selected: _change.text.trim().isEmpty ? null : _change.text.trim(),
                locked: _saving,
                onSelect: (v) => setState(() => _change.text = v),
              ),
              const SizedBox(height: 10),
            ],
            _field(_change, 'Change order number (like ECO-0042)', onChanged: (_) => setState(() {})),
          ],
          if (_what.isNotEmpty) ...[
            _field(_on, 'Date done (year-month-day)', keyboard: TextInputType.datetime, caps: TextCapitalization.none),
            TextField(
              controller: _text,
              minLines: _what == 'note' ? 3 : 1,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: _what == 'note' ? 'What you found' : 'Comment (optional)'),
            ),
            const SizedBox(height: 12),
            if (_photos.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('${_photos.length} photo${_photos.length == 1 ? '' : 's'} to add',
                    style: TextStyle(color: fx.muted, fontSize: 13)),
              ),
            SecondaryAction('Take a photo', icon: 'camera', onPressed: _saving ? null : _photo),
            if (_problem != null) ...[const SizedBox(height: 12), NoticeBanner(_problem!, tone: Tone.danger)],
            const SizedBox(height: 12),
            Text('The office decides what goes into RevisionWorx. The unit’s record doesn’t change on the phone.',
                style: TextStyle(color: fx.muted, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------------------------- one finding
class FindingScreen extends StatelessWidget {
  const FindingScreen({super.key, required this.id});
  final String id;

  Future<void> _void(BuildContext context) async {
    final m = AppScope.read(context);
    final reason = await askText(context,
        title: 'Void this finding?', hint: 'Why (it was the wrong unit, say)', action: 'Void');
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await m.voidFinding(id, reason.trim());
    } on Exception catch (e) {
      if (context.mounted) showMessage(context, explain(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    final s = m.finding(id);
    if (s['valid'] != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Finding')),
        body: PageList(children: [NoticeBanner(findingSummary(s), tone: Tone.danger)]),
      );
    }
    final a = m.catalog.asset(s['asset']! as String);
    final who = s['recorded']! as Map;
    final voids = (s['voids']! as List).cast<Map<String, Object?>>();
    final photos = (s['attachments']! as List).cast<Map<String, Object?>>();
    final text = s['text']! as String;
    return Scaffold(
      appBar: AppBar(title: const Text('Finding')),
      body: PageList(
        bottom: voids.isEmpty && m.canRecord
            ? SecondaryAction('Void…', icon: 'close', onPressed: () => _void(context))
            : null,
        children: [
          StatusBlock(
            icon: 'note',
            kind: 'Finding',
            title: findingSummary(s),
            subtitle: a?.label ?? (s['asset']! as String),
            chips: [
              if (voids.isNotEmpty) const StatusChip('voided', tone: Tone.warn) else const StatusChip('reported'),
            ],
          ),
          if (voids.isNotEmpty) ...[
            const SizedBox(height: 10),
            NoticeBanner('Voided: ${voids.last['reason']} (${voids.last['actor']})', tone: Tone.warn),
          ],
          const SizedBox(height: 10),
          RowsCard(children: [
            if (s['what'] == 'replaced') KeyValueRow('Taken out', _partWords(s['removed'])),
            if (s['what'] == 'replaced') KeyValueRow('Where it went', s['disposition']! as String),
            if (s['what'] == 'replaced' || s['what'] == 'found') KeyValueRow('Fitted', _partWords(s['fitted'])),
            if (s['what'] == 'change') KeyValueRow('Change', s['change']! as String),
            if ((s['on'] as String).isNotEmpty) KeyValueRow('Done', s['on']! as String),
            if (text.isNotEmpty) KeyValueRow(s['what'] == 'note' ? 'Found' : 'Comment', text),
            KeyValueRow('Reported by', '${who['actor']} · ${shortTime(who['time']! as String)}'),
          ]),
          if (photos.isNotEmpty) ...[const SizedBox(height: 10), PhotoStrip(photos: photos)],
          const SizedBox(height: 10),
          Text(
              'The office decides what goes into RevisionWorx; the next package shows the unit as it is recorded '
              'there.',
              style: TextStyle(color: fx.muted, fontSize: 13)),
        ],
      ),
    );
  }
}
