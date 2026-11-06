// SPDX-License-Identifier: GPL-3.0-or-later
// Inspection templates and the state of an inspection worked out from its events (docs/PROTOCOL.md section 5).
// A line-by-line port of bridge/fieldworx_bridge/inspections.py: spec/vectors/inspections.json requires the same
// state, byte for byte, from the same events in any arrival order.

import 'decimal.dart';
import 'events.dart';
import 'fxjson.dart' as fx;

const String templateFormat = 'fieldworx.template';
const List<String> itemKinds = ['check', 'measure', 'text', 'choice'];
const List<String> photoRules = ['none', 'optional', 'required'];
final RegExp reItemId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._\-]{0,31}$');
const List<String> checkResults = ['pass', 'fail', 'na'];
const List<String> statusTypes = ['inspection.complete', 'inspection.reopen', 'inspection.void'];
const List<String> knownTypes = [
  'inspection.start', 'inspection.answer', 'inspection.note', 'inspection.attach', ...statusTypes, //
];

class TemplateError implements Exception {
  TemplateError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _text(Object? v, String what, int limit, {bool required = false, bool multiline = false}) {
  if (v is! String) throw TemplateError('$what must be text');
  if (cpLen(v) > limit) throw TemplateError('$what is longer than $limit characters');
  for (final c in v.codeUnits) {
    final allowed = multiline && (c == 0x0A || c == 0x09);
    if ((c < 0x20 && !allowed) || c == 0x7F) throw TemplateError('$what contains control characters');
  }
  if (required && v.trim().isEmpty) throw TemplateError('$what is empty');
  return v;
}

bool _keysAre(Map<Object?, Object?> m, Set<String> want) =>
    m.length == want.length && m.keys.every((k) => k is String && want.contains(k));

/// Returns [t] if it is a valid version 1 template, else throws [TemplateError] naming the problem.
Map<String, Object?> checkTemplate(Object? t) {
  if (t is! Map) throw TemplateError('a template is a JSON object');
  if (!_keysAre(t, {'format', 'version', 'id', 'revision', 'title', 'description', 'sections'})) {
    throw TemplateError('template fields wrong');
  }
  if (t['format'] != templateFormat || t['version'] != 1) throw TemplateError('not a version 1 FieldWorx template');
  _text(t['id'], 'template id', 64, required: true);
  _text(t['revision'], 'template revision', 16);
  _text(t['title'], 'template title', 200, required: true);
  _text(t['description'], 'template description', 4000, multiline: true);
  final sections = t['sections'];
  if (sections is! List || sections.isEmpty) throw TemplateError('a template needs at least one section');
  final seen = <String>{};
  var count = 0;
  for (var si = 0; si < sections.length; si++) {
    final s = sections[si];
    if (s is! Map || !_keysAre(s, {'title', 'items'})) {
      throw TemplateError('section ${si + 1} must have exactly title and items');
    }
    _text(s['title'], 'section ${si + 1} title', 200);
    final its = s['items'];
    if (its is! List || its.isEmpty) throw TemplateError('section ${si + 1} has no items');
    for (final it in its) {
      _checkItem(it, seen);
      count++;
    }
  }
  if (count > 1000) throw TemplateError('a template has at most 1000 items');
  return fx.asMap(t, 'template');
}

void _checkItem(Object? it, Set<String> seen) {
  const base = {'id', 'kind', 'prompt', 'required', 'photo', 'help'};
  if (it is! Map) throw TemplateError('an item is a JSON object');
  final iid = it['id'];
  if (iid is! String) throw TemplateError('an item id must be text');
  if (!reItemId.hasMatch(iid)) {
    throw TemplateError("item id '$iid' must be 1-32 letters, digits, '.', '_' or '-'");
  }
  if (seen.contains(iid.toLowerCase())) throw TemplateError('item id $iid appears twice');
  seen.add(iid.toLowerCase());
  final kind = it['kind'];
  if (!itemKinds.contains(kind)) throw TemplateError('item $iid: kind must be one of ${itemKinds.join(', ')}');
  final extra = kind == 'measure'
      ? {'unit', 'nominal', 'min', 'max'}
      : kind == 'choice'
          ? {'choices'}
          : <String>{};
  if (!_keysAre(it, {...base, ...extra})) throw TemplateError('item $iid: fields wrong for a $kind item');
  _text(it['prompt'], 'item $iid prompt', 500, required: true);
  if (it['required'] is! bool) throw TemplateError('item $iid: required must be true or false');
  if (!photoRules.contains(it['photo'])) throw TemplateError('item $iid: photo must be none, optional or required');
  _text(it['help'], 'item $iid help', 2000, multiline: true);
  if (kind == 'measure') {
    _text(it['unit'], 'item $iid unit', 16);
    for (final k in ['nominal', 'min', 'max']) {
      if (it[k] != '' && !isDecimal(it[k])) {
        throw TemplateError('item $iid: $k must be a plain decimal like 12.5 or -0.05, or empty');
      }
    }
    final lo = it['min'] as String, hi = it['max'] as String;
    if (lo.isNotEmpty && hi.isNotEmpty && compareDecimal(lo, hi) > 0) throw TemplateError('item $iid: min is above max');
  }
  if (kind == 'choice') {
    final ch = it['choices'];
    if (ch is! List || ch.length < 2 || ch.length > 20) {
      throw TemplateError('item $iid: a choice item needs 2 to 20 choices');
    }
    for (final c in ch) {
      _text(c, 'item $iid choice', 100, required: true);
    }
    if (ch.map((c) => (c as String).toLowerCase()).toSet().length != ch.length) {
      throw TemplateError('item $iid: choices repeat');
    }
  }
}

List<Map<String, Object?>> templateItems(Map<String, Object?> t) => [
      for (final s in t['sections']! as List)
        for (final it in (s as Map)['items'] as List) fx.asMap(it, 'item'),
    ];

/// 'pass' or 'fail' for a measured decimal against the item's limits (inclusive).
String evaluateMeasure(Map<String, Object?> item, String measured) {
  final lo = item['min']! as String, hi = item['max']! as String;
  if (lo.isNotEmpty && compareDecimal(measured, lo) < 0) return 'fail';
  if (hi.isNotEmpty && compareDecimal(measured, hi) > 0) return 'fail';
  return 'pass';
}

bool validValue(Map<String, Object?> item, Object? value) {
  if (value is! Map) return false;
  if (value.isEmpty) return true;
  final kind = item['kind'];
  if (kind == 'check') return _keysAre(value, {'result'}) && checkResults.contains(value['result']);
  if (kind == 'measure') {
    if (_keysAre(value, {'result'})) return value['result'] == 'na';
    return _keysAre(value, {'measured'}) && isDecimal(value['measured']);
  }
  if (kind == 'text') {
    final t = value['text'];
    return _keysAre(value, {'text'}) && t is String && cpLen(t) <= 4000;
  }
  if (kind == 'choice') {
    return _keysAre(value, {'choice'}) && (item['choices']! as List).contains(value['choice']);
  }
  return false;
}

/// open, pass, fail, na or done (text and choice items).
String itemOutcome(Map<String, Object?> item, Map<String, Object?>? value) {
  if (value == null || value.isEmpty) return 'open';
  final kind = item['kind'];
  if (kind == 'check') return value['result']! as String;
  if (kind == 'measure') {
    if (value['result'] == 'na') return 'na';
    return evaluateMeasure(item, value['measured']! as String);
  }
  return 'done';
}

Map<String, Object?> _who(Event e) => {'event': e.id, 'actor': e.actor, 'device': e.device, 'time': e.time};

List<Event> _current(List<Event> writes, Map<String, Set<String>> anc) {
  final out = [
    for (final w in writes)
      if (!writes.any((o) => o.id != w.id && anc[o.id]!.contains(w.id))) w,
  ]..sort((a, b) => a.id.compareTo(b.id));
  return out;
}

int _byTimeThenEvent(Map<String, Object?> a, Map<String, Object?> b) {
  final c = (a['time']! as String).compareTo(b['time']! as String);
  return c != 0 ? c : (a['event']! as String).compareTo(b['event']! as String);
}

bool _strIn(Object? v, Map<String, Object?> byItem) => v is String && (v == '' || byItem.containsKey(v));

/// The state of inspection [entity] from its events (a JSON-able map; see docs/PROTOCOL.md section 5).
Map<String, Object?> reduceInspection(FieldLog log, String entity) {
  final evs = log.entityEvents(entity)..sort((a, b) => a.id.compareTo(b.id));
  final problems = <String>[];
  final starts = [for (final e in evs) if (e.type == 'inspection.start') e];
  if (starts.length != 1) {
    return {
      'entity': entity,
      'valid': false,
      'problems': [starts.isEmpty ? 'no start record' : 'more than one start record'],
    };
  }
  final start = starts.single;
  final body = start.body;
  final Map<String, Object?> template;
  final Map<String, Object?> subj;
  try {
    if (!_keysAre(body, {'template', 'title', 'subject', 'package'})) throw TemplateError('start record fields wrong');
    template = checkTemplate(body['template']);
    _text(body['title'], 'title', 200);
    _text(body['package'], 'package', 64);
    final s = body['subject'];
    if (s is! Map || !_keysAre(s, {'kind', 'id', 'label'}) ||
        !const ['', 'asset', 'part', 'document', 'project'].contains(s['kind'])) {
      throw TemplateError('subject malformed');
    }
    _text(s['id'], 'subject id', 128);
    _text(s['label'], 'subject label', 200);
    subj = fx.asMap(s, 'subject');
  } on TemplateError catch (e) {
    return {
      'entity': entity,
      'valid': false,
      'problems': ['start record unusable: ${e.message}'],
    };
  }
  final anc = ancestors(log, entity);
  final items = templateItems(template);
  final byItem = {for (final it in items) it['id']! as String: it};

  final answers = <String, List<Event>>{};
  final statusWrites = <Event>[];
  final notes = <Map<String, Object?>>[];
  final attachments = <Map<String, Object?>>[];
  final contentEvents = <Event>[];
  for (final e in evs) {
    final t = e.type, b = e.body;
    final short = e.id.substring(0, 12);
    if (t == 'inspection.start') continue;
    if (!knownTypes.contains(t)) {
      problems.add("record $short is of a kind this version doesn't know ($t); update FieldWorx");
      continue;
    }
    if (t == 'inspection.answer') {
      final item = b['item'], note = b['note'];
      final ok = _keysAre(b, {'item', 'value', 'note'}) &&
          item is String &&
          byItem.containsKey(item) &&
          validValue(byItem[item]!, b['value']) &&
          note is String &&
          cpLen(note) <= 2000;
      if (!ok) {
        problems.add('answer record $short is malformed and was ignored');
        continue;
      }
      (answers[item] ??= []).add(e);
      contentEvents.add(e);
    } else if (t == 'inspection.note') {
      final text = b['text'];
      if (!(_keysAre(b, {'text', 'item'}) &&
          text is String &&
          cpLen(text) > 0 &&
          cpLen(text) <= 4000 &&
          _strIn(b['item'], byItem))) {
        problems.add('note record $short is malformed and was ignored');
        continue;
      }
      notes.add({'text': text, 'item': b['item'], ..._who(e)});
    } else if (t == 'inspection.attach') {
      final obj = b['object'], size = b['size'], media = b['media_type'], cap = b['caption'];
      if (!(_keysAre(b, {'object', 'size', 'media_type', 'item', 'caption'}) &&
          obj is String &&
          reHash.hasMatch(obj) &&
          size is int &&
          size >= 0 &&
          media is String &&
          cpLen(media) <= 100 &&
          cap is String &&
          cpLen(cap) <= 500 &&
          _strIn(b['item'], byItem))) {
        problems.add('photo record $short is malformed and was ignored');
        continue;
      }
      attachments.add({'object': obj, 'size': size, 'media_type': media, 'item': b['item'], 'caption': cap, ..._who(e)});
      contentEvents.add(e);
    } else {
      final summary = b['summary'], reason = b['reason'];
      final ok = (t == 'inspection.complete' &&
              _keysAre(b, {'result', 'summary'}) &&
              (b['result'] == 'pass' || b['result'] == 'fail') &&
              summary is String &&
              cpLen(summary) <= 4000) ||
          ((t == 'inspection.reopen' || t == 'inspection.void') &&
              _keysAre(b, {'reason'}) &&
              reason is String &&
              cpLen(reason) <= 2000);
      if (!ok) {
        problems.add('status record $short is malformed and was ignored');
        continue;
      }
      statusWrites.add(e);
    }
  }

  final outItems = <Map<String, Object?>>[];
  final outcomes = <(Map<String, Object?>, String)>[];
  for (final it in items) {
    final id = it['id']! as String;
    final cur = _current(answers[id] ?? const [], anc);
    final values = [
      for (final c in cur) {'value': c.body['value'], 'note': c.body['note'], ..._who(c)},
    ];
    String outcome;
    if (cur.length > 1) {
      outcome = 'conflict';
    } else {
      outcome = itemOutcome(it, cur.isEmpty ? null : fx.asMap(cur.first.body['value'], 'value'));
      if (outcome != 'open' &&
          outcome != 'na' &&
          it['photo'] == 'required' &&
          !attachments.any((a) => a['item'] == id)) {
        outcome = 'photo-missing';
      }
    }
    outcomes.add((it, outcome));
    outItems.add({'id': id, 'outcome': outcome, 'values': values});
  }
  final String overall;
  if (outcomes.any((o) => o.$2 == 'conflict')) {
    overall = 'conflict';
  } else if (outcomes.any((o) => o.$2 == 'fail')) {
    overall = 'fail';
  } else if (outcomes.any((o) => o.$1['required'] == true && (o.$2 == 'open' || o.$2 == 'photo-missing'))) {
    overall = 'incomplete';
  } else {
    overall = 'pass';
  }

  final curStatus = _current(statusWrites, anc);
  Map<String, Object?>? completion;
  final String status;
  if (curStatus.isEmpty) {
    status = 'open';
  } else if (curStatus.length > 1) {
    status = 'conflict';
  } else {
    final s = curStatus.single;
    status = const {
      'inspection.complete': 'completed',
      'inspection.reopen': 'open',
      'inspection.void': 'voided',
    }[s.type]!;
    if (s.type == 'inspection.complete') {
      final covered = anc[s.id]!;
      final uncovered = [for (final e in contentEvents) if (!covered.contains(e.id)) e.id]..sort();
      completion = {
        'result': s.body['result'],
        'summary': s.body['summary'],
        ..._who(s),
        'stale': uncovered.isNotEmpty,
        'uncovered': uncovered,
      };
    }
  }
  notes.sort(_byTimeThenEvent);
  attachments.sort(_byTimeThenEvent);
  return {
    'entity': entity,
    'valid': true,
    'title': body['title'],
    'subject': subj,
    'package': body['package'],
    'template': {
      'id': template['id'],
      'revision': template['revision'],
      'title': template['title'],
      'digest': fx.digest('template/v1', template),
    },
    'started': _who(start),
    'status': status,
    'outcome': overall,
    'completion': completion,
    'items': outItems,
    'notes': notes,
    'attachments': attachments,
    'problems': problems,
    'heads': log.entityHeads(entity),
  };
}

List<String> inspectionEntities(FieldLog log) {
  final out = [
    for (final e in log.byEntity.entries)
      if (e.key.startsWith('ins_') && e.value.any((i) => log.events[i]!.type == 'inspection.start')) e.key,
  ]..sort();
  return out;
}
