// SPDX-License-Identifier: GPL-3.0-or-later
// Signed field records (docs/PROTOCOL.md section 12): the Dart SHA-512 and Ed25519 agree with the Python reference on
// spec/vectors/signatures.json; a phone's store has one key for life, signs every record with it, and takes in only
// records whose signatures hold, checking each new one once.

import 'dart:convert';
import 'dart:io';

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:fieldworx_core/src/ed25519.dart' as ed;
import 'package:fieldworx_core/src/fxjson.dart' as fx;
import 'package:fieldworx_core/src/sha512.dart';
import 'package:test/test.dart';

final String vectorsDir = Directory('../spec/vectors').existsSync() ? '../spec/vectors' : 'spec/vectors';

Map<String, Object?> load(String name) =>
    jsonDecode(File('$vectorsDir/$name').readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> cases(Map<String, Object?> v, String key) => (v[key]! as List).cast<Map<String, Object?>>();

const String ent = 'ins_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Event note(SigningKey? key, String device, int seq, String prev, Map<String, Object?> body,
        {String time = '2026-11-07T09:00:00.000Z'}) =>
    Event.make(
        device: device, seq: seq, prev: prev, actor: 'Tess', type: 'inspection.note', entity: ent, //
        deps: prev.isEmpty ? const <String>[] : [prev], body: body, time: time, signingKey: key);

/// [ev] with fields changed after it was signed, as a broken phone or a person editing the file would make it.
List<int> tampered(Event ev, Map<String, Object?> changes) => fx.encode({...ev.data, ...changes});

void main() {
  final v = load('signatures.json');

  group('vectors', () {
    test('SHA-512', () {
      for (final c in cases(v, 'sha512')) {
        expect(toHex(sha512(ed.hexBytes(c['hex']! as String))), equals(c['sha512']));
      }
    });
    test('RFC 8032 section 7.1, tests 1 to 3', () {
      for (final c in cases(v, 'rfc8032')) {
        final seed = ed.hexBytes(c['seed']! as String), message = ed.hexBytes(c['message']! as String);
        expect(toHex(ed.publicKey(seed)), equals(c['public']));
        expect(toHex(ed.sign(seed, message)), equals(c['signature']));
        expect(ed.verify(ed.hexBytes(c['public']! as String), message, ed.hexBytes(c['signature']! as String)), isTrue);
      }
    });
    test('fingerprints', () {
      for (final c in cases(v, 'fingerprints')) {
        expect(keyFingerprint(c['public']! as String), equals(c['fingerprint']));
      }
      expect(keyFingerprint(cases(v, 'fingerprints').first['public']! as String), equals('F9A2-C52A-0A32-73C7'));
    });
    test('signatures over event ids', () {
      for (final c in cases(v, 'events')) {
        final key = SigningKey(ed.hexBytes(c['seed']! as String));
        expect(key.publicHex, equals(c['public']));
        expect(toHex(signatureMessage(c['event']! as String)), equals(c['message']));
        expect(toHex(key.sign(signatureMessage(c['event']! as String))), equals(c['signature']));
      }
    });
    for (final c in cases(v, 'bad')) {
      test('refused: ${c['name']}', () {
        expect(
            ed.verify(ed.hexBytes(c['public']! as String), ed.hexBytes(c['message']! as String),
                ed.hexBytes(c['signature']! as String)),
            isFalse);
      });
    }
    test('a key that is not a point of the curve', () {
      expect(ed.isPublicKey(ed.hexBytes('ff' * 32)), isFalse);
      expect(ed.isPublicKey(ed.hexBytes(cases(v, 'rfc8032').first['public']! as String)), isTrue);
      // y = 1 with the sign bit: x would be 0, which has no sign (RFC 8032, 5.1.3)
      expect(ed.isPublicKey([1, ...List.filled(30, 0), 0x80]), isFalse);
      expect(ed.isPublicKey([1, ...List.filled(31, 0)]), isTrue);
    });
  });

  group('signed records', () {
    final key = SigningKey(List<int>.generate(32, (i) => i));
    final other = SigningKey(List<int>.generate(32, (i) => i + 1));
    const dev = 'dev_1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f';

    test('a signed record reads back, and its id leaves out the signature', () {
      final ev = note(key, dev, 1, '', {'x': 1});
      expect(ev.version, equals(2));
      expect(ev.key, equals(key.publicHex));
      final unsigned = {for (final e in ev.data.entries) if (e.key != 'sig') e.key: e.value};
      expect(ev.id, equals(digest('event/v2', unsigned)));
      expect(ed.verify(key.public, signatureMessage(ev.id), ed.hexBytes(ev.sig)), isTrue);
      final back = Event.fromBytes(ev.raw, expectedId: ev.id);
      expect(back.raw, equals(ev.raw));
      expect(note(key, dev, 1, '', {'x': 1}).raw, equals(ev.raw)); // deterministic: one stored form
    });

    for (final change in <String, Map<String, Object?>>{
      'body': {'body': {'x': 2}},
      'actor': {'actor': 'Mallory'},
      'signature': {'sig': '00' * 64},
      'key': {'key': other.publicHex},
    }.entries) {
      test('changed after signing (${change.key}) is refused', () {
        final raw = tampered(note(key, dev, 1, '', {'x': 1}), change.value);
        expect(() => Event.fromBytes(raw), throwsA(isA<EventError>()));
        expect(Event.fromBytes(raw, checkSignature: false).signatureHolds, isFalse);
      });
    }

    test('one key per device, and no unsigned record after a signed one', () {
      final first = note(key, dev, 1, '', {'x': 1});
      final log = FieldLog()..importEvents([first]);
      expect(() => log.importEvents([note(other, dev, 2, first.id, {'x': 2})]), throwsA(isA<EventError>()));
      expect(() => log.importEvents([note(null, dev, 2, first.id, {'x': 2})]), throwsA(isA<EventError>()));
      expect(log.length, equals(1));
      log.importEvents([note(key, dev, 2, first.id, {'x': 2})]);
      expect(log.length, equals(2));
    });
  });

  group('the store', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('fwx-sig-'));
    tearDown(() async => tmp.delete(recursive: true));

    test('a new store has a key for life, and signs every record with it', () async {
      final s = await FieldStore.open(Directory('${tmp.path}/phone'));
      final m = jsonDecode(File('${tmp.path}/phone/device.json').readAsStringSync()) as Map<String, Object?>;
      final k = m['key']! as Map<String, Object?>;
      expect(k['public'], equals(s.signingKey.publicHex));
      expect(SigningKey.fromSeedHex(k['seed']! as String).publicHex, equals(k['public']));
      expect(s.fingerprint, equals(keyFingerprint(s.signingKey.publicHex)));
      expect(s.fingerprint, matches(RegExp(r'^[0-9A-F]{4}(-[0-9A-F]{4}){3}$')));
      final ev = await s.record('inspection.note', ent, {'text': 'x', 'item': ''});
      expect((ev.version, ev.key, ev.signatureHolds), equals((2, s.signingKey.publicHex, true)));
      final again = await FieldStore.open(Directory('${tmp.path}/phone'));
      expect((again.deviceId, again.signingKey.publicHex), equals((s.deviceId, s.signingKey.publicHex)));
      expect(again.fieldError, isNull);
      final out = await again.exportFieldLog(Directory('${tmp.path}/out'));
      final a = await FieldArchive.open(out);
      expect(a.createdBy['key'], equals(s.signingKey.publicHex));
      expect(a.createdBy['device'], equals(s.deviceId));
      await a.close();
    });

    test('a store from before keys gets one, keeps its id, and its earlier records stay unsigned', () async {
      final root = Directory('${tmp.path}/old')..createSync(recursive: true);
      const dev = 'dev_2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e';
      File('${root.path}/device.json').writeAsBytesSync(fx.encode({'device': dev, 'created': '2026-01-01T00:00:00.000Z'}));
      final old = note(null, dev, 1, '', {'text': 'before keys', 'item': ''});
      File('${root.path}/events/$dev/0000000001.json')
        ..createSync(recursive: true)
        ..writeAsBytesSync(old.raw);
      final s = await FieldStore.open(root);
      expect(s.deviceId, equals(dev));
      expect(s.fieldError, isNull);
      final ev = await s.record('inspection.note', ent, {'text': 'after', 'item': ''});
      expect(s.log.events.values.map((e) => e.version).toList()..sort(), equals([1, 2]));
      expect(ev.prev, equals(old.id));
      final again = await FieldStore.open(root);
      expect(again.signingKey.publicHex, equals(s.signingKey.publicHex));
      expect(again.log.length, equals(2));
    });

    test('a damaged key is refused rather than replaced', () async {
      final s = await FieldStore.open(Directory('${tmp.path}/phone'));
      final f = File('${tmp.path}/phone/device.json');
      final m = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      final k = Map<String, Object?>.of(m['key']! as Map<String, Object?>)..['public'] = SigningKey.generate().publicHex;
      f.writeAsBytesSync(fx.encode({...m, 'key': k}));
      await expectLater(FieldStore.open(Directory('${tmp.path}/phone')), throwsA(isA<StoreError>()));
      expect(s.deviceId, isNotEmpty);
    });

    test("a field log is taken in only if each new record's signature holds", () async {
      final a = await FieldStore.open(Directory('${tmp.path}/a'));
      final first = await a.record('inspection.note', ent, {'text': 'one', 'item': ''});
      final good = await a.exportFieldLog(Directory('${tmp.path}/out1'));
      final b = await FieldStore.open(Directory('${tmp.path}/b'));
      expect((await b.importFieldLog(good)).newEvents, equals(1));
      final second = await a.record('inspection.note', ent, {'text': 'two', 'item': ''});
      // A field log whose new record was edited after it was signed: nothing from it is taken in.
      final edited = Event.fromBytes(tampered(second, {'body': {'text': 'edited', 'item': ''}}), checkSignature: false);
      final bad = File('${tmp.path}/bad.fieldlog');
      await writeArchive(bad,
          kind: 'fieldlog', archiveId: newId('flg'), title: 't', created: utcNow(), //
          createdBy: {'device': a.deviceId}, events: [first, edited], objects: const []);
      await expectLater(b.importFieldLog(bad), throwsA(isA<StoreError>()));
      expect(b.log.length, equals(1));
      // A known record with a signature that doesn't hold is ignored: this copy keeps its own.
      final forgedCopy = Event.fromBytes(tampered(first, {'sig': '00' * 64}), checkSignature: false);
      final mixed = File('${tmp.path}/mixed.fieldlog');
      await writeArchive(mixed,
          kind: 'fieldlog', archiveId: newId('flg'), title: 't', created: utcNow(), //
          createdBy: {'device': a.deviceId}, events: [forgedCopy, second], objects: const []);
      final r = await b.importFieldLog(mixed);
      expect((r.newEvents, r.knownEvents), equals((1, 1)));
      expect(b.log.events[first.id]!.raw, equals(first.raw));
    });
  });
}
