// SPDX-License-Identifier: GPL-3.0-or-later
// The on-device store (docs/ARCHITECTURE.md, ADR-004). Everything is a file written once, under its final name
// only when complete:
//
//   device.json                      this copy's device id and signing key (never backed up or restored: section 9)
//   settings.json                    name and theme (the only file that is replaced)
//   objects/<aa>/<sha256>            drawings and photos, named by their content
//   packages/<package id>/           manifest.json and catalog.json of each installed package
//   events/<device>/<seq>.json       field records, canonical bytes
//   exported.json                    which photos have already gone out in a field log
//
// A package or field log is checked completely before anything from it is kept. Packages of the same series
// replace each other; field records are never removed.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'archive.dart';
import 'catalog.dart';
import 'events.dart';
import 'finding.dart';
import 'fxjson.dart' as fx;
import 'inspection.dart';
import 'sha256.dart';

class StoreError implements Exception {
  StoreError(this.message);
  final String message;
  @override
  String toString() => message;
}

class InstallResult {
  InstallResult(this.package, this.newEvents, this.newObjects, this.replaced);
  final PackageInfo package;
  final int newEvents, newObjects;
  final List<String> replaced;
}

class ImportResult {
  ImportResult(this.newEvents, this.knownEvents, this.newObjects);
  final int newEvents, knownEvents, newObjects;
}

Future<void> _writeAtomic(File f, List<int> data) async {
  await f.parent.create(recursive: true);
  final tmp = File('${f.path}.${newId('tmp')}.tmp');
  await tmp.writeAsBytes(data, flush: true);
  await tmp.rename(f.path);
}

class FieldStore {
  FieldStore(this.root);

  final Directory root;
  late String deviceId;

  /// This device's Ed25519 key (PROTOCOL.md section 12): every record it makes is signed with it.
  late SigningKey signingKey;
  Map<String, Object?> settings = {};
  final FieldLog log = FieldLog();
  Catalog catalog = Catalog();

  /// Set when field records couldn't be read: the store is then read-only for field work, and says why.
  String? fieldError;
  final List<String> warnings = [];

  Directory get _objects => Directory('${root.path}/objects');
  Directory get _packages => Directory('${root.path}/packages');
  Directory get _events => Directory('${root.path}/events');
  Directory get _tmp => Directory('${root.path}/tmp');

  String get userName => (settings['user'] as String?) ?? '';

  /// What this phone shows for enrolling it to someone's account: compare it with what the office sees.
  String get fingerprint => signingKey.fingerprint;
  String get theme => (settings['theme'] as String?) ?? 'modern_light';

  static Future<FieldStore> open(Directory root) async {
    final s = FieldStore(root);
    await s._open();
    return s;
  }

  Future<void> _open() async {
    await root.create(recursive: true);
    for (final d in [_objects, _packages, _events, _tmp]) {
      await d.create(recursive: true);
    }
    await for (final f in _tmp.list()) {
      try {
        await f.delete(recursive: true);
      } catch (_) {}
    }
    final dev = File('${root.path}/device.json');
    var m = <String, Object?>{};
    if (await dev.exists()) {
      m = fx.asMap(fx.parseBytes(await dev.readAsBytes()), 'device.json');
      deviceId = fx.asString(m['device'], 'device');
      if (!reDevice.hasMatch(deviceId)) throw StoreError('device.json is damaged');
    } else {
      deviceId = newId('dev');
      m = {'device': deviceId, 'created': utcNow()};
    }
    if (m['key'] == null) {
      // A new device, or one from before records were signed: it gets its key now and keeps its id. Records it made
      // before stay unsigned. This is the only time device.json is replaced.
      signingKey = SigningKey.generate();
      m = {...m, 'key': {'seed': toHex(signingKey.seed), 'public': signingKey.publicHex, 'created': utcNow()}};
      await _writeAtomic(dev, fx.encode(m));
    } else {
      signingKey = _keyFrom(m['key']);
    }
    final set = File('${root.path}/settings.json');
    if (await set.exists()) {
      try {
        settings = fx.asMap(fx.parseBytes(await set.readAsBytes()), 'settings');
      } catch (_) {
        settings = {};
        warnings.add('Settings were unreadable and were reset.');
      }
    }
    await _loadEvents();
    await reloadCatalog();
  }

  static SigningKey _keyFrom(Object? k) {
    const damaged = "device.json is damaged: this device's signing key can't be read";
    if (k is! Map || k['seed'] is! String || k['public'] is! String) throw StoreError(damaged);
    final seed = k['seed'] as String, public = k['public'] as String;
    if (!reKey.hasMatch(seed) || !reKey.hasMatch(public)) throw StoreError(damaged);
    final key = SigningKey.fromSeedHex(seed);
    if (key.publicHex != public) throw StoreError(damaged);
    return key;
  }

  Future<void> saveSettings(Map<String, Object?> changes) async {
    settings = {...settings, ...changes};
    await _writeAtomic(File('${root.path}/settings.json'), fx.encode(settings));
  }

  // ----------------------------------------------------------------------------------------------- events
  Future<void> _loadEvents() async {
    final batch = <Event>[];
    try {
      await for (final d in _events.list()) {
        if (d is! Directory) continue;
        final name = d.uri.pathSegments.where((x) => x.isNotEmpty).last;
        if (!reDevice.hasMatch(name)) continue;
        await for (final f in d.list()) {
          if (f is! File || !f.path.endsWith('.json') || f.uri.pathSegments.last.startsWith('.')) continue;
          // This store's own records were checked when they came in; their signatures aren't checked again here.
          final ev = Event.fromBytes(await f.readAsBytes(), checkSignature: false);
          if (ev.device != name || f.uri.pathSegments.last != '${ev.seq.toString().padLeft(10, '0')}.json') {
            throw EventError('${f.path} is in the wrong place');
          }
          batch.add(ev);
        }
      }
      log.importEvents(batch);
    } on EventError catch (e) {
      fieldError = 'Field records on this device could not be read (${e.message}). Nothing will be recorded '
          'until this is sorted out; drawings and parts still work.';
    }
  }

  Future<void> _persist(Event ev) async {
    final f = File('${_events.path}/${ev.device}/${ev.seq.toString().padLeft(10, '0')}.json');
    if (await f.exists()) {
      if (sha256Hex(await f.readAsBytes()) != sha256Hex(ev.raw)) {
        throw StoreError('record ${ev.seq} of ${ev.device} is already here with different content');
      }
      return;
    }
    await _writeAtomic(f, ev.raw);
  }

  /// Records a new event of this device on [entity]. Its dependencies are the entity's current heads.
  Future<Event> record(String type, String entity, Map<String, Object?> body) async {
    if (fieldError != null) throw StoreError(fieldError!);
    final stream = log.streams[deviceId] ?? const <String>[];
    final ev = Event.make(
      device: deviceId,
      seq: stream.length + 1,
      prev: stream.isEmpty ? '' : stream.last,
      actor: userName,
      type: type,
      entity: entity,
      deps: log.entityHeads(entity),
      body: body,
      signingKey: signingKey,
    );
    await _persist(ev);
    log.append(ev);
    return ev;
  }

  /// The events of [incoming] that are new here, in an order they can be added, once they are shown to fit with this
  /// device's and each new one's signature holds. Changes nothing; throws EventError otherwise.
  Future<List<Event>> _checkIncoming(List<Event> incoming) async {
    final scratch = FieldLog()
      ..events.addAll(log.events)
      ..streams.addAll({for (final e in log.streams.entries) e.key: List.of(e.value)})
      ..byEntity.addAll({for (final e in log.byEntity.entries) e.key: List.of(e.value)});
    final added = scratch.importEvents(incoming);
    final signed = [for (final e in added) if (e.version == 2) e];
    final flat = [for (final e in signed) ...[e.id, e.key, e.sig]];
    final bad = signed.length < inlineSignatureChecks ? firstBadSignature(flat) : await _checkElsewhere(flat);
    if (bad >= 0) signed[bad].checkSignature(); // throws, saying which record
    return added;
  }

  /// Up to this many new signatures are checked here; more, in another isolate. A phone checks a few milliseconds' worth
  /// per signature: a package bringing thousands of other phones' records would otherwise stop the app answering (and
  /// Android would offer to close it).
  static const int inlineSignatureChecks = 8;

  static Future<int> _checkElsewhere(List<String> flat) => Isolate.run(() => firstBadSignature(flat));

  Future<List<Event>> _importEvents(List<Event> events) async {
    if (fieldError != null && events.isNotEmpty) throw StoreError(fieldError!);
    final scratch = FieldLog()
      ..events.addAll(log.events)
      ..streams.addAll({for (final e in log.streams.entries) e.key: List.of(e.value)})
      ..byEntity.addAll({for (final e in log.byEntity.entries) e.key: List.of(e.value)});
    final added = scratch.importEvents(events); // all-or-nothing; throws before anything is written
    for (final ev in added) {
      await _persist(ev);
    }
    log.importEvents(added);
    return added;
  }

  // ---------------------------------------------------------------------------------------------- objects
  File objectFile(String sha) => File('${_objects.path}/${sha.substring(0, 2)}/$sha');
  Future<bool> hasObject(String sha) => objectFile(sha).exists();

  Future<bool> _putObjectFromArchive(FieldArchive a, String sha) async {
    final dest = objectFile(sha);
    if (await dest.exists()) return false;
    final tmp = File('${_tmp.path}/${newId('obj')}');
    await a.extractObject(sha, tmp);
    await dest.parent.create(recursive: true);
    await tmp.rename(dest.path);
    return true;
  }

  /// Copies a photo (or any file) into the store; returns (sha256, size).
  Future<(String, int)> addFile(File source) async {
    final tmp = File('${_tmp.path}/${newId('obj')}');
    final h = Sha256();
    final sink = tmp.openWrite();
    await for (final chunk in source.openRead()) {
      h.add(chunk);
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();
    final sha = h.hexDigest();
    final dest = objectFile(sha);
    if (await dest.exists()) {
      await tmp.delete();
    } else {
      await dest.parent.create(recursive: true);
      await tmp.rename(dest.path);
    }
    return (sha, h.length);
  }

  // --------------------------------------------------------------------------------------------- packages
  Future<List<(PackageInfo, Map<String, Object?>)>> _installed() async {
    final out = <(PackageInfo, Map<String, Object?>)>[];
    await for (final d in _packages.list()) {
      if (d is! Directory) continue;
      final id = d.uri.pathSegments.where((x) => x.isNotEmpty).last;
      if (!reArchiveId.hasMatch(id)) continue;
      try {
        final mb = await File('${d.path}/manifest.json').readAsBytes();
        final m = checkManifest(fx.parseCanonical(mb));
        final cb = await File('${d.path}/catalog.json').readAsBytes();
        final cmeta = fx.asMap(m['catalog'], 'catalog');
        if (sha256Hex(cb) != cmeta['sha256']) throw StoreError('catalog changed on disk');
        final c = fx.asMap(fx.parseCanonical(cb), 'catalog');
        checkCatalog(c);
        out.add((_info(m, sha256Hex(mb)), c));
      } catch (e) {
        warnings.add('Package $id could not be read and was left out ($e).');
      }
    }
    out.sort((a, b) => a.$1.created.compareTo(b.$1.created));
    // Only the newest package of each series counts (an interrupted replacement can leave two).
    final newest = <String, String>{};
    for (final (p, _) in out) {
      newest[p.series.isEmpty ? p.id : p.series] = p.id;
    }
    return [for (final x in out) if (newest[x.$1.series.isEmpty ? x.$1.id : x.$1.series] == x.$1.id) x];
  }

  PackageInfo _info(Map<String, Object?> m, String digest) => PackageInfo(
        id: m['id']! as String,
        title: m['title']! as String,
        series: m['series']! as String,
        created: m['created']! as String,
        digest: digest,
        source: fx.asMap(m['source'], 'source'),
        notices: (m['notices']! as List).cast<String>(),
        createdBy: fx.asMap(m['created_by'], 'created_by'),
      );

  Future<void> reloadCatalog() async {
    final c = Catalog();
    for (final (p, cat) in await _installed()) {
      c.add(p, cat);
    }
    catalog = c;
  }

  /// Checks and installs a package file. Nothing is kept unless everything in it is intact and its field records
  /// fit with this device's.
  Future<InstallResult> installPackage(File file) async {
    final a = await FieldArchive.open(file, checkSignatures: false); // the new records' are checked below
    try {
      if (a.kind != 'package') throw StoreError('This is a field log, not a package. Use "Import field log".');
      try {
        checkCatalog(a.catalog);
      } on CatalogError catch (e) {
        throw StoreError('The package catalog is not usable: ${e.message}');
      }
      final existing = await _installed();
      for (final (p, _) in existing) {
        if (p.id == a.id) throw StoreError('This package is already installed.');
        if (p.series.isNotEmpty && p.series == a.series && p.created.compareTo(a.created) > 0) {
          throw StoreError('A newer package of the same series (${p.title}, ${p.created.substring(0, 10)}) is '
              'already installed.');
        }
      }
      // Field records first, all-or-nothing, so a package whose records don't fit changes nothing.
      final List<Event> fresh;
      try {
        fresh = await _checkIncoming(a.events);
      } on EventError catch (e) {
        throw StoreError("This package's field records can't be used: ${e.message}");
      }
      var newObjects = 0;
      for (final sha in a.objects.keys) {
        if (await _putObjectFromArchive(a, sha)) newObjects++;
      }
      final added = await _importEvents(fresh);
      final stage = Directory('${_tmp.path}/${a.id}');
      await stage.create(recursive: true);
      await File('${stage.path}/manifest.json').writeAsBytes(a.manifestBytes, flush: true);
      await File('${stage.path}/catalog.json').writeAsBytes(fx.encode(a.catalog), flush: true);
      await stage.rename('${_packages.path}/${a.id}');
      final replaced = <String>[];
      for (final (p, _) in existing) {
        if (p.series.isNotEmpty && p.series == a.series) {
          await Directory('${_packages.path}/${p.id}').delete(recursive: true);
          replaced.add(p.title);
        }
      }
      await reloadCatalog();
      await collectGarbage();
      return InstallResult(_info(a.manifest, a.digest), added.length, newObjects, replaced);
    } finally {
      await a.close();
    }
  }

  Future<void> removePackage(String id) async {
    final d = Directory('${_packages.path}/$id');
    if (await d.exists()) await d.delete(recursive: true);
    await reloadCatalog();
    await collectGarbage();
  }

  /// Deletes files no installed package and no field record refers to.
  Future<int> collectGarbage() async {
    final keep = <String>{};
    for (final (_, c) in await _installed()) {
      for (final d in (c['documents']! as List).cast<Map<String, Object?>>()) {
        for (final r in (d['revisions']! as List).cast<Map<String, Object?>>()) {
          final rend = r['rendition'] as Map<String, Object?>?;
          if (rend != null) keep.add(rend['object']! as String);
        }
      }
    }
    for (final e in log.events.values) {
      final o = e.body['object'];
      if (e.type.endsWith('.attach') && o is String) keep.add(o);
    }
    var removed = 0;
    await for (final d in _objects.list()) {
      if (d is! Directory) continue;
      await for (final f in d.list()) {
        final name = f.uri.pathSegments.last;
        if (f is File && reHash.hasMatch(name) && !keep.contains(name)) {
          await f.delete();
          removed++;
        }
      }
    }
    return removed;
  }

  // ------------------------------------------------------------------------------------------- field logs
  Future<(Set<String>, int)> _exported() async {
    final f = File('${root.path}/exported.json');
    if (!await f.exists()) return (<String>{}, 0);
    try {
      final m = fx.asMap(fx.parseBytes(await f.readAsBytes()), 'exported');
      return (fx.asList(m['objects'], 'objects').cast<String>().toSet(), fx.asInt(m['own_seq'], 'own_seq'));
    } catch (_) {
      return (<String>{}, 0);
    }
  }

  /// How many of this device's records haven't gone out in a field log yet.
  Future<int> unsentCount() async {
    final (_, seq) = await _exported();
    final own = log.streams[deviceId]?.length ?? 0;
    return own > seq ? own - seq : 0;
  }

  /// Writes every field record this device knows, with the photos not sent before (or all of them), to a new
  /// field log in [dir]. Returns the file.
  Future<File> exportFieldLog(Directory dir, {bool allPhotos = false, String tool = 'FieldWorx'}) async {
    if (fieldError != null) throw StoreError(fieldError!);
    if (log.length == 0) throw StoreError('There are no field records on this device yet.');
    final sent = allPhotos ? <String>{} : (await _exported()).$1;
    final objects = <ObjectSource>[];
    final included = <String>{};
    for (final e in log.events.values) {
      final b = e.body;
      final o = b['object'];
      if (!e.type.endsWith('.attach') || o is! String || included.contains(o) || sent.contains(o)) continue;
      final f = objectFile(o);
      if (!await f.exists()) continue;
      final media = (b['media_type'] as String?) ?? 'application/octet-stream';
      objects.add(ObjectSource.file(o, await f.length(), reMedia.hasMatch(media) ? media : 'application/octet-stream', f));
      included.add(o);
    }
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    await dir.create(recursive: true);
    final out = File('${dir.path}/FieldWorx-${deviceId.substring(4, 10)}-$stamp.fieldlog');
    await writeArchive(
      out,
      kind: 'fieldlog',
      archiveId: newId('flg'),
      title: 'Field records from ${userName.isEmpty ? 'a device' : userName}',
      created: utcNow(),
      createdBy: {'device': deviceId, 'key': signingKey.publicHex, 'user': userName, 'tool': tool},
      events: log.ordered(),
      objects: objects,
    );
    final all = {...(await _exported()).$1, ...included};
    await _writeAtomic(File('${root.path}/exported.json'),
        fx.encode({'objects': all.toList()..sort(), 'own_seq': log.streams[deviceId]?.length ?? 0}));
    return out;
  }

  /// Brings in a field log (from another device, or one written here earlier).
  Future<ImportResult> importFieldLog(File file) async {
    final a = await FieldArchive.open(file, checkSignatures: false); // the new records' are checked below
    try {
      if (a.kind != 'fieldlog') throw StoreError('This is a package, not a field log. Use "Add package".');
      final known = a.events.where((e) => log.contains(e.id)).length;
      final List<Event> fresh;
      try {
        fresh = await _checkIncoming(a.events);
      } on EventError catch (e) {
        throw StoreError("These field records can't be used: ${e.message}");
      }
      var newObjects = 0;
      for (final sha in a.objects.keys) {
        if (await _putObjectFromArchive(a, sha)) newObjects++;
      }
      final added = await _importEvents(fresh);
      return ImportResult(added.length, known, newObjects);
    } finally {
      await a.close();
    }
  }

  // ------------------------------------------------------------------------------------------ inspections
  List<Map<String, Object?>> inspections() =>
      [for (final e in inspectionEntities(log)) reduceInspection(log, e)];

  Map<String, Object?> inspection(String entity) => reduceInspection(log, entity);

  Future<String> startInspection(TemplateEntry t, {required String title, Map<String, String>? subject}) async {
    final entity = newId('ins');
    await record('inspection.start', entity, {
      'template': t.template,
      'title': title,
      'subject': subject ?? {'kind': '', 'id': '', 'label': ''},
      'package': t.package.id,
    });
    return entity;
  }

  // --------------------------------------------------------------------------------------------- findings
  /// Every finding this phone holds (docs/PROTOCOL.md section 11), each reduced.
  List<Map<String, Object?>> findings() => [for (final e in findingEntities(log)) reduceFinding(log, e)];

  Map<String, Object?> finding(String entity) => reduceFinding(log, entity);

  /// Records a new finding: what was found or changed on a unit, for someone in the office to accept into RevisionWorx.
  /// [body] is a `finding.record` body; it is checked first, so a phone never records one the office can't read.
  Future<String> recordFinding(Map<String, Object?> body) async {
    checkFindingRecord(body);
    final entity = newId('fnd');
    await record('finding.record', entity, body);
    return entity;
  }

  String describe() => jsonEncode({'device': deviceId, 'events': log.length, 'packages': catalog.packages.length});
}
