// SPDX-License-Identifier: GPL-3.0-or-later
// The engineering snapshot (docs/PROTOCOL.md section 6) as typed, indexed, searchable data. Read-only: authority
// stays with RevisionWorx and OpenMeridian. checkCatalog applies the same rules as
// bridge/fieldworx_bridge/catalog.py, so a malformed catalog is refused rather than half-shown.

import 'decimal.dart';
import 'events.dart' show cpLen;
import 'fxjson.dart' as fx;
import 'inspection.dart' show checkTemplate, TemplateError;

const String catalogFormat = 'fieldworx.catalog';

/// The catalog versions this reads; it writes none (the bridge writes version 2).
const List<int> catalogVersions = [1, 2];
final RegExp _reSha = RegExp(r'^[0-9a-f]{64}$');
final RegExp _reQty = RegExp(r'^(0|[1-9]\d{0,14})(\.\d{1,9})?$');
final RegExp _reAssetId = RegExp(r'^(unt|ast)_[0-9a-f]{32}$');
final RegExp _reAlias = RegExp(r'^ast_[0-9a-f]{32}$');
const Set<String> _assetV1 = {'id', 'tag', 'serial', 'name', 'part', 'project', 'location', 'built', 'notes', 'as_built'};
const Set<String> _assetV2 = {
  'id', 'aliases', 'label', 'class', 'name', 'model', 'part', 'project', 'customer', 'site', 'location', 'status', //
  'identifiers', 'parent', 'standard', 'documents', 'components', 'milestones', 'history', 'changes', 'deviations', //
  'notes', 'source',
};
const List<String> assetClasses = ['product', 'component', 'instrument', 'tool'];
const List<String> changeKinds = ['', 'production', 'retrofit-required', 'retrofit-optional', 'unit', 'documentation'];
const List<String> changeStates = [
  'pending', 'offered', 'accepted', 'scheduled', 'deferred', 'declined', 'installed', 'verified', 'not-applicable', //
  'reversed',
];
const List<String> deviationKinds = ['deviation', 'concession'];
const List<String> deviationStates = ['in-effect', 'cleared', 'not-used'];
final RegExp _reDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');
const List<String> assetStatuses = ['', 'planned', 'in-build', 'built', 'in-service', 'out-of-service', 'retired', 'scrapped'];
const List<String> _schemes = ['serial', 'tag', 'other'];
const List<String> _sources = ['standard', 'unit', 'register'];
const List<String> assetBases = ['verified', 'reported', 'declared', 'legacy'];
const List<String> milestoneNames = ['built', 'shipped', 'installed', 'commissioned', 'decommissioned'];

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

String _choice(Object? v, List<String> choices, String what) {
  if (v is! String || !choices.contains(v)) throw CatalogError('$what must be one of ${choices.join(', ')}');
  return v;
}

bool _bool(Object? v, String what) {
  if (v is! bool) throw CatalogError('$what must be true or false');
  return v;
}

/// Throws [CatalogError] unless [c] is a valid version 1 or 2 catalog (docs/PROTOCOL.md section 6).
void checkCatalog(Object? c) {
  final m = _keys(c, {'format', 'version', 'projects', 'documents', 'parts', 'bom', 'assets', 'templates'}, 'catalog');
  if (m['format'] != catalogFormat) throw CatalogError('not a FieldWorx catalog');
  final version = m['version'];
  if (version is! int || !catalogVersions.contains(version)) {
    throw CatalogError('catalog version $version is newer than this program understands');
  }
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
  final revDoc = <String, String>{};
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
      revDoc[rm['id']! as String] = dm['id']! as String;
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
  if (version == 1) {
    for (final a in _list(m['assets'], 'assets')) {
      final am = _keys(a, _assetV1, 'asset');
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
  } else {
    _checkAssetsV2(_list(m['assets'], 'assets'), unique, projects, docs, parts, revDoc);
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

void _checkAssetsV2(List<Object?> assets, void Function(String, String) unique, Set<String> projects, Set<String> docs,
    Set<String> parts, Map<String, String> revDoc) {
  final ids = <String>{};
  final parents = <String, String>{};
  for (final a in assets) {
    final am = _keys(a, _assetV2, 'asset');
    final id = am['id'];
    if (id is! String || !_reAssetId.hasMatch(id)) throw CatalogError('an asset id must be unt_ or ast_ and 32 hex digits');
    unique(id, 'asset');
    ids.add(id);
    String? previous;
    for (final x in _list(am['aliases'], 'asset aliases', 100)) {
      if (x is! String || !_reAlias.hasMatch(x)) throw CatalogError('asset aliases must be ast_ ids');
      if (previous != null && x.compareTo(previous) <= 0) throw CatalogError('asset aliases must be sorted and unique');
      previous = x;
      unique(x, 'asset');
    }
    for (final k in ['label', 'name', 'customer', 'site', 'location', 'source']) {
      _s(am[k], 'asset $k', 200);
    }
    _s(am['model'], 'asset model', 100);
    _s(am['notes'], 'asset notes', 4000);
    _choice(am['class'], assetClasses, 'asset class');
    _choice(am['status'], assetStatuses, 'asset status');
    final part = _s(am['part'], 'asset part', 64), proj = _s(am['project'], 'asset project', 64);
    if (part.isNotEmpty && !parts.contains(part)) throw CatalogError("an asset names a part that isn't there");
    if (proj.isNotEmpty && !projects.contains(proj)) throw CatalogError("an asset names a project that isn't there");
    for (final i in _list(am['identifiers'], 'asset identifiers', 100)) {
      final im = _keys(i, {'scheme', 'issuer', 'value', 'active'}, 'identifier');
      _choice(im['scheme'], _schemes, 'identifier scheme');
      _s(im['issuer'], 'identifier issuer', 200);
      if (_s(im['value'], 'identifier value', 100).isEmpty) throw CatalogError('an identifier has no value');
      _bool(im['active'], 'identifier active');
    }
    final parent = am['parent'];
    if (parent != null) {
      final pm = _keys(parent, {'asset', 'position'}, 'parent');
      parents[id] = _s(pm['asset'], 'parent asset', 64);
      _s(pm['position'], 'parent position', 64);
    }
    final standard = am['standard'];
    if (standard != null) {
      final sm = _keys(standard, {'number', 'title'}, 'standard');
      _s(sm['number'], 'standard number', 64);
      _s(sm['title'], 'standard title', 200);
    }
    final seenDocs = <String>{};
    for (final d in _list(am['documents'], 'asset documents', 2000)) {
      final dm = _keys(d, {'document', 'revision', 'source', 'basis'}, 'asset document');
      final doc = _s(dm['document'], 'asset document', 64), rev = _s(dm['revision'], 'asset revision', 64);
      if (!seenDocs.add(doc)) throw CatalogError('an asset names a document twice');
      if (!docs.contains(doc)) throw CatalogError("an asset names a document that isn't there");
      if (rev.isNotEmpty && revDoc[rev] != doc) throw CatalogError("an asset names a revision that isn't there");
      _choice(dm['source'], _sources, 'document source');
      _choice(dm['basis'], assetBases, 'document basis');
    }
    final positions = <String>{};
    for (final c in _list(am['components'], 'asset components', 1000)) {
      final cm = _keys(c, {'position', 'part', 'number', 'asset', 'serial', 'lot', 'since', 'basis'}, 'component');
      final pos = _s(cm['position'], 'component position', 64);
      if (pos.isEmpty || !positions.add(pos)) throw CatalogError('component positions must be given and unique');
      for (final k in ['part', 'number', 'asset', 'serial', 'lot', 'since']) {
        _s(cm[k], 'component $k', 200);
      }
      final cp = cm['part']! as String;
      if (cp.isNotEmpty && !parts.contains(cp)) throw CatalogError("a component names a part that isn't there");
      _choice(cm['basis'], assetBases, 'component basis');
    }
    final ms = am['milestones'];
    if (ms is! Map || !ms.keys.every(milestoneNames.contains)) {
      throw CatalogError('milestones are built, shipped, installed, commissioned and decommissioned');
    }
    for (final v in ms.values) {
      _s(v, 'milestone date', 32);
    }
    var last = 0;
    for (final h in _list(am['history'], 'asset history', 1000)) {
      final hm = _keys(h, {'n', 'type', 'summary', 'effective', 'time', 'actor', 'basis', 'voided'}, 'history entry');
      final n = hm['n'];
      if (n is! int || n <= last) throw CatalogError('history numbers must increase');
      last = n;
      _s(hm['type'], 'history type', 64);
      _s(hm['summary'], 'history summary', 500);
      _s(hm['effective'], 'history effective', 32);
      _s(hm['time'], 'history time', 32);
      _s(hm['actor'], 'history actor', 200);
      _choice(hm['basis'], assetBases, 'history basis');
      _bool(hm['voided'], 'history voided');
    }
    final seenChanges = <String>{};
    for (final ch in _list(am['changes'], 'asset changes', 200)) {
      final cm = _keys(ch, {'change', 'number', 'title', 'kind', 'required', 'state', 'since', 'documents'}, 'change');
      final cid = _s(cm['change'], 'change id', 64);
      if (cid.isEmpty || !seenChanges.add(cid)) throw CatalogError('each change is given once, with its id');
      _s(cm['number'], 'change number', 64);
      _s(cm['title'], 'change title', 200);
      _choice(cm['kind'], changeKinds, 'change kind');
      _bool(cm['required'], 'change required');
      _choice(cm['state'], changeStates, 'change state');
      _s(cm['since'], 'change since', 32);
      for (final row in _list(cm['documents'], 'change documents', 100)) {
        final rm = _keys(row, {'number', 'from', 'to'}, 'change document');
        for (final k in ['number', 'from', 'to']) {
          _s(rm[k], 'change document $k', 64);
        }
      }
    }
    final seenDeviations = <String>{};
    for (final dv in _list(am['deviations'], 'asset deviations', 200)) {
      final dm = _keys(
          dv,
          {'deviation', 'number', 'kind', 'title', 'departure', 'temporary', 'until', 'state', 'since', 'documents'},
          'deviation');
      final did = _s(dm['deviation'], 'deviation id', 64);
      if (did.isEmpty || !seenDeviations.add(did)) throw CatalogError('each deviation is given once, with its id');
      _s(dm['number'], 'deviation number', 64);
      _choice(dm['kind'], deviationKinds, 'deviation kind');
      _s(dm['title'], 'deviation title', 200);
      _s(dm['departure'], 'deviation departure', 4000);
      if (_bool(dm['temporary'], 'deviation temporary')) {
        final until = _s(dm['until'], 'deviation until', 32);
        if (until.isNotEmpty && !_reDate.hasMatch(until)) {
          throw CatalogError("a deviation's end date is YYYY-MM-DD, or empty");
        }
      } else if (dm['until'] != '') {
        throw CatalogError('only a temporary deviation has an end date');
      }
      _choice(dm['state'], deviationStates, 'deviation state');
      _s(dm['since'], 'deviation since', 32);
      for (final row in _list(dm['documents'], 'deviation documents', 100)) {
        final rm = _keys(row, {'number', 'revision'}, 'deviation document');
        for (final k in ['number', 'revision']) {
          _s(rm[k], 'deviation document $k', 64);
        }
      }
    }
  }
  for (final a in assets) {
    final am = fx.asMap(a, 'asset');
    final fitted = [
      for (final c in fx.asList(am['components'], 'components')) fx.asMap(c, 'component')['asset']! as String,
    ];
    final refs = [
      ...fitted.where((r) => r.isNotEmpty),
      if (am['parent'] != null) fx.asMap(am['parent'], 'parent')['asset']! as String,
    ];
    for (final r in refs) {
      if (!ids.contains(r)) throw CatalogError("an asset names an asset that isn't there");
    }
  }
  for (final start in parents.keys) {
    final seen = <String>{start};
    var cur = parents[start];
    while (cur != null) {
      if (!seen.add(cur)) throw CatalogError('assets are fitted inside each other in a loop');
      cur = parents[cur];
    }
  }
}

/// An asset as catalog version 2 describes it, whatever the version of its catalog (docs/PROTOCOL.md section 6.4):
/// a version 1 asset (a row of an asset register) becomes the version 2 asset the protocol derives from it.
Map<String, Object?> assetView(Map<String, Object?> a, int version, Map<String, String> revisionDocument) {
  if (version != 1) return a;
  final tag = a['tag']! as String, serial = a['serial']! as String, built = a['built']! as String;
  return <String, Object?>{
    'id': a['id'],
    'aliases': <Object?>[],
    'label': tag.isNotEmpty ? tag : serial,
    'class': 'product',
    'name': a['name'],
    'model': '',
    'part': a['part'],
    'project': a['project'],
    'customer': '',
    'site': '',
    'location': a['location'],
    'status': '',
    'identifiers': <Object?>[
      for (final s in ['tag', 'serial'])
        if ((a[s]! as String).isNotEmpty) <String, Object?>{'scheme': s, 'issuer': '', 'value': a[s], 'active': true},
    ],
    'parent': null,
    'standard': null,
    'documents': <Object?>[
      for (final r in (a['as_built']! as List).cast<String>())
        <String, Object?>{'document': revisionDocument[r], 'revision': r, 'source': 'register', 'basis': 'legacy'},
    ],
    'components': <Object?>[],
    'milestones': built.isEmpty ? <String, Object?>{} : <String, Object?>{'built': built},
    'history': <Object?>[],
    'changes': <Object?>[],
    'deviations': <Object?>[],
    'notes': a['notes'],
    'source': '',
  };
}

/// Every asset of a checked catalog, in the version 2 shape.
List<Map<String, Object?>> assetsView(Map<String, Object?> c) {
  final owner = <String, String>{
    for (final d in (c['documents']! as List).cast<Map<String, Object?>>())
      for (final r in (d['revisions']! as List).cast<Map<String, Object?>>()) r['id']! as String: d['id']! as String,
  };
  final version = c['version']! as int;
  return [for (final a in (c['assets']! as List).cast<Map<String, Object?>>()) assetView(a, version, owner)];
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

class AssetIdentifier {
  AssetIdentifier(this.scheme, this.issuer, this.value, this.active);
  final String scheme, issuer, value;
  final bool active;
}

/// One document of a unit's record: the revision that applies to this unit (empty when the document doesn't apply), where
/// that came from (`standard`, `unit` or `register`) and how well it is known.
class AssetDocument {
  AssetDocument(this.documentId, this.revisionId, this.source, this.basis);
  final String documentId, revisionId, source, basis;
  bool get applies => revisionId.isNotEmpty;
}

class AssetComponent {
  AssetComponent(this.position, this.partId, this.number, this.assetId, this.serial, this.lot, this.since, this.basis);
  final String position, partId, number, assetId, serial, lot, since, basis;
}

class AssetEvent {
  AssetEvent(this.n, this.type, this.summary, this.effective, this.time, this.actor, this.basis, this.voided);
  final int n;
  final String type, summary, effective, time, actor, basis;
  final bool voided;
}

/// An engineering change RevisionWorx records as reaching a unit, and where it stands on it (PROTOCOL.md section 6.4). The
/// phone shows it; it is settled in RevisionWorx.
class AssetChange {
  AssetChange(this.change, this.number, this.title, this.kind, this.required, this.state, this.since, this.documents);
  final String change, number, title, kind, state, since;
  final bool required;

  /// `(document number, from revision, to revision)`.
  final List<(String, String, String)> documents;

  /// Required, and neither verified nor not applicable.
  bool get outstanding => required && state != 'verified' && state != 'not-applicable';
}

/// A deviation (permission before the work) or concession (acceptance afterwards) that lets a unit differ from its
/// documents, and where it stands on the unit (PROTOCOL.md section 6.4). It is settled in RevisionWorx.
class AssetDeviation {
  AssetDeviation(this.deviation, this.number, this.kind, this.title, this.departure, this.temporary, this.until,
      this.state, this.since, this.documents);
  final String deviation, number, kind, title, departure, until, state, since;
  final bool temporary;

  /// `(document number, revision label)`: the revisions it departs from.
  final List<(String, String)> documents;

  /// The unit may differ from its documents as it says.
  bool get inEffect => state == 'in-effect';

  /// Temporary, still in effect, and past its end date ([today] is `YYYY-MM-DD`).
  bool overdue(String today) => temporary && inEffect && until.isNotEmpty && until.compareTo(today) < 0;
}

/// A unit built: from RevisionWorx's unit register (`source` is `revisionworx`), or a row of an asset register.
class Asset {
  Asset({
    required this.id,
    required this.aliases,
    required this.label,
    required this.cls,
    required this.name,
    required this.model,
    required this.partId,
    required this.projectId,
    required this.customer,
    required this.site,
    required this.location,
    required this.status,
    required this.identifiers,
    required this.parentId,
    required this.parentPosition,
    required this.standardNumber,
    required this.standardTitle,
    required this.documents,
    required this.components,
    required this.milestones,
    required this.history,
    required this.changes,
    required this.deviations,
    required this.notes,
    required this.source,
    required this.package,
  });

  /// From a checked catalog's asset in the version 2 shape ([assetView]).
  factory Asset.fromView(Map<String, Object?> v, PackageInfo package) {
    final parent = v['parent'] as Map<String, Object?>?;
    final standard = v['standard'] as Map<String, Object?>?;
    return Asset(
      id: v['id']! as String,
      aliases: (v['aliases']! as List).cast<String>(),
      label: v['label']! as String,
      cls: v['class']! as String,
      name: v['name']! as String,
      model: v['model']! as String,
      partId: v['part']! as String,
      projectId: v['project']! as String,
      customer: v['customer']! as String,
      site: v['site']! as String,
      location: v['location']! as String,
      status: v['status']! as String,
      identifiers: [
        for (final i in (v['identifiers']! as List).cast<Map<String, Object?>>())
          AssetIdentifier(i['scheme']! as String, i['issuer']! as String, i['value']! as String, i['active']! as bool),
      ],
      parentId: parent == null ? '' : parent['asset']! as String,
      parentPosition: parent == null ? '' : parent['position']! as String,
      standardNumber: standard == null ? '' : standard['number']! as String,
      standardTitle: standard == null ? '' : standard['title']! as String,
      documents: [
        for (final d in (v['documents']! as List).cast<Map<String, Object?>>())
          AssetDocument(d['document']! as String, d['revision']! as String, d['source']! as String, d['basis']! as String),
      ],
      components: [
        for (final c in (v['components']! as List).cast<Map<String, Object?>>())
          AssetComponent(c['position']! as String, c['part']! as String, c['number']! as String, c['asset']! as String,
              c['serial']! as String, c['lot']! as String, c['since']! as String, c['basis']! as String),
      ],
      milestones: (v['milestones']! as Map).cast<String, String>(),
      history: [
        for (final h in (v['history']! as List).cast<Map<String, Object?>>())
          AssetEvent(h['n']! as int, h['type']! as String, h['summary']! as String, h['effective']! as String,
              h['time']! as String, h['actor']! as String, h['basis']! as String, h['voided']! as bool),
      ],
      changes: [
        for (final c in (v['changes']! as List).cast<Map<String, Object?>>())
          AssetChange(
            c['change']! as String,
            c['number']! as String,
            c['title']! as String,
            c['kind']! as String,
            c['required']! as bool,
            c['state']! as String,
            c['since']! as String,
            [
              for (final d in (c['documents']! as List).cast<Map<String, Object?>>())
                (d['number']! as String, d['from']! as String, d['to']! as String),
            ],
          ),
      ],
      deviations: [
        for (final d in (v['deviations']! as List).cast<Map<String, Object?>>())
          AssetDeviation(
            d['deviation']! as String,
            d['number']! as String,
            d['kind']! as String,
            d['title']! as String,
            d['departure']! as String,
            d['temporary']! as bool,
            d['until']! as String,
            d['state']! as String,
            d['since']! as String,
            [
              for (final r in (d['documents']! as List).cast<Map<String, Object?>>())
                (r['number']! as String, r['revision']! as String),
            ],
          ),
      ],
      notes: v['notes']! as String,
      source: v['source']! as String,
      package: package,
    );
  }

  final String id, label, cls, name, model, partId, projectId, customer, site, location, status, notes, source;
  final String parentId, parentPosition, standardNumber, standardTitle;
  final List<String> aliases;
  final List<AssetIdentifier> identifiers;
  final List<AssetDocument> documents;
  final List<AssetComponent> components;
  final Map<String, String> milestones;
  final List<AssetEvent> history;

  /// Engineering changes that reach it, outstanding ones first, as RevisionWorx sent them.
  final List<AssetChange> changes;

  /// Deviations and concessions that cover it, those in effect first, as RevisionWorx sent them.
  final List<AssetDeviation> deviations;
  final PackageInfo package;

  /// Deviations and concessions in effect: where the unit may differ from its documents.
  List<AssetDeviation> get deviationsInEffect => [for (final d in deviations) if (d.inEffect) d];

  /// Required changes it hasn't finished.
  List<AssetChange> get outstandingChanges => [for (final c in changes) if (c.outstanding) c];

  String _current(String scheme) {
    for (final i in identifiers) {
      if (i.scheme == scheme && i.active) return i.value;
    }
    return '';
  }

  String get tag => _current('tag');
  String get serial => _current('serial');
  String get built => milestones['built'] ?? '';

  /// Whether this comes from RevisionWorx's unit register (rather than a row of an asset register).
  bool get isUnit => source == 'revisionworx';

  /// The revisions this unit's record names, as built or since modified.
  List<String> get asBuilt => [for (final d in documents) if (d.applies) d.revisionId];

  /// The code its permanent label carries: its id when it is a unit in the register, else its label.
  String get labelCode => id.startsWith('unt_') ? id : label;
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

  /// Earlier ids of assets (a unit's `ast_` id from an asset register row): alias -> asset id.
  final Map<String, String> assetAliases = {};
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
    for (final v in assetsView(c)) {
      final a = Asset.fromView(v, pkg);
      assets[a.id] = a;
      for (final x in a.aliases) {
        assetAliases[x] = a.id;
        assets.remove(x); // an older package's register row for the same unit
      }
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

  /// An asset by its id or by an earlier id (records made against a unit before it joined the unit register).
  Asset? asset(String id) => assets[id] ?? assets[assetAliases[id] ?? ''];

  /// Units fitted in [a], by position.
  List<Asset> fittedIn(Asset a) => [for (final x in assets.values) if (x.parentId == a.id) x]
    ..sort((x, y) => _naturalCompare(x.parentPosition, y.parentPosition));
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
      final s = [
        codeScore(a.label, 1000, 700, 300),
        for (final i in a.identifiers) codeScore(i.value, i.active ? 1000 : 600, i.active ? 700 : 400, i.active ? 300 : 150),
        codeScore(a.model, 500, 300, 120),
        textScore(a.name, 40),
        textScore(a.location, 20),
        textScore(a.customer, 20),
        textScore(a.site, 20),
      ].reduce((x, y) => x > y ? x : y);
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
