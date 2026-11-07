// SPDX-License-Identifier: GPL-3.0-or-later
// Field events (docs/PROTOCOL.md sections 4 and 12): the same rules as bridge/fieldworx_bridge/events.py, checked by
// spec/vectors/envelopes.json, spec/vectors/fieldlog.json and spec/vectors/signatures.json.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'ed25519.dart' as ed;
import 'fxjson.dart' as fx;
import 'sha256.dart';

const String eventDomain = 'event/v1';
const String eventDomainV2 = 'event/v2';
const String signatureDomain = 'fieldworx/event-signature/v1\u0000'; // signed: this, then the id as 64 hex digits
const String fingerprintDomain = 'fieldworx/key-fingerprint/v1\u0000';
const int maxEventBytes = 256 * 1024;
const int maxDeps = 64;
const Set<String> envelopeKeys = {'v', 'device', 'seq', 'prev', 'time', 'actor', 'type', 'entity', 'deps', 'body'};
const Set<String> envelopeKeysV2 = {...envelopeKeys, 'key', 'sig'};

final RegExp reDevice = RegExp(r'^dev_[0-9a-f]{32}$');
final RegExp reEntity = RegExp(r'^[a-z]{3}_[0-9a-f]{32}$');
final RegExp reHash = RegExp(r'^[0-9a-f]{64}$');
final RegExp reTime = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$');
final RegExp reType = RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$');
final RegExp reKey = RegExp(r'^[0-9a-f]{64}$');
final RegExp reSig = RegExp(r'^[0-9a-f]{128}$');

class EventError implements Exception {
  EventError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A device has two different records with one sequence number: its history was forked.
class ForkError extends EventError {
  ForkError(super.message);
}

/// A batch continues a history this copy does not have yet.
class MissingHistory extends EventError {
  MissingHistory(super.message);
}

final Random _rng = Random.secure();

/// `<prefix>_<32 random hex>`, as RevisionWorx makes its ids.
String newId(String prefix) {
  if (!RegExp(r'^[a-z]{3}$').hasMatch(prefix)) throw ArgumentError('id prefixes are three lowercase letters');
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  return '${prefix}_${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';
}

String utcNow([DateTime? t]) {
  final d = (t ?? DateTime.now()).toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:${two(d.minute)}:'
      '${two(d.second)}.${d.millisecond.toString().padLeft(3, '0')}Z';
}

/// What a phone shows and a person compares (section 12.1): the first 8 bytes of SHA-256 of the domain and the public
/// key, as 16 uppercase hex digits in four groups joined by `-`.
String keyFingerprint(String publicHex) {
  final h = sha256Hex([...utf8.encode(fingerprintDomain), ...ed.hexBytes(publicHex)]).substring(0, 16).toUpperCase();
  return [for (var i = 0; i < 16; i += 4) h.substring(i, i + 4)].join('-');
}

/// What a version 2 event's signature is over.
List<int> signatureMessage(String eventId) => utf8.encode(signatureDomain + eventId);

/// A device's Ed25519 key: the seed stays on the device; [public] goes in every record it signs.
class SigningKey {
  SigningKey(List<int> seed, [List<int>? public])
      : seed = Uint8List.fromList(seed),
        public = Uint8List.fromList(public ?? ed.publicKey(seed)) {
    if (this.seed.length != 32) throw ArgumentError('an Ed25519 seed is 32 bytes');
  }

  /// A new key from the platform's secure random generator.
  factory SigningKey.generate() => SigningKey(List<int>.generate(32, (_) => _rng.nextInt(256)));

  /// The key whose seed is [seed], 64 hex digits.
  factory SigningKey.fromSeedHex(String seed) => SigningKey(ed.hexBytes(seed));

  final Uint8List seed;
  final Uint8List public;

  String get publicHex => toHex(public);
  String get fingerprint => keyFingerprint(publicHex);

  Uint8List sign(List<int> message) => ed.sign(seed, message, public);
}

/// Length in code points, as Python counts it (limits are shared with the reference implementation).
int cpLen(String s) => s.runes.length;

bool _textOk(Object? s, int limit) =>
    s is String && cpLen(s) <= limit && !s.codeUnits.any((c) => c < 0x20 || c == 0x7f);

void checkEnvelope(Object? ev) {
  if (ev is! Map) throw EventError('an event is a JSON object');
  final v = ev['v'];
  if (v is! int || (v != 1 && v != 2)) throw EventError('event version $v is not supported by this FieldWorx; update it');
  final expected = v == 1 ? envelopeKeys : envelopeKeysV2;
  final keys = ev.keys.toSet();
  if (keys.length != expected.length || !keys.containsAll(expected)) {
    throw EventError('event fields wrong');
  }
  final device = ev['device'];
  if (device is! String || !reDevice.hasMatch(device)) throw EventError('device id malformed');
  final seq = ev['seq'];
  if (seq is! int || seq < 1) throw EventError('seq must be a positive integer');
  final prev = ev['prev'];
  if (seq == 1) {
    if (prev != '') throw EventError('the first event of a device has no prev');
  } else if (prev is! String || !reHash.hasMatch(prev)) {
    throw EventError("prev must be the id of the device's previous event");
  }
  final time = ev['time'];
  if (time is! String || !reTime.hasMatch(time)) throw EventError('time must be UTC, like 2026-11-06T21:42:00.123Z');
  if (!_textOk(ev['actor'], 200)) {
    throw EventError('actor must be text of at most 200 characters, without control characters');
  }
  final type = ev['type'];
  if (type is! String || cpLen(type) > 64 || !reType.hasMatch(type)) throw EventError('type malformed');
  final entity = ev['entity'];
  if (entity is! String || !reEntity.hasMatch(entity)) throw EventError('entity id malformed');
  final deps = ev['deps'];
  if (deps is! List || deps.length > maxDeps) throw EventError('deps must be a list of at most $maxDeps event ids');
  String? last;
  for (final d in deps) {
    if (d is! String || !reHash.hasMatch(d)) throw EventError('deps must be event ids');
    if (last != null && d.compareTo(last) <= 0) throw EventError('deps must be sorted and unique');
    last = d;
  }
  if (ev['body'] is! Map) throw EventError('body must be an object');
  if (v == 2) {
    // Whether the key is a point of the curve is the signature check's (it is costly, and a copy's own store skips it).
    final key = ev['key'];
    if (key is! String || !reKey.hasMatch(key)) {
      throw EventError("key must be the device's Ed25519 public key, 64 lowercase hex digits");
    }
    final sig = ev['sig'];
    if (sig is! String || !reSig.hasMatch(sig)) {
      throw EventError('sig must be an Ed25519 signature, 128 lowercase hex digits');
    }
  }
}

String _idOf(Map<String, Object?> data, List<int> raw) {
  if (data['v'] == 1) return fx.digestBytes(eventDomain, raw);
  return fx.digest(eventDomainV2, {for (final e in data.entries) if (e.key != 'sig') e.key: e.value});
}

class Event {
  Event._(this.id, this.raw, this.data);

  final String id;

  /// Canonical bytes, exactly as stored and exchanged.
  final Uint8List raw;
  final Map<String, Object?> data;

  String get device => data['device']! as String;
  int get seq => data['seq']! as int;
  String get prev => data['prev']! as String;
  String get type => data['type']! as String;
  String get entity => data['entity']! as String;
  String get time => data['time']! as String;
  String get actor => data['actor']! as String;
  List<String> get deps => (data['deps']! as List).cast<String>();
  Map<String, Object?> get body => fx.asMap(data['body'], 'body');
  int get version => data['v']! as int;

  /// The signing device's public key; empty for a version 1 event, which isn't signed.
  String get key => (data['key'] as String?) ?? '';
  String get sig => (data['sig'] as String?) ?? '';

  /// Whether a version 2 event's signature holds over its id with the key it carries. True for version 1.
  bool get signatureHolds =>
      version == 1 || ed.verify(ed.hexBytes(key), signatureMessage(id), ed.hexBytes(sig));

  void checkSignature() {
    if (!signatureHolds) {
      throw EventError("record ${id.substring(0, 12)} of device ${device.substring(0, 12)}: its signature doesn't hold. "
          "It was changed after it was signed, or wasn't signed with the key it carries");
    }
  }

  /// The id of a version 1 event from its canonical bytes.
  static String idOf(List<int> raw) => fx.digestBytes(eventDomain, raw);

  /// Checks canonical form, envelope, (if given) the id and, for a version 2 event, its signature. [checkSignature]
  /// false is for a copy's own store, which holds only events checked when they came in, and for an importer that
  /// checks the events new to it rather than a whole history it already has.
  static Event fromBytes(List<int> raw, {String? expectedId, bool checkSignature = true}) {
    if (raw.length > maxEventBytes) throw EventError('event larger than $maxEventBytes bytes');
    final Object? data;
    try {
      data = fx.parseCanonical(raw);
    } on fx.FxJsonError catch (e) {
      throw EventError('event is not canonical JSON: ${e.message}');
    }
    checkEnvelope(data);
    final map = fx.asMap(data, 'event');
    final id = _idOf(map, raw);
    if (expectedId != null && id != expectedId) {
      throw EventError('event content does not match its id ${expectedId.substring(0, 12)}');
    }
    final ev = Event._(id, Uint8List.fromList(raw), map);
    if (checkSignature) ev.checkSignature();
    return ev;
  }

  static Event make({
    required String device,
    required int seq,
    required String prev,
    required String actor,
    required String type,
    required String entity,
    required Iterable<String> deps,
    required Map<String, Object?> body,
    String? time,
    SigningKey? signingKey,
  }) {
    final sorted = deps.toSet().toList()..sort();
    final data = <String, Object?>{
      'v': 1,
      'device': device,
      'seq': seq,
      'prev': prev,
      'time': time ?? utcNow(),
      'actor': actor,
      'type': type,
      'entity': entity,
      'deps': sorted,
      'body': body,
    };
    if (signingKey != null) {
      data['v'] = 2;
      data['key'] = signingKey.publicHex;
      data['sig'] = '0' * 128;
      checkEnvelope(data);
      data['sig'] = toHex(signingKey.sign(signatureMessage(_idOf(data, const []))));
    }
    checkEnvelope(data);
    final raw = fx.encode(data);
    if (raw.length > maxEventBytes) throw EventError('event larger than $maxEventBytes bytes');
    return Event._(_idOf(data, raw), raw, data);
  }

  String get text => utf8.decode(raw);
}

/// Every event a copy knows, indexed by device stream and by entity.
class FieldLog {
  final Map<String, Event> events = {};
  final Map<String, List<String>> streams = {};
  final Map<String, List<String>> byEntity = {};

  int get length => events.length;
  bool contains(String id) => events.containsKey(id);

  Map<String, Map<String, Object?>> heads() {
    final keys = streams.keys.toList()..sort();
    return {
      for (final d in keys) d: {'seq': streams[d]!.length, 'id': streams[d]!.last},
    };
  }

  List<Event> entityEvents(String entity) => [for (final i in byEntity[entity] ?? const <String>[]) events[i]!];

  /// Events of [entity] that no other event of it depends on: what a new event should depend on.
  List<String> entityHeads(String entity) {
    final ids = byEntity[entity] ?? const <String>[];
    final depended = <String>{for (final i in ids) ...events[i]!.deps};
    return [for (final i in ids) if (!depended.contains(i)) i]..sort();
  }

  /// All events in an order in which another copy can import them.
  List<Event> ordered() => events.values.toList();

  String? _checkFits(Event ev) {
    final stream = streams[ev.device] ?? const <String>[];
    if (ev.seq <= stream.length) {
      if (stream[ev.seq - 1] != ev.id) {
        throw ForkError('device ${ev.device.substring(0, 12)} has two different records numbered ${ev.seq}; its '
            'history was forked (was the phone restored from a backup?). Nothing was imported');
      }
      return 'known';
    }
    if (ev.seq != stream.length + 1) return 'record ${stream.length + 1} of device ${ev.device.substring(0, 12)}';
    if (ev.seq > 1 && stream.last != ev.prev) {
      throw ForkError('device ${ev.device.substring(0, 12)}: record ${ev.seq} does not follow record ${ev.seq - 1} '
          'here; its history was forked. Nothing was imported');
    }
    if (ev.seq > 1) {
      // Section 12.2: one key per device, and no going back to unsigned records.
      final before = events[stream.last];
      if (before != null && before.version == 2 && ev.version == 1) {
        throw EventError("device ${ev.device.substring(0, 12)}: record ${ev.seq} isn't signed, but the records before "
            'it are. Nothing was imported');
      }
      if (before != null && before.version == 2 && ev.key != before.key) {
        throw EventError('device ${ev.device.substring(0, 12)} signs with two different keys (record ${ev.seq}): its '
            'store was damaged or copied. Nothing was imported');
      }
    }
    for (final d in ev.deps) {
      final dep = events[d];
      if (dep == null) return 'record ${d.substring(0, 12)} that record ${ev.id.substring(0, 12)} depends on';
      if (dep.entity != ev.entity) {
        throw EventError('record ${ev.id.substring(0, 12)} depends on a record of another entity');
      }
    }
    return null;
  }

  void _add(Event ev) {
    events[ev.id] = ev;
    (streams[ev.device] ??= []).add(ev.id);
    (byEntity[ev.entity] ??= []).add(ev.id);
  }

  /// Adds one event that must fit now (a copy's own new events).
  void append(Event ev) {
    final why = _checkFits(ev);
    if (why == 'known') return;
    if (why != null) throw MissingHistory('cannot add record ${ev.id.substring(0, 12)}: missing $why');
    _add(ev);
  }

  /// Adds a batch all-or-nothing; returns the events that were new, in the order they were added.
  List<Event> importEvents(Iterable<Event> batch) {
    final seen = <String, Event>{};
    for (final e in batch) {
      seen.putIfAbsent(e.id, () => e);
    }
    final scratch = FieldLog();
    scratch.events.addAll(events);
    streams.forEach((k, v) => scratch.streams[k] = List.of(v));
    byEntity.forEach((k, v) => scratch.byEntity[k] = List.of(v));
    var todo = seen.values.toList();
    final added = <Event>[];
    while (todo.isNotEmpty) {
      var progress = false;
      final waiting = <Event>[];
      final reasons = <String>[];
      for (final ev in todo) {
        final why = scratch._checkFits(ev);
        if (why == 'known') {
          progress = true;
        } else if (why == null) {
          scratch._add(ev);
          added.add(ev);
          progress = true;
        } else {
          waiting.add(ev);
          reasons.add(why);
        }
      }
      if (!progress) {
        throw MissingHistory('${waiting.length} record(s) continue a history this copy does not have (first '
            'missing: ${reasons.first}). Import the earlier field log first. Nothing was imported');
      }
      todo = waiting;
    }
    events
      ..clear()
      ..addAll(scratch.events);
    streams
      ..clear()
      ..addAll(scratch.streams);
    byEntity
      ..clear()
      ..addAll(scratch.byEntity);
    return added;
  }
}

/// For each event of [entity], the set of its ancestors through deps (not including itself).
Map<String, Set<String>> ancestors(FieldLog log, String entity) {
  final memo = <String, Set<String>>{};
  for (final start in log.byEntity[entity] ?? const <String>[]) {
    if (memo.containsKey(start)) continue;
    final stack = <(String, bool)>[(start, false)];
    while (stack.isNotEmpty) {
      final (id, expanded) = stack.removeLast();
      if (memo.containsKey(id)) continue;
      final deps = log.events[id]!.deps;
      if (expanded) {
        final acc = <String>{};
        for (final d in deps) {
          acc.add(d);
          acc.addAll(memo[d]!);
        }
        memo[id] = acc;
      } else {
        stack.add((id, true));
        for (final d in deps) {
          if (!memo.containsKey(d)) stack.add((d, false));
        }
      }
    }
  }
  return memo;
}
