// SPDX-License-Identifier: GPL-3.0-or-later
// Findings: what someone found or changed on a unit in the field (docs/PROTOCOL.md section 11). A finding is a
// proposal, never a change: someone in the office accepts it into RevisionWorx's unit register, or doesn't.
// A line-by-line port of bridge/fieldworx_bridge/findings.py: spec/vectors/findings.json requires the same state, byte
// for byte, from the same events in any arrival order, and the same verdict on every record body.

import 'events.dart';

const List<String> findingWhat = ['replaced', 'found', 'change', 'note'];
const List<String> findingDispositions = ['scrapped', 'returned', 'repair', 'stock', 'reused', 'unknown'];
const List<String> recordKeys = [
  'asset', 'what', 'position', 'removed', 'fitted', 'disposition', 'change', 'on', 'text', 'package', //
];
const List<String> findingTypes = ['finding.record', 'finding.attach', 'finding.void'];
final RegExp _reAsset = RegExp(r'^(unt|ast)_[0-9a-f]{32}$');
final RegExp _reDate = RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$');

class FindingError implements Exception {
  FindingError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Nothing but spaces, tabs and newlines (the Python reference defines it the same way, not by trimming).
bool textIsBlank(String v) => v.codeUnits.every((c) => c == 0x20 || c == 0x09 || c == 0x0A);

String _text(Object? v, String what, int limit, {bool required = false, bool multiline = false}) {
  if (v is! String) throw FindingError('$what must be text');
  if (cpLen(v) > limit) throw FindingError('$what is longer than $limit characters');
  for (final c in v.codeUnits) {
    final allowed = multiline && (c == 0x0A || c == 0x09);
    if ((c < 0x20 && !allowed) || c == 0x7F) throw FindingError('$what contains control characters');
  }
  if (required && textIsBlank(v)) throw FindingError('$what is empty');
  return v;
}

bool _keysAre(Map<Object?, Object?> m, Iterable<String> want) {
  final w = want.toSet();
  return m.length == w.length && m.keys.every((k) => k is String && w.contains(k));
}

Map<Object?, Object?>? _part(Object? v, String what, {required bool required}) {
  if (v == null && !required) return null;
  if (v is! Map || !_keysAre(v, const ['number', 'serial', 'lot'])) {
    throw FindingError('$what must be {number, serial, lot}');
  }
  for (final k in const ['number', 'serial', 'lot']) {
    _text(v[k], '$what $k', 100);
  }
  return v;
}

/// Returns [b] if it is a valid `finding.record` body, else throws [FindingError] naming the problem.
Map<String, Object?> checkFindingRecord(Object? b) {
  if (b is! Map || !_keysAre(b, recordKeys)) throw FindingError('finding fields wrong');
  final asset = b['asset'];
  if (asset is! String || !_reAsset.hasMatch(asset)) {
    throw FindingError('a finding is about a unit or asset: unt_ or ast_ and 32 hex digits');
  }
  final what = b['what'];
  if (what is! String || !findingWhat.contains(what)) throw FindingError('what is one of ${findingWhat.join(', ')}');
  final partFinding = what == 'replaced' || what == 'found';
  _text(b['position'], 'position', 64, required: partFinding);
  if (!partFinding && b['position'] != '') throw FindingError('only a replacement or a find has a position');
  final removed = _part(b['removed'], 'removed', required: what == 'replaced');
  if (what != 'replaced' && removed != null) throw FindingError('only a replacement has something removed');
  final fitted = _part(b['fitted'], 'fitted', required: partFinding);
  if (!partFinding && fitted != null) throw FindingError('only a replacement or a find has something fitted');
  if (fitted != null && textIsBlank(fitted['number']! as String) && textIsBlank(fitted['serial']! as String)) {
    throw FindingError('say what is fitted: a part number or a serial');
  }
  if (what == 'replaced') {
    if (!findingDispositions.contains(b['disposition'])) {
      throw FindingError('disposition is one of ${findingDispositions.join(', ')}');
    }
  } else if (b['disposition'] != '') {
    throw FindingError('only a replacement has a disposition');
  }
  _text(b['change'], 'change', 64, required: what == 'change');
  if (what != 'change' && b['change'] != '') throw FindingError('only a change has a change number');
  final on = b['on'];
  if (on is! String || (on.isNotEmpty && !_reDate.hasMatch(on))) {
    throw FindingError('on is a date like 2026-11-03, or empty');
  }
  _text(b['text'], 'text', 4000, required: what == 'note', multiline: true);
  _text(b['package'], 'package', 64);
  return b.cast<String, Object?>();
}

Map<String, Object?> _who(Event e) => {'event': e.id, 'actor': e.actor, 'device': e.device, 'time': e.time};

int _byTimeThenEvent(Map<String, Object?> a, Map<String, Object?> b) {
  final c = (a['time']! as String).compareTo(b['time']! as String);
  return c != 0 ? c : (a['event']! as String).compareTo(b['event']! as String);
}

/// The state of finding [entity] from its events (a JSON-able map; see docs/PROTOCOL.md section 11).
Map<String, Object?> reduceFinding(FieldLog log, String entity) {
  final evs = log.entityEvents(entity)..sort((a, b) => a.id.compareTo(b.id));
  final records = [for (final e in evs) if (e.type == 'finding.record') e];
  if (records.length != 1) {
    return {
      'entity': entity,
      'valid': false,
      'problems': [records.isEmpty ? 'no finding record' : 'more than one finding record'],
    };
  }
  final rec = records.single;
  final Map<String, Object?> body;
  try {
    body = checkFindingRecord(rec.body);
  } on FindingError catch (e) {
    return {
      'entity': entity,
      'valid': false,
      'problems': ['finding record unusable: ${e.message}'],
    };
  }
  final problems = <String>[];
  final attachments = <Map<String, Object?>>[];
  final voids = <Map<String, Object?>>[];
  for (final e in evs) {
    final t = e.type, b = e.body;
    final short = e.id.substring(0, 12);
    if (t == 'finding.record') continue;
    if (!findingTypes.contains(t)) {
      problems.add("record $short is of a kind this version doesn't know ($t); update FieldWorx");
      continue;
    }
    if (t == 'finding.attach') {
      final object = b['object'], size = b['size'], media = b['media_type'], caption = b['caption'];
      final ok = _keysAre(b, const ['object', 'size', 'media_type', 'caption']) &&
          object is String &&
          reHash.hasMatch(object) &&
          size is int &&
          size >= 0 &&
          media is String &&
          cpLen(media) <= 100 &&
          caption is String &&
          cpLen(caption) <= 500;
      if (!ok) {
        problems.add('photo record $short is malformed and was ignored');
        continue;
      }
      attachments.add({'object': object, 'size': size, 'media_type': media, 'caption': caption, ..._who(e)});
    } else {
      final reason = b['reason'];
      final ok = _keysAre(b, const ['reason']) && reason is String && !textIsBlank(reason) && cpLen(reason) <= 2000;
      if (!ok) {
        problems.add('void record $short is malformed and was ignored');
        continue;
      }
      voids.add({'reason': reason, ..._who(e)});
    }
  }
  attachments.sort(_byTimeThenEvent);
  voids.sort(_byTimeThenEvent);
  final keys = [...recordKeys]..sort();
  return {
    'entity': entity,
    'valid': true,
    for (final k in keys) k: body[k],
    'recorded': _who(rec),
    'status': voids.isEmpty ? 'recorded' : 'voided',
    'voids': voids,
    'attachments': attachments,
    'problems': problems,
    'heads': log.entityHeads(entity),
  };
}

/// The findings this log holds, by entity id.
List<String> findingEntities(FieldLog log) {
  final out = [
    for (final e in log.byEntity.entries)
      if (e.key.startsWith('fnd_') && e.value.any((i) => log.events[i]!.type == 'finding.record')) e.key,
  ]..sort();
  return out;
}
