// SPDX-License-Identifier: GPL-3.0-or-later
// The Dart core must agree with the Python reference on every shared vector (spec/vectors, written by
// spec/make_vectors.py): same canonical bytes, digests, verdicts and inspection states.

import 'dart:convert';
import 'dart:io';

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:fieldworx_core/src/fxjson.dart' as fx;
import 'package:test/test.dart';

final String vectorsDir = () {
  for (final p in ['../spec/vectors', 'spec/vectors']) {
    if (Directory(p).existsSync()) return p;
  }
  throw StateError('spec/vectors not found; run the tests from core/');
}();

Object? load(String name) => jsonDecode(File('$vectorsDir/$name').readAsStringSync());

List<Map<String, Object?>> loadList(String name) => (load(name)! as List).cast<Map<String, Object?>>();

void main() {
  group('fxjson', () {
    for (final c in loadList('fxjson.json')) {
      test(c['name']! as String, () {
        final input = c['input']! as String;
        final canonical = c['canonical'] as String?;
        if (canonical == null) {
          expect(() => fx.encode(fx.parse(input)), throwsA(isA<FxJsonError>()));
          return;
        }
        final v = fx.parse(input);
        expect(fx.encodeText(v), equals(canonical));
        expect(fx.parseCanonical(utf8.encode(canonical)), equals(v));
        if (input != canonical) {
          expect(() => fx.parseCanonical(utf8.encode(input)), throwsA(isA<FxJsonError>()));
        }
      });
    }
  });

  test('digests and sha256', () {
    final d = load('digests.json')! as Map<String, Object?>;
    for (final c in (d['domain_digests']! as List).cast<Map<String, Object?>>()) {
      expect(fx.digestBytes(c['domain']! as String, utf8.encode(c['canonical']! as String)), equals(c['digest']));
    }
    for (final c in (d['sha256']! as List).cast<Map<String, Object?>>()) {
      final hex = c['hex']! as String;
      final bytes = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
      expect(sha256Hex(bytes), equals(c['sha256']));
      // Streaming in odd-sized pieces gives the same digest.
      final h = Sha256();
      for (var i = 0; i < bytes.length; i += 7) {
        h.add(bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7));
      }
      expect(h.hexDigest(), equals(c['sha256']));
    }
  });

  test('envelopes', () {
    final d = load('envelopes.json')! as Map<String, Object?>;
    for (final g in (d['good']! as List).cast<Map<String, Object?>>()) {
      expect(Event.fromBytes(utf8.encode(g['event']! as String)).id, equals(g['id']));
    }
    for (final b in (d['bad']! as List).cast<Map<String, Object?>>()) {
      expect(() => Event.fromBytes(utf8.encode(b['event']! as String)), throwsA(isA<EventError>()),
          reason: b['name'] as String);
    }
    for (final n in (d['not_canonical']! as List).cast<String>()) {
      expect(() => Event.fromBytes(utf8.encode(n)), throwsA(isA<EventError>()));
    }
  });

  group('field log', () {
    for (final c in loadList('fieldlog.json')) {
      test(c['name']! as String, () {
        final log = FieldLog();
        for (final step in (c['steps']! as List).cast<Map<String, Object?>>()) {
          final batch = [for (final r in (step['events']! as List).cast<String>()) Event.fromBytes(utf8.encode(r))];
          final result = step['result'];
          if (result == 'ok') {
            expect([for (final e in log.importEvents(batch)) e.id], equals(step['new']));
          } else {
            final before = Map.of(log.events);
            final matcher = switch (result) {
              'fork' => isA<ForkError>(),
              'missing' => isA<MissingHistory>(),
              _ => isA<EventError>(),
            };
            expect(() => log.importEvents(batch), throwsA(matcher));
            expect(log.events.keys.toSet(), equals(before.keys.toSet()));
          }
        }
        expect(log.heads(), equals(c['heads']));
        final eh = {for (final e in (log.byEntity.keys.toList()..sort())) e: log.entityHeads(e)};
        expect(eh, equals(c['entity_heads']));
      });
    }
  });

  group('inspections', () {
    for (final c in loadList('inspections.json')) {
      test(c['name']! as String, () {
        final evs = [for (final r in (c['events']! as List).cast<String>()) Event.fromBytes(utf8.encode(r))];
        final log = FieldLog()..importEvents(evs);
        final state = reduceInspection(log, c['entity']! as String);
        expect(fx.encodeText(state), equals(fx.encodeText(c['state'])));
        final reversed = FieldLog()..importEvents(evs.reversed);
        expect(fx.encodeText(reduceInspection(reversed, c['entity']! as String)), equals(fx.encodeText(state)));
      });
    }
  });

  group('findings', () {
    final d = load('findings.json')! as Map<String, Object?>;
    for (final c in (d['scenarios']! as List).cast<Map<String, Object?>>()) {
      test(c['name']! as String, () {
        final evs = [for (final r in (c['events']! as List).cast<String>()) Event.fromBytes(utf8.encode(r))];
        final log = FieldLog()..importEvents(evs);
        final state = reduceFinding(log, c['entity']! as String);
        expect(fx.encodeText(state), equals(fx.encodeText(c['state'])));
        final reversed = FieldLog()..importEvents(evs.reversed);
        expect(fx.encodeText(reduceFinding(reversed, c['entity']! as String)), equals(fx.encodeText(state)));
        expect(findingEntities(log), equals(c['name'] == 'no record' ? <String>[] : [c['entity']]),
            reason: 'a finding is listed once it has a record, even an unusable one');
      });
    }
    test('record bodies', () {
      for (final b in d['good']! as List) {
        checkFindingRecord(b);
      }
      for (final b in (d['bad']! as List).cast<Map<String, Object?>>()) {
        expect(() => checkFindingRecord(b['body']), throwsA(isA<FindingError>()), reason: b['name'] as String);
      }
    });
  });

  test('templates', () {
    final d = load('templates.json')! as Map<String, Object?>;
    for (final t in d['good']! as List) {
      checkTemplate(t);
    }
    for (final b in (d['bad']! as List).cast<Map<String, Object?>>()) {
      expect(() => checkTemplate(b['template']), throwsA(isA<TemplateError>()), reason: b['name'] as String);
    }
  });

  test('decimals', () {
    for (final c in loadList('decimals.json')) {
      expect(compareDecimal(c['a']! as String, c['b']! as String), equals(c['cmp']), reason: '${c['a']} ${c['b']}');
    }
  });

  group('catalogs', () {
    final v = load('catalogs.json')! as Map<String, Object?>;
    for (final c in (v['accept']! as List).cast<Map<String, Object?>>()) {
      test('accepts: ${c['name']}', () {
        final cat = fx.asMap(c['catalog'], 'catalog');
        checkCatalog(cat);
        expect(fx.encodeText(assetsView(cat)), equals(fx.encodeText(c['assets'])));
      });
    }
    for (final c in (v['refuse']! as List).cast<Map<String, Object?>>()) {
      test('refuses: ${c['name']}', () {
        expect(() => checkCatalog(c['catalog']), throwsA(isA<CatalogError>()));
      });
    }
    test('a unit resolves by its permanent label, an earlier id and every identifier', () {
      final cat = fx.asMap(((v['accept']! as List)[1] as Map<String, Object?>)['catalog'], 'catalog');
      final c = Catalog()
        ..add(
            PackageInfo(id: 'pkg_x', title: 't', series: '', created: '', digest: '', source: {}, notices: [], createdBy: {}),
            cat);
      final hpu = 'unt_${'0c' * 16}';
      expect(resolve(c, 'FWX:A:$hpu').matches.single.id, equals(hpu));
      expect(resolve(c, 'FWX:A:ast_${'0e' * 16}').matches.single.id, equals(hpu), reason: 'its asset register id');
      expect(resolve(c, 'FWX:A:unt_${'77' * 16}').matches, isEmpty, reason: 'an unknown unit: nothing guessed');
      expect(resolve(c, 'hpu-0001').matches.single.why, equals('asset tag (Acme)'));
      expect(resolve(c, 'OLD-17').matches.single.why, equals('former code (Previous owner)'));
      expect(resolve(c, 'GP-4471').matches.single.why, equals('serial number (Hydrix)'));
      final a = c.asset(hpu)!;
      expect(a.labelCode, equals(hpu));
      expect(a.isUnit, isTrue);
      expect(a.standardNumber, equals('HPU-75-A'));
      expect(c.fittedIn(a).single.label, equals('GP-4471'));
      expect(a.documents.map((d) => d.source).toList(), equals(['unit', 'standard', 'unit']));
      expect(a.documents[2].applies, isFalse);
      expect(a.asBuilt.length, equals(2));
      expect(a.history.last.voided, isTrue);
      expect(a.changes.map((c) => c.number).toList(), equals(['ECO-0042', 'ECO-0040']));
      expect(a.outstandingChanges.single.number, equals('ECO-0042'), reason: 'required and only scheduled');
      expect(a.changes.first.documents.single, equals(('FRM-200', 'A', 'B')));
      expect(a.changes.last.outstanding, isFalse, reason: 'an optional change is never outstanding');
      expect(a.deviations.map((d) => d.number).toList(), equals(['DEV-0007', 'CON-0002']));
      expect(a.deviationsInEffect.length, equals(2));
      final (dev, con) = (a.deviations.first, a.deviations.last);
      expect((dev.kind, dev.temporary, dev.until, dev.documents.single), equals(('deviation', true, '2026-03-31', ('BOM-75', 'B'))));
      expect(dev.overdue('2026-03-31'), isFalse, reason: 'in effect through its end date');
      expect(dev.overdue('2026-04-01'), isTrue, reason: 'past it the day after');
      expect((con.kind, con.temporary, con.overdue('2099-01-01')), equals(('concession', false, false)),
          reason: 'a permanent one is never past an end date');
      final row = c.assets['ast_${'05' * 16}']!;
      expect((row.isUnit, row.labelCode, row.tag), equals((false, 'HPU-0002', 'HPU-0002')));
    });
    test('a drawing has no label: document and revision labels match nothing and say how to find it', () {
      final cat = fx.asMap(((v['accept']! as List)[1] as Map<String, Object?>)['catalog'], 'catalog');
      final c = Catalog()
        ..add(
            PackageInfo(id: 'pkg_x', title: 't', series: '', created: '', digest: '', source: {}, notices: [], createdBy: {}),
            cat);
      expect(resolve(c, 'FRM-200').matches.where((m) => m.kind == ResultKind.document).length, equals(1),
          reason: 'the drawing is in the package, and its number still finds it');
      for (final (raw, code) in [
        ('FWX:R:FRM-200@B', 'FRM-200'),
        ('FWX:R:frm-200@a', 'frm-200'),
        ('FWX:R:A@B@C', 'A@B'),
        ('FWX:D:FRM-200', 'FRM-200'),
        ('FWX:document:FRM-200', 'FRM-200'),
      ]) {
        final r = resolve(c, raw);
        expect(r.matches, isEmpty, reason: '$raw: which revision applies is the machine’s to say');
        expect(r.code, equals(code), reason: '$raw: the number to search for');
        expect(r.problem, contains('Scan the machine’s label'), reason: raw);
        expect(r.typed, isNull, reason: raw);
      }
      expect(() => labelFor(ResultKind.document, 'FRM-200'), throwsArgumentError, reason: 'a drawing has no label to show');
    });
    test('a version 1 asset reads as the register row it was', () {
      final cat = fx.asMap(((v['accept']! as List)[0] as Map<String, Object?>)['catalog'], 'catalog');
      final c = Catalog()
        ..add(
            PackageInfo(id: 'pkg_y', title: 't', series: '', created: '', digest: '', source: {}, notices: [], createdBy: {}),
            cat);
      final a = c.assets.values.single;
      expect((a.label, a.tag, a.serial, a.built), equals(('HPU-0001', 'HPU-0001', 'NH-26-0001', '2026-03-18')));
      expect(a.documents.single.source, equals('register'));
      expect(a.changes, isEmpty);
      expect(a.deviations, isEmpty);
      expect(resolve(c, 'FWX:A:HPU-0001').matches.single.why, equals('asset tag'));
    });
  });

  group('archives written by the bridge', () {
    final expected = load('archives.json')! as Map<String, Object?>;
    for (final name in ['sample.fieldworx', 'sample.fieldlog', 'units.fieldworx']) {
      test(name, () async {
        final want = expected[name]! as Map<String, Object?>;
        final a = await FieldArchive.open(File('$vectorsDir/$name'), verifyObjects: true);
        try {
          expect(a.digest, equals(want['digest']));
          expect(a.kind, equals(want['kind']));
          expect(a.id, equals(want['id']));
          expect([for (final e in a.events) e.id], equals(want['events']));
          expect(a.objects.keys.toList()..sort(), equals(want['objects']));
          expect(a.catalog == null ? '' : fx.digest('catalog/v1', a.catalog), equals(want['catalog_digest']));
          for (final sha in a.objects.keys) {
            expect(sha256Hex(await a.readObject(sha)), equals(sha));
          }
        } finally {
          await a.close();
        }
      });
    }
    test('compressed data that doesn’t decompress is a damaged archive, refused with a message', () async {
      final raw = File('$vectorsDir/sample.fieldlog').readAsBytesSync();
      // The manifest's local header: signature, then its name and extra field lengths at 26 and 28.
      final at = _localHeader(raw, 'manifest.json');
      final data = at + 30 + (raw[at + 26] | raw[at + 27] << 8) + (raw[at + 28] | raw[at + 29] << 8);
      final bad = List<int>.of(raw)..[data] = 0xFF; // BFINAL 1, BTYPE 11: reserved, so not inflatable
      final dir = Directory.systemTemp.createTempSync('fwx-damaged');
      try {
        final f = File('${dir.path}/bad.fieldlog')..writeAsBytesSync(bad);
        await expectLater(FieldArchive.open(f),
            throwsA(isA<ArchiveError>().having((e) => e.message, 'message', contains('damaged'))));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

/// Where member [name]'s local file header starts: searched for by its signature followed, 26 bytes on, by its name.
int _localHeader(List<int> raw, String name) {
  final want = utf8.encode(name);
  for (var i = 0; i + 30 + want.length <= raw.length; i++) {
    if (raw[i] != 0x50 || raw[i + 1] != 0x4b || raw[i + 2] != 0x03 || raw[i + 3] != 0x04) continue;
    final nameLen = raw[i + 26] | raw[i + 27] << 8;
    if (nameLen != want.length) continue;
    var same = true;
    for (var k = 0; k < want.length && same; k++) {
      same = raw[i + 30 + k] == want[k];
    }
    if (same) return i;
  }
  throw StateError('no member $name');
}
