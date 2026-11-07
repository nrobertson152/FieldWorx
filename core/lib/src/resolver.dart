// SPDX-License-Identifier: GPL-3.0-or-later
// What a scanned label means (docs/PROTOCOL.md section 7). FieldWorx labels say what they are:
//
//   FWX:A:unt_9f2c...  a unit, by its permanent id (or an earlier ast_ id): the label RevisionWorx's units carry
//   FWX:A:HPU-0001     an asset, by tag (or serial, or another code)
//   FWX:P:FRM-200      a part, by part number
//   FWX:D:FRM-200      a document, by document number
//   FWX:J:J-2001       a project, by project number
//
// Everything else (a manufacturer's barcode, a serial plate, a hand-typed number, an internal id) is matched
// exactly against tags, serials, part numbers, MPNs, SKUs, document and project numbers and reference
// designators. Nothing is guessed: several matches are all shown, and none means none.

import 'catalog.dart';

class ScanMatch {
  ScanMatch(this.kind, this.id, this.title, this.subtitle, this.why, this.priority);
  final ResultKind kind;
  final String id, title, subtitle, why;
  final int priority;
}

class ScanResult {
  ScanResult(this.raw, this.code, this.matches, {this.typed});
  final String raw;

  /// The text that was looked up (the label's value, without any FWX prefix).
  final String code;
  final List<ScanMatch> matches;

  /// The kind a FieldWorx label said it was, if it was one.
  final ResultKind? typed;

  bool get isUnique => matches.length == 1;
}

final RegExp _reInternal = RegExp(r'^(doc|prt|ast|unt|prj|rev)_[0-9a-f]{32}$');
final RegExp _reAssetId = RegExp(r'^(unt|ast)_[0-9a-f]{32}$');

String _clean(String raw) {
  // Hardware scanners can add CR/LF or a symbology prefix like "]Q1"; labels can carry stray spaces.
  var s = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (RegExp(r'^\][A-Za-z][0-9]').hasMatch(s)) s = s.substring(3);
  return s.trim();
}

/// Builds labels the resolver understands, for the app's "show label" screen. A unit's permanent label carries its id
/// ([Asset.labelCode]).
String labelFor(ResultKind kind, String code) {
  final t = switch (kind) {
    ResultKind.asset => 'A',
    ResultKind.part => 'P',
    ResultKind.document => 'D',
    ResultKind.project => 'J',
    ResultKind.template => 'T',
  };
  return 'FWX:$t:$code';
}

ScanResult resolve(Catalog c, String raw) {
  var code = _clean(raw);
  ResultKind? typed;
  final fwx = RegExp(r'^FWX:([A-Za-z]+):(.+)$').firstMatch(code);
  if (fwx != null) {
    typed = switch (fwx.group(1)!.toUpperCase()) {
      'A' || 'ASSET' => ResultKind.asset,
      'P' || 'PART' => ResultKind.part,
      'D' || 'DOC' || 'DOCUMENT' => ResultKind.document,
      'J' || 'PROJECT' => ResultKind.project,
      _ => null,
    };
    code = fwx.group(2)!.trim();
  } else if (RegExp(r'^https?://', caseSensitive: false).hasMatch(code)) {
    // A URL on a label: FieldWorx never opens it; the last path segment is often the part or serial number.
    final uri = Uri.tryParse(code);
    final seg = uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
    if (seg.isNotEmpty) code = Uri.decodeComponent(seg.last);
  }
  final q = norm(code);
  final out = <ScanMatch>[];
  void add(ResultKind k, String id, String title, String sub, String why, int pri) {
    if (typed != null && k != typed) return;
    if (out.any((m) => m.kind == k && m.id == id)) return;
    out.add(ScanMatch(k, id, title, sub, why, pri));
  }

  if (q.isEmpty) return ScanResult(raw, code, const []);
  if (_reInternal.hasMatch(code)) {
    final a = c.asset(code);
    if (a != null) add(ResultKind.asset, a.id, a.label, a.name, a.id == code ? 'unit id' : 'earlier id', 100);
    final p = c.parts[code];
    if (p != null) add(ResultKind.part, p.id, p.number, p.description, 'internal id', 100);
    final d = c.documents[code] ?? c.revisions[code]?.document;
    if (d != null) add(ResultKind.document, d.id, d.label, d.title, 'internal id', 100);
    final j = c.projects[code];
    if (j != null) add(ResultKind.project, j.id, j.label, j.customer, 'internal id', 100);
  }
  // A permanent unit label names an id; it never falls back to a tag that happens to look the same.
  if (!(typed == ResultKind.asset && _reAssetId.hasMatch(code))) {
    const words = {'tag': 'asset tag', 'serial': 'serial number', 'other': 'code'};
    const rank = {'tag': 95, 'serial': 94, 'other': 93};
    for (final active in [true, false]) {
      for (final a in c.assets.values) {
        for (final i in a.identifiers) {
          if (i.active == active && norm(i.value) == q) {
            final why = '${active ? '' : 'former '}${words[i.scheme] ?? i.scheme}'
                '${i.issuer.isEmpty ? '' : ' (${i.issuer})'}';
            add(ResultKind.asset, a.id, a.label, a.name, why, (rank[i.scheme] ?? 90) - (active ? 0 : 10));
          }
        }
      }
    }
  }
  for (final p in c.parts.values) {
    if (norm(p.number) == q) add(ResultKind.part, p.id, p.number, p.description, 'part number', 90);
  }
  for (final d in c.documents.values) {
    if (norm(d.number) == q) add(ResultKind.document, d.id, d.label, d.title, 'document number', 85);
  }
  for (final j in c.projects.values) {
    if (norm(j.number) == q) add(ResultKind.project, j.id, j.label, j.customer, 'project number', 80);
  }
  for (final p in c.parts.values) {
    for (final m in p.manufacturers) {
      if (norm(m.code) == q) add(ResultKind.part, p.id, p.number, p.description, '${m.name} part number', 70);
    }
    for (final v in p.vendors) {
      if (norm(v.code) == q) add(ResultKind.part, p.id, p.number, p.description, '${v.name} order code', 65);
    }
  }
  for (final l in c.bom) {
    for (final r in l.refdes) {
      if (norm(r) == q) {
        final p = c.parts[l.childId];
        final parent = c.parts[l.parentId];
        if (p != null) {
          add(ResultKind.part, p.id, p.number, '$r in ${parent?.number ?? '?'} · ${p.description}',
              'reference designator', 60);
        }
      }
    }
  }
  out.sort((a, b) => b.priority - a.priority);
  return ScanResult(raw, code, out, typed: typed);
}
