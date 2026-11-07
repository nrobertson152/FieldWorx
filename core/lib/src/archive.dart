// SPDX-License-Identifier: GPL-3.0-or-later
// FieldWorx archives (docs/PROTOCOL.md section 3): packages and field logs. Same rules as
// bridge/fieldworx_bridge/archive.py. Every listed member is checked before anything from the archive is used.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'events.dart';
import 'fxjson.dart' as fx;
import 'sha256.dart';
import 'zip.dart';

const Map<String, String> archiveMime = {
  'package': 'application/x-fieldworx-package',
  'fieldlog': 'application/x-fieldworx-fieldlog',
};
const String archiveFormat = 'fieldworx.archive';
const int archiveVersion = 1;
const int maxManifest = 16 * 1024 * 1024;
const int maxCatalog = 256 * 1024 * 1024;
const int maxObject = 2 * 1024 * 1024 * 1024;
const int maxMembers = 200000;
final RegExp reArchiveId = RegExp(r'^(pkg|flg)_[0-9a-f]{32}$');
final RegExp reMedia = RegExp(r'^[a-z0-9][a-z0-9.+\-]*/[a-z0-9][a-z0-9.+\-]*$');
const Set<String> storedMedia = {'application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'};
const Set<String> manifestKeys = {
  'format', 'version', 'kind', 'id', 'title', 'series', 'created', 'created_by', 'source', 'catalog', 'events', //
  'objects', 'notices',
};

class ArchiveError implements Exception {
  ArchiveError(this.message);
  final String message;
  @override
  String toString() => message;
}

class ObjectInfo {
  const ObjectInfo(this.sha256, this.size, this.mediaType);
  final String sha256;
  final int size;
  final String mediaType;
}

bool _memberNameOk(String name) {
  if (name.isEmpty || utf8.encode(name).length > 255 || name.startsWith('/') || name.contains(r'\') ||
      name.contains(':')) {
    return false;
  }
  return name.split('/').every((p) => p.isNotEmpty && p != '.' && p != '..');
}

bool _sha(Object? s) => s is String && reHash.hasMatch(s);
bool _size(Object? n, int limit) => n is int && n >= 0 && n <= limit;

Map<String, Object?> checkManifest(Object? m) {
  if (m is! Map || m.length != manifestKeys.length || !m.keys.every(manifestKeys.contains)) {
    throw ArchiveError('manifest fields wrong');
  }
  if (m['format'] != archiveFormat) throw ArchiveError('not a FieldWorx archive');
  if (m['version'] != archiveVersion) {
    throw ArchiveError('archive version ${m['version']} is newer than this program understands; update it');
  }
  final kind = m['kind'];
  if (!archiveMime.containsKey(kind)) throw ArchiveError('unknown archive kind');
  final id = m['id'];
  if (id is! String || !reArchiveId.hasMatch(id) || id.substring(0, 3) != (kind == 'package' ? 'pkg' : 'flg')) {
    throw ArchiveError('archive id malformed');
  }
  for (final (k, limit) in [('title', 200), ('series', 128), ('created', 40)]) {
    final v = m[k];
    if (v is! String || cpLen(v) > limit) throw ArchiveError('$k malformed');
  }
  if (!reTime.hasMatch(m['created']! as String)) throw ArchiveError('created must be a UTC time');
  for (final k in ['created_by', 'source']) {
    final v = m[k];
    if (v is! Map || !v.values.every((x) => x is String && cpLen(x) <= 200)) {
      throw ArchiveError('$k must be an object of short texts');
    }
  }
  if (kind == 'package') {
    final c = m['catalog'];
    if (c is! Map || c.length != 2 || !_sha(c['sha256']) || !_size(c['size'], maxCatalog)) {
      throw ArchiveError('a package must describe its catalog');
    }
  } else if (m['catalog'] != null) {
    throw ArchiveError('a field log has no catalog');
  }
  final evs = m['events'], objs = m['objects'], notes = m['notices'];
  if (evs is! List || objs is! List || notes is! List) throw ArchiveError('events, objects and notices must be lists');
  if (evs.length + objs.length > maxMembers) throw ArchiveError('too many members');
  final ids = <String>{};
  for (final e in evs) {
    if (e is! Map || e.length != 2 || !_sha(e['id']) || !_size(e['size'], maxEventBytes)) {
      throw ArchiveError('event entry malformed');
    }
    if (!ids.add(e['id']! as String)) throw ArchiveError('an event is listed twice');
  }
  String? last;
  for (final o in objs) {
    if (o is! Map || o.length != 3 || !_sha(o['sha256']) || !_size(o['size'], maxObject)) {
      throw ArchiveError('object entry malformed');
    }
    final media = o['media_type'];
    if (media is! String || !reMedia.hasMatch(media)) throw ArchiveError('object entry malformed');
    final sha = o['sha256']! as String;
    if (last != null && sha.compareTo(last) <= 0) {
      throw ArchiveError(sha == last ? 'an object is listed twice' : 'objects must be listed in hash order');
    }
    last = sha;
  }
  if (!notes.every((n) => n is String && cpLen(n) <= 1000)) throw ArchiveError('notices must be short texts');
  return fx.asMap(m, 'manifest');
}

/// An archive that has been opened and checked. Objects stay in the file until [extractObject].
class FieldArchive {
  FieldArchive._(this.kind, this.manifest, this.manifestBytes, this.catalog, this.events, this.objects, this._zip);

  final String kind;
  final Map<String, Object?> manifest;
  final Uint8List manifestBytes;
  final Map<String, Object?>? catalog;
  final List<Event> events;
  final Map<String, ObjectInfo> objects;
  final ZipReader _zip;

  String get id => manifest['id']! as String;
  String get title => manifest['title']! as String;
  String get series => manifest['series']! as String;
  String get created => manifest['created']! as String;
  List<String> get notices => (manifest['notices']! as List).cast<String>();
  Map<String, Object?> get source => fx.asMap(manifest['source'], 'source');
  Map<String, Object?> get createdBy => fx.asMap(manifest['created_by'], 'created_by');

  /// SHA-256 of the manifest: identifies this exact archive.
  String get digest => sha256Hex(manifestBytes);

  Future<void> close() => _zip.close();

  /// Writes object [sha] to [dest] while checking its size and SHA-256; [dest] is deleted on any mismatch.
  Future<void> extractObject(String sha, File dest) async {
    final info = objects[sha];
    final entry = _zip.byName['objects/$sha'];
    if (info == null || entry == null) throw ArchiveError('file ${sha.substring(0, 12)} is not in this archive');
    final sink = await dest.open(mode: FileMode.writeOnly);
    final h = Sha256();
    try {
      await _zip.extract(entry, (chunk) async {
        h.add(chunk);
        await sink.writeFrom(chunk);
      });
      await sink.flush();
    } catch (e) {
      await sink.close();
      if (await dest.exists()) await dest.delete();
      if (e is ZipError) throw ArchiveError('file ${sha.substring(0, 12)} is damaged: ${e.message}');
      rethrow;
    }
    await sink.close();
    if (h.hexDigest() != sha || h.length != info.size) {
      await dest.delete();
      throw ArchiveError('file ${sha.substring(0, 12)} is damaged');
    }
  }

  /// Reads a small object fully (checked).
  Future<Uint8List> readObject(String sha, {int limit = 64 * 1024 * 1024}) async {
    final info = objects[sha];
    final entry = _zip.byName['objects/$sha'];
    if (info == null || entry == null) throw ArchiveError('file ${sha.substring(0, 12)} is not in this archive');
    if (info.size > limit) throw ArchiveError('file ${sha.substring(0, 12)} is too large to read at once');
    final data = await _zip.readBytes(entry, limit: limit);
    if (sha256Hex(data) != sha) throw ArchiveError('file ${sha.substring(0, 12)} is damaged');
    return data;
  }

  /// Opens [file] and checks everything except object contents (pass [verifyObjects] to hash those too). Every
  /// event's id is checked against its bytes; [checkSignatures] false leaves version 2 signatures to the caller, which
  /// checks those of the events new to it (`Event.checkSignature`), not a whole history it already has.
  static Future<FieldArchive> open(File file, {bool verifyObjects = false, bool checkSignatures = true}) async {
    final ZipReader z;
    try {
      z = await ZipReader.open(file);
    } on ZipError catch (e) {
      throw ArchiveError('not a readable FieldWorx file: ${e.message}');
    } on FileSystemException catch (e) {
      throw ArchiveError('cannot read the file: ${e.message}');
    }
    try {
      return await _read(z, verifyObjects, checkSignatures);
    } catch (e) {
      await z.close();
      if (e is ZipError) throw ArchiveError('damaged FieldWorx file: ${e.message}');
      if (e is FileSystemException) throw ArchiveError('cannot read the file: ${e.message}');
      rethrow;
    }
  }

  static Future<Uint8List> _exact(ZipReader z, ZipEntry e, int size, int limit) async {
    if (e.size != size || size > limit) throw ArchiveError('${e.name} has the wrong size');
    return z.readBytes(e, limit: limit);
  }

  static Future<FieldArchive> _read(ZipReader z, bool verifyObjects, bool checkSignatures) async {
    final entries = z.entries;
    if (entries.length > maxMembers + 3) throw ArchiveError('too many members');
    final names = <String, ZipEntry>{};
    for (final e in entries) {
      if (!_memberNameOk(e.name)) throw ArchiveError("member name '${e.name}' is not allowed");
      if (names.containsKey(e.name)) throw ArchiveError('member ${e.name} appears twice');
      names[e.name] = e;
    }
    if (entries.isEmpty || entries.first.name != 'mimetype' || entries.first.method != 0) {
      throw ArchiveError('not a FieldWorx file (no mimetype first)');
    }
    final mime = latin1.decode(await _exact(z, entries.first, entries.first.size, 100));
    String? kind;
    archiveMime.forEach((k, v) {
      if (v == mime) kind = k;
    });
    if (kind == null) throw ArchiveError('not a FieldWorx file');
    final mi = names['manifest.json'];
    if (mi == null) throw ArchiveError('manifest missing');
    final mbytes = await _exact(z, mi, mi.size, maxManifest);
    final Object? mraw;
    try {
      mraw = fx.parseCanonical(mbytes);
    } on fx.FxJsonError catch (e) {
      throw ArchiveError('manifest unreadable: ${e.message}');
    }
    final manifest = checkManifest(mraw);
    if (manifest['kind'] != kind) throw ArchiveError('mimetype and manifest disagree');

    Map<String, Object?>? catalog;
    if (kind == 'package') {
      final c = fx.asMap(manifest['catalog'], 'catalog');
      final ci = names['catalog.json'];
      if (ci == null) throw ArchiveError('catalog missing');
      final cbytes = await _exact(z, ci, c['size']! as int, maxCatalog);
      if (sha256Hex(cbytes) != c['sha256']) throw ArchiveError('catalog does not match the manifest');
      try {
        catalog = fx.asMap(fx.parseCanonical(cbytes), 'catalog');
      } on fx.FxJsonError catch (e) {
        throw ArchiveError('catalog unreadable: ${e.message}');
      }
    }

    final evs = <Event>[];
    for (final e in (manifest['events']! as List).cast<Map<Object?, Object?>>()) {
      final id = e['id']! as String;
      final ei = names['events/$id'];
      if (ei == null) throw ArchiveError('event ${id.substring(0, 12)} missing');
      final raw = await _exact(z, ei, e['size']! as int, maxEventBytes);
      try {
        evs.add(Event.fromBytes(raw, expectedId: id, checkSignature: checkSignatures));
      } on EventError catch (err) {
        throw ArchiveError('event ${id.substring(0, 12)}: ${err.message}');
      }
    }

    final objects = <String, ObjectInfo>{};
    for (final o in (manifest['objects']! as List).cast<Map<Object?, Object?>>()) {
      final sha = o['sha256']! as String, size = o['size']! as int;
      final oi = names['objects/$sha'];
      if (oi == null) throw ArchiveError('file ${sha.substring(0, 12)} missing');
      if (oi.size != size) throw ArchiveError('file ${sha.substring(0, 12)} has the wrong size');
      if (verifyObjects) {
        final h = Sha256();
        await z.extract(oi, h.add);
        if (h.hexDigest() != sha) throw ArchiveError('file ${sha.substring(0, 12)} is damaged');
      }
      objects[sha] = ObjectInfo(sha, size, o['media_type']! as String);
    }
    return FieldArchive._(kind!, manifest, mbytes, catalog, evs, objects, z);
  }
}

/// Where a writer gets an object's bytes from.
class ObjectSource {
  ObjectSource.file(this.sha256, this.size, this.mediaType, File this.file) : bytes = null;
  ObjectSource.bytes(Uint8List this.bytes, this.mediaType)
      : sha256 = sha256Hex(bytes),
        size = bytes.length,
        file = null;

  final String sha256;
  final int size;
  final String mediaType;
  final File? file;
  final Uint8List? bytes;
}

/// Writes a field log (or, for tests and tools, a package) all-or-nothing: a temporary file next to [out] is
/// renamed into place only when complete. Returns the manifest.
Future<Map<String, Object?>> writeArchive(
  File out, {
  required String kind,
  required String archiveId,
  required String title,
  required String created,
  required Map<String, String> createdBy,
  Map<String, String> source = const {},
  String series = '',
  Map<String, Object?>? catalog,
  List<Event> events = const [],
  List<ObjectSource> objects = const [],
  List<String> notices = const [],
}) async {
  final objs = <String, ObjectSource>{for (final o in objects) o.sha256: o};
  final shas = objs.keys.toList()..sort();
  final cbytes = catalog == null ? null : fx.encode(catalog);
  final manifest = <String, Object?>{
    'format': archiveFormat,
    'version': archiveVersion,
    'kind': kind,
    'id': archiveId,
    'title': title,
    'series': series,
    'created': created,
    'created_by': createdBy,
    'source': source,
    'catalog': cbytes == null ? null : {'sha256': sha256Hex(cbytes), 'size': cbytes.length},
    'events': [
      for (final e in events) {'id': e.id, 'size': e.raw.length},
    ],
    'objects': [
      for (final s in shas) {'sha256': s, 'size': objs[s]!.size, 'media_type': objs[s]!.mediaType},
    ],
    'notices': notices,
  };
  checkManifest(manifest);
  final tmp = File('${out.parent.path}/.${out.uri.pathSegments.last}.${newId('tmp')}.tmp');
  final w = await ZipWriter.create(tmp);
  try {
    await w.addBytes('mimetype', ascii.encode(archiveMime[kind]!), deflate: false);
    await w.addBytes('manifest.json', fx.encode(manifest), deflate: true);
    if (cbytes != null) await w.addBytes('catalog.json', cbytes, deflate: true);
    for (final e in events) {
      await w.addBytes('events/${e.id}', e.raw, deflate: true);
    }
    for (final s in shas) {
      final o = objs[s]!;
      final deflate = !storedMedia.contains(o.mediaType);
      if (o.bytes != null) {
        await w.addBytes('objects/$s', o.bytes!, deflate: deflate);
      } else {
        final h = Sha256();
        await w.addStream('objects/$s', o.file!.openRead().map((c) {
          h.add(c);
          return c;
        }), deflate: deflate);
        if (h.hexDigest() != s) throw ArchiveError('a file changed while it was being written');
      }
    }
    await w.close();
  } catch (_) {
    await w.abandon();
    if (await tmp.exists()) await tmp.delete();
    rethrow;
  }
  if (await out.exists()) await out.delete();
  await tmp.rename(out.path);
  return manifest;
}
