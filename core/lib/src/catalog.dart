// SPDX-License-Identifier: GPL-3.0-or-later
// The engineering snapshot (docs/PROTOCOL.md section 6) as typed, indexed, searchable data. Read-only: authority
// stays with RevisionWorx and OpenMeridian. checkCatalog applies the same rules as
// bridge/fieldworx_bridge/catalog.py, so a malformed catalog is refused rather than half-shown.

import 'decimal.dart';
import 'events.dart' show cpLen;
import 'fxjson.dart' as fx;
import 'inspection.dart' show checkTemplate, TemplateError;

const String catalogFormat = 'fieldworx.catalog';
final RegExp _reSha = RegExp(r'^[0-9a-f]{64}$');
final RegExp _reQty = RegExp(r'^(0|[1-9]\d{0,14})(\.\d{1,9})?$');

class CatalogError implements Exception {
  CatalogError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _s(Object? v, String what, [int limit = 500]) {
  if (v is! String || cpLen(v) > limit) throw CatalogError('$what must be text of at most $limit characters');
  return v;
}

Map<String, Object?> _keys(Object? d, Set<String> want, String what) {
  if (d is! Map || d.length != want.length || !d.keys.every(want.contains)) {
    throw CatalogError('$what: fields wrong');
  }
  return fx.asMap(d, what);
}

List<Object?> _list(Object? v, String what, [int limit = 1000000]) {
  if (v is! List || v.length > limit) throw CatalogError('$what must be a list');
  return v;
}

/// Throws [CatalogError] unless [c] is a valid version 1 catalog.
void checkCatalog(Object? c) {
  final m = _keys(c, {'format', 'version', 'projects', 'documents', 'parts', 'bom', 'assets', 'templates'}, 'catalog');
  if (m['format'] != catalogFormat) throw CatalogError('not a FieldWorx catalog');
  if (m['version'] != 1) throw CatalogError('catalog version ${m['version']} is newer than this program understands');
  final ids = <String>{};
  void unique(String i, String what) {
    if (!ids.add(i)) throw CatalogError('$what id $i appears twice');
  }

  final projects = <String>{};
  for (final p in _list(m['projects'], 'projects')) {
    final pm = _keys(p, {'id', 'number', 'name', 'customer'}, 'project');
    for (final k in pm.keys) {
      _s(pm[k], 'project $k', 200);
    }
    unique(pm['id']! as String, 'project');
    projects.add(pm['id']! as String);
  }
  final revs = <String>{};
  final docs = <String>{};
  for (final d in _list(m['documents'], 'documents')) {
    final dm = _keys(d, {'id', 'number', 'title', 'type', 'project', 'path', 'released', 'latest', 'revisions'}, 'document');
    for (final k in ['id', 'number', 'title', 'type', 'project', 'path', 'released', 'latest']) {
      _s(dm[k], 'document $k');
    }
    unique(dm['id']! as String, 'document');
    docs.add(dm['id']! as String);
    final proj = dm['project']! as String;
    if (proj.isNotEmpty && !projects.contains(proj)) throw CatalogError("a document names a project that isn't there");
    final own = <String>{};
    for (final r in _list(dm['revisions'], 'revisions', 10000)) {
      final rm = _keys(r, {
        'id', 'label', 'state', 'state_name', 'sha256', 'size', 'created', 'author', 'description', 'ext', //
        'rendition',
      }, 'revision');
      for (final k in ['id', 'label', 'state', 'state_name', 'created', 'author', 'ext']) {
        _s(rm[k], 'revision $k', 200);
      }
      _s(rm['description'], 'revision description', 4000);
      if (!_reSha.hasMatch(_s(rm['sha256'], 'revision sha256')) || rm['size'] is! int) {
        throw CatalogError('revision hash or size malformed');
      }
      unique(rm['id']! as String, 'revision');
      revs.add(rm['id']! as String);
      own.add(rm['id']! as String);
      final rend = rm['rendition'];
      if (rend != null) {
        final rr = _keys(rend, {'object', 'media_type', 'via'}, 'rendition');
        if (!_reSha.hasMatch(_s(rr['object'], 'rendition object'))) throw CatalogError('rendition object malformed');
        _s(rr['media_type'], 'rendition media type', 100);
        _s(rr['via'], 'rendition via', 200);
      }
    }
    for (final k in ['released', 'latest']) {
      final v = dm[k]! as String;
      if (v.isNotEmpty && !own.contains(v)) throw CatalogError('document $k revision is not among its revisions');
    }
  }
  final parts = <String>{};
  for (final p in _list(m['parts'], 'parts')) {
    final pm = _keys(p, {
      'id', 'number', 'description', 'unit', 'kind', 'revision', 'status', 'manufacturers', 'vendors', 'documents', //
      'attributes', 'stock',
    }, 'part');
    for (final k in ['id', 'number', 'description', 'unit', 'kind', 'revision', 'status']) {
      _s(pm[k], 'part $k');
    }
    unique(pm['id']! as String, 'part');
    parts.add(pm['id']! as String);
    for (final x in _list(pm['manufacturers'], 'manufacturers', 100)) {
      final xm = _keys(x, {'name', 'mpn'}, 'manufacturer');
      _s(xm['name'], 'manufacturer', 200);
      _s(xm['mpn'], 'MPN', 200);
    }
    for (final x in _list(pm['vendors'], 'vendors', 100)) {
      final xm = _keys(x, {'name', 'sku'}, 'vendor');
      _s(xm['name'], 'vendor', 200);
      _s(xm['sku'], 'SKU', 200);
    }
    for (final x in _list(pm['documents'], 'part documents', 100)) {
      final xm = _keys(x, {'document', 'revision', 'role'}, 'part document');
      for (final k in xm.keys) {
        _s(xm[k], 'part document $k', 200);
      }
    }
    final attrs = pm['attributes'];
    if (attrs is! Map || attrs.length > 200) throw CatalogError('part attributes must be an object');
    attrs.forEach((k, v) {
      _s(k, 'attribute name', 100);
      _s(v, 'attribute value', 1000);
    });
    final st = pm['stock'];
    if (st != null) {
      final sm = _keys(st, {'on_hand', 'unit', 'bin', 'as_of', 'source'}, 'stock');
      for (final k in sm.keys) {
        _s(sm[k], 'stock $k', 200);
      }
      if (!isDecimal(sm['on_hand'])) throw CatalogError('stock on hand must be a decimal');
    }
  }
  for (final b in _list(m['bom'], 'bom')) {
    final bm = _keys(b, {'parent', 'child', 'quantity', 'unit', 'find_number', 'refdes', 'note', 'provenance', 'source'},
        'BOM line');
    for (final k in ['parent', 'child', 'quantity', 'unit', 'find_number', 'note', 'provenance', 'source']) {
      _s(bm[k], 'BOM line $k', 1000);
    }
    if (!parts.contains(bm['parent']) || !parts.contains(bm['child'])) {
      throw CatalogError("a BOM line names a part that isn't in the package");
    }
    if (!_reQty.hasMatch(bm['quantity']! as String)) throw CatalogError('BOM quantity must be a positive decimal');
    for (final r in _list(bm['refdes'], 'reference designators', 10000)) {
      _s(r, 'reference designator', 64);
    }
  }
  for (final a in _list(m['assets'], 'assets')) {
    final am = _keys(a, {'id', 'tag', 'serial', 'name', 'part', 'project', 'location', 'built', 'notes', 'as_built'},
        'asset');
    for (final k in ['id', 'tag', 'serial', 'name', 'part', 'project', 'location', 'built']) {
      _s(am[k], 'asset $k', 200);
    }
    _s(am['notes'], 'asset notes', 4000);
    unique(am['id']! as String, 'asset');
    final part = am['part']! as String, proj = am['project']! as String;
    if (part.isNotEmpty && !parts.contains(part)) throw CatalogError("an asset names a part that isn't there");
    if (proj.isNotEmpty && !projects.contains(proj)) throw CatalogError("an asset names a project that isn't there");
    for (final r in _list(am['as_built'], 'as-built revisions', 1000)) {
      if (!revs.contains(r)) throw CatalogError("an asset names an as-built revision that isn't there");
    }
  }
  final tids = <String>{};
  for (final t in _list(m['templates'], 'templates', 10000)) {
    final tm = _keys(t, {'template', 'document', 'revision', 'state'}, 'template entry');
    try {
      checkTemplate(tm['template']);
    } on TemplateError catch (e) {
      throw CatalogError('template: ${e.message}');
    }
    final tt = tm['template']! as Map;
    if (!tids.add('${(tt['id'] as String).toLowerCase()}\u0000${(tt['revision'] as String).toLowerCase()}')) {
      throw CatalogError('a template appears twice');
    }
    for (final k in ['document', 'revision', 'state']) {
      _s(tm[k], 'template $k', 200);
    }
    final doc = tm['document']! as String;
    if (doc.isNotEmpty && !docs.contains(doc)) throw CatalogError("a template names a document that isn't there");
  }
}

// ------------------------------------------------------------------------------------------------- model
class PackageInfo {
  PackageInfo({
    required this.id,
    required this.title,
    required this.series,
    required this.created,
    required this.digest,
    required this.source,
    required this.notices,
    required this.createdBy,
  });
  final String id, title, series, created, digest;
  final Map<String, Object?> source, createdBy;
  final List<String> notices;

  String get sourceName => (source['name'] as String?) ?? '';
}

class Project {
  Project(this.id, this.number, this.name, this.customer, this.package);
  final String id, number, name, customer;
  final PackageInfo package;
  String get label => [number, name].where((s) => s.isNotEmpty).join(' ');
}

class Rendition {
  Rendition(this.object, this.mediaType, this.via);
  final String object, mediaType, via;
}

class Revision {
  Revision(this.id, this.label, this.state, this.stateName, this.sha256, this.size, this.created, this.author,
      this.description, this.ext, this.rendition);
  final String id, label, state, stateName, sha256, created, author, description, ext;
  final int size;
  final Rendition? rendition;
  late final Document document;

  bool get isReleased => state == 'released';
}

class Document {
  Document(this.id, this.number, this.title, this.type, this.projectId, this.path, this.releasedId, this.latestId,
      this.revisions, this.package);
  final String id, number, title, type, projectId, path, releasedId, latestId;
  final List<Revision> revisions;
  final PackageInfo package;

  Revision? get released => _rev(releasedId);
  Revision? get latest => _rev(latestId);
  Revision? _rev(String id) {
    for (final r in revisions) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// What the phone should open by default: the released revision, else the newest one it has a view of.
  Revision? get current {
    final r = released;
    if (r != null) return r;
    for (final x in revisions.reversed) {
      if (x.rendition != null) return x;
    }
    return latest;
  }

  String get label => number.isNotEmpty ? number : title;
}

class Party {
  const Party(this.name, this.code);
  final String name, code;
}

class PartDocumentLink {
  const PartDocumentLink(this.documentId, this.revisionId, this.role);
  final String documentId, revisionId, role;
}

class Stock {
  Stock(this.onHand, this.unit, this.bin, this.asOf, this.source);
  final String onHand, unit, bin, asOf, source;
}

class Part {
  Part(this.id, this.number, this.description, this.unit, this.kind, this.revision, this.status, this.manufacturers,
      this.vendors, this.documents, this.attributes, this.stock, this.package);
  final String id, number, description, unit, kind, revision, status;
  final List<Party> manufacturers, vendors;
  final List<PartDocumentLink> documents;
  final Map<String, String> attributes;
  final Stock? stock;
  final PackageInfo package;
}

class BomLine {
  BomLine(this.parentId, this.childId, this.quantity, this.unit, this.findNumber, this.refdes, this.note,
      this.provenance, this.source);
  final String parentId, childId, quantity, unit, findNumber, note, provenance, source;
  final List<String> refdes;
}

class Asset {
  Asset(this.id, this.tag, this.serial, this.name, this.partId, this.projectId, this.location, this.built, this.notes,
      this.asBuilt, this.package);
  final String id, tag, serial, name, partId, projectId, location, built, notes;
  final List<String> asBuilt;
  final PackageInfo package;
  String get label => tag.isNotEmpty ? tag : serial;
}

class TemplateEntry {
  TemplateEntry(this.template, this.documentId, this.revisionId, this.state, this.package);
  final Map<String, Object?> template;
  final String documentId, revisionId, state;
  final PackageInfo package;
  String get id => template['id']! as String;
  String get revision => template['revision']! as String;
  String get title => template['title']! as String;
  bool get controlled => state != 'uncontrolled';
}

enum ResultKind { asset, part, document, project, template }

class SearchResult {
  SearchResult(this.kind, this.id, this.title, this.subtitle, this.score, this.why);
  final ResultKind kind;
  final String id, title, subtitle, why;
  final int score;
}

String norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Everything installed, merged across packages (the newest package wins for an id it shares with another).
class Catalog {
  final Map<String, Project> projects = {};
  final Map<String, Document> documents = {};
  final Map<String, Revision> revisions = {};
  final Map<String, Part> parts = {};
  final Map<String, Asset> assets = {};
  final List<BomLine> bom = [];
  final List<TemplateEntry> templates = [];
  final List<PackageInfo> packages = [];
  final Map<String, List<BomLine>> _children = {};
  final Map<String, List<BomLine>> _parents = {};

  bool get isEmpty => packages.isEmpty;

  /// Adds one package's catalog. Call in order from oldest to newest package.
  void add(PackageInfo pkg, Map<String, Object?> c) {
    packages.add(pkg);
    for (final p in (c['projects']! as List).cast<Map<String, Object?>>()) {
      projects[p['id']! as String] =
          Project(p['id']! as String, p['number']! as String, p['name']! as String, p['customer']! as String, pkg);
    }
    for (final d in (c['documents']! as List).cast<Map<String, Object?>>()) {
      final revs = <Revision>[
        for (final r in (d['revisions']! as List).cast<Map<String, Object?>>())
          Revision(
            r['id']! as String,
            r['label']! as String,
            r['state']! as String,
            r['state_name']! as String,
            r['sha256']! as String,
            r['size']! as int,
            r['created']! as String,
            r['author']! as String,
            r['description']! as String,
            r['ext']! as String,
            r['rendition'] == null
                ? null
                : () {
                    final m = r['rendition']! as Map<String, Object?>;
                    return Rendition(m['object']! as String, m['media_type']! as String, m['via']! as String);
                  }(),
          ),
      ];
      final doc = Document(d['id']! as String, d['number']! as String, d['title']! as String, d['type']! as String,
          d['project']! as String, d['path']! as String, d['released']! as String, d['latest']! as String, revs, pkg);
      final old = documents[doc.id];
      if (old != null) {
        for (final r in old.revisions) {
          revisions.remove(r.id);
        }
      }
      documents[doc.id] = doc;
      for (final r in revs) {
        r.document = doc;
        revisions[r.id] = r;
      }
    }
    for (final p in (c['parts']! as List).cast<Map<String, Object?>>()) {
      final st = p['stock'] as Map<String, Object?>?;
      parts[p['id']! as String] = Part(
        p['id']! as String,
        p['number']! as String,
        p['description']! as String,
        p['unit']! as String,
        p['kind']! as String,
        p['revision']! as String,
        p['status']! as String,
        [
          for (final m in (p['manufacturers']! as List).cast<Map<String, Object?>>())
            Party(m['name']! as String, m['mpn']! as String),
        ],
        [
          for (final m in (p['vendors']! as List).cast<Map<String, Object?>>())
            Party(m['name']! as String, m['sku']! as String),
        ],
        [
          for (final m in (p['documents']! as List).cast<Map<String, Object?>>())
            PartDocumentLink(m['document']! as String, m['revision']! as String, m['role']! as String),
        ],
        (p['attributes']! as Map).cast<String, String>(),
        st == null
            ? null
            : Stock(st['on_hand']! as String, st['unit']! as String, st['bin']! as String, st['as_of']! as String,
                st['source']! as String),
        pkg,
      );
    }
    // A newer package replaces the BOM of every parent it describes.
    final lines = [
      for (final b in (c['bom']! as List).cast<Map<String, Object?>>())
        BomLine(b['parent']! as String, b['child']! as String, b['quantity']! as String, b['unit']! as String,
            b['find_number']! as String, (b['refdes']! as List).cast<String>(), b['note']! as String,
            b['provenance']! as String, b['source']! as String),
    ];
    final parents = {for (final l in lines) l.parentId};
    bom.removeWhere((l) => parents.contains(l.parentId));
    bom.addAll(lines);
    for (final a in (c['assets']! as List).cast<Map<String, Object?>>()) {
      assets[a['id']! as String] = Asset(
          a['id']! as String,
          a['tag']! as String,
          a['serial']! as String,
          a['name']! as String,
          a['part']! as String,
          a['project']! as String,
          a['location']! as String,
          a['built']! as String,
          a['notes']! as String,
          (a['as_built']! as List).cast<String>(),
          pkg);
    }
    for (final t in (c['templates']! as List).cast<Map<String, Object?>>()) {
      final e = TemplateEntry(fx.asMap(t['template'], 'template'), t['document']! as String, t['revision']! as String,
          t['state']! as String, pkg);
      templates.removeWhere((x) => x.id.toLowerCase() == e.id.toLowerCase() && x.revision == e.revision);
      templates.add(e);
    }
    _reindex();
  }

  void _reindex() {
    _children.clear();
    _parents.clear();
    for (final l in bom) {
      (_children[l.parentId] ??= []).add(l);
      (_parents[l.childId] ??= []).add(l);
    }
    for (final v in _children.values) {
      v.sort((a, b) => _naturalCompare(a.findNumber, b.findNumber));
    }
  }

  List<BomLine> children(String partId) => _children[partId] ?? const [];
  List<BomLine> parentsOf(String partId) => _parents[partId] ?? const [];

  /// Documents linked to a part: its declared links first, then documents numbered like the part.
  List<(Document, String)> documentsForPart(Part p) {
    final out = <(Document, String)>[];
    for (final l in p.documents) {
      final d = documents[l.documentId];
      if (d != null && !out.any((x) => x.$1.id == d.id)) out.add((d, l.role));
    }
    return out;
  }

  List<Asset> assetsForPart(String partId) => [for (final a in assets.values) if (a.partId == partId) a];
  List<Document> documentsForProject(String id) =>
      [for (final d in documents.values) if (d.projectId == id) d]..sort((a, b) => _naturalCompare(a.label, b.label));
  List<Asset> assetsForProject(String id) => [for (final a in assets.values) if (a.projectId == id) a];

  /// Templates newest first by id, controlled before uncontrolled.
  List<TemplateEntry> sortedTemplates() => [...templates]..sort((a, b) {
      final c = _naturalCompare(a.id, b.id);
      if (c != 0) return c;
      return _naturalCompare(b.revision, a.revision);
    });

  /// Text search across assets, parts, documents and projects. Results best first.
  List<SearchResult> search(String query, {int limit = 100}) {
    final q = norm(query);
    if (q.isEmpty) return const [];
    final words = q.split(' ');
    final out = <SearchResult>[];
    int codeScore(String code, int exact, int prefix, int contains) {
      final c = norm(code);
      if (c.isEmpty) return 0;
      if (c == q) return exact;
      if (c.startsWith(q)) return prefix;
      if (c.contains(q)) return contains;
      return 0;
    }

    int textScore(String text, int perWord) {
      final t = norm(text);
      if (t.isEmpty) return 0;
      var s = 0;
      for (final w in words) {
        if (!t.contains(w)) return 0;
        s += RegExp('(^|[^a-z0-9])${RegExp.escape(w)}').hasMatch(t) ? perWord : perWord ~/ 2;
      }
      return s;
    }

    for (final a in assets.values) {
      final s = [codeScore(a.tag, 1000, 700, 300), codeScore(a.serial, 1000, 700, 300), textScore(a.name, 40),
        textScore(a.location, 20)].reduce((x, y) => x > y ? x : y);
      if (s > 0) {
        out.add(SearchResult(ResultKind.asset, a.id, a.label, [a.name, a.location].where((x) => x.isNotEmpty).join(' · '),
            s, 'asset'));
      }
    }
    for (final p in parts.values) {
      var s = codeScore(p.number, 900, 600, 250);
      var why = 'part number';
      for (final m in [...p.manufacturers, ...p.vendors]) {
        final ms = codeScore(m.code, 800, 500, 200);
        if (ms > s) {
          s = ms;
          why = '${m.name} ${m.code}';
        }
      }
      final ts = textScore(p.description, 40);
      if (ts > s) {
        s = ts;
        why = 'description';
      }
      if (s > 0) out.add(SearchResult(ResultKind.part, p.id, p.number, p.description, s, why));
    }
    for (final d in documents.values) {
      final s = [codeScore(d.number, 850, 550, 220), textScore(d.title, 35)].reduce((x, y) => x > y ? x : y);
      if (s > 0) out.add(SearchResult(ResultKind.document, d.id, d.label, d.title, s, 'document'));
    }
    for (final p in projects.values) {
      final s = [codeScore(p.number, 600, 400, 150), textScore(p.name, 30), textScore(p.customer, 20)]
          .reduce((x, y) => x > y ? x : y);
      if (s > 0) out.add(SearchResult(ResultKind.project, p.id, p.label, p.customer, s, 'project'));
    }
    // Reference designators: K1 in a panel's BOM.
    for (final l in bom) {
      for (final r in l.refdes) {
        if (norm(r) == q) {
          final child = parts[l.childId], parent = parts[l.parentId];
          if (child != null) {
            out.add(SearchResult(ResultKind.part, child.id, child.number,
                '$r in ${parent?.number ?? '?'} · ${child.description}', 650, 'reference $r'));
          }
        }
      }
    }
    out.sort((a, b) => b.score != a.score ? b.score - a.score : _naturalCompare(a.title, b.title));
    final seen = <String>{};
    final unique = [for (final r in out) if (seen.add('${r.kind}:${r.id}')) r];
    return unique.take(limit).toList();
  }
}

/// Compares "SEC-2" before "SEC-10".
int _naturalCompare(String a, String b) {
  final ra = RegExp(r'(\d+)|(\D+)').allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final rb = RegExp(r'(\d+)|(\D+)').allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < ra.length && i < rb.length; i++) {
    final x = ra[i], y = rb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return ra.length - rb.length;
}

int naturalCompare(String a, String b) => _naturalCompare(a, b);
