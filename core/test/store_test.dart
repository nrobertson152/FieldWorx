// SPDX-License-Identifier: GPL-3.0-or-later
// The on-device store: packages install all-or-nothing and replace their series, field records persist and
// survive reopening, field logs round-trip, damaged archives are refused, scans resolve without guessing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:fieldworx_core/src/zip.dart';
import 'package:test/test.dart';

final String vectors = Directory('../spec/vectors').existsSync() ? '../spec/vectors' : 'spec/vectors';

Map<String, Object?> sampleCatalog() {
  final pdf = utf8.encode('%PDF-1.4 sample');
  return {
    'format': 'fieldworx.catalog',
    'version': 1,
    'projects': [
      {'id': 'prj_${'01' * 16}', 'number': 'J-1', 'name': 'Demo', 'customer': 'Acme'},
    ],
    'documents': [
      {
        'id': 'doc_${'02' * 16}',
        'number': 'DWG-1',
        'title': 'Frame',
        'type': 'pdf',
        'project': 'prj_${'01' * 16}',
        'path': 'DWG-1.pdf',
        'released': 'rev_${'03' * 16}',
        'latest': 'rev_${'03' * 16}',
        'revisions': [
          {
            'id': 'rev_${'03' * 16}',
            'label': 'A',
            'state': 'released',
            'state_name': 'Released',
            'sha256': sha256Hex(pdf),
            'size': pdf.length,
            'created': '2026-01-01T00:00:00+00:00',
            'author': 'am',
            'description': '',
            'ext': '.pdf',
            'rendition': {'object': sha256Hex(pdf), 'media_type': 'application/pdf', 'via': 'content'},
          },
        ],
      },
    ],
    'parts': [
      {
        'id': 'pn:pnl-1', 'number': 'PNL-1', 'description': 'Panel', 'unit': 'EA', 'kind': 'assembly', //
        'revision': 'A', 'status': 'active', 'manufacturers': <Object?>[], 'vendors': <Object?>[],
        'documents': [
          {'document': 'doc_${'02' * 16}', 'revision': '', 'role': 'drawing'},
        ],
        'attributes': <String, Object?>{}, 'stock': null,
      },
      {
        'id': 'pn:k-9', 'number': 'K-9', 'description': 'Contactor 9 A', 'unit': 'EA', 'kind': 'part', //
        'revision': '', 'status': 'active',
        'manufacturers': [
          {'name': 'Kestrel', 'mpn': 'KC-09'},
        ],
        'vendors': [
          {'name': 'Delta', 'sku': 'D-77'},
        ],
        'documents': <Object?>[], 'attributes': <String, Object?>{},
        'stock': {'on_hand': '3', 'unit': 'EA', 'bin': 'B2', 'as_of': '2026-11-01T00:00:00Z', 'source': 'OpenMeridian'},
      },
    ],
    'bom': [
      {
        'parent': 'pn:pnl-1', 'child': 'pn:k-9', 'quantity': '2', 'unit': 'EA', 'find_number': '10', //
        'refdes': ['K1', 'K2'], 'note': '', 'provenance': 'declared', 'source': '',
      },
    ],
    'assets': [
      {
        'id': 'ast_${'04' * 16}', 'tag': 'PNL-0001', 'serial': 'SN-1', 'name': 'Panel 1', 'part': 'pn:pnl-1', //
        'project': 'prj_${'01' * 16}', 'location': 'Bay 4', 'built': '2026-01-02', 'notes': '',
        'as_built': ['rev_${'03' * 16}'],
      },
    ],
    'templates': [
      {
        'template': {
          'format': 'fieldworx.template', 'version': 1, 'id': 'ITP-1', 'revision': 'A', 'title': 'Check', //
          'description': '',
          'sections': [
            {
              'title': 'S',
              'items': [
                {'id': '1', 'kind': 'check', 'prompt': 'OK?', 'required': true, 'photo': 'optional', 'help': ''},
                {
                  'id': '2', 'kind': 'measure', 'prompt': 'Gap', 'unit': 'mm', 'nominal': '1', 'min': '0.9', //
                  'max': '1.1', 'required': true, 'photo': 'none', 'help': '',
                },
              ],
            },
          ],
        },
        'document': '',
        'revision': '',
        'state': 'uncontrolled',
      },
    ],
  };
}

Future<File> writePackage(Directory dir, {String series = 'ser1', String created = '2026-11-01T00:00:00.000Z',
    String? id, List<Event> events = const [], Map<String, Object?>? catalog}) async {
  final pdf = Uint8List.fromList(utf8.encode('%PDF-1.4 sample'));
  final f = File('${dir.path}/${newId('tst')}.fieldworx');
  await writeArchive(f,
      kind: 'package',
      archiveId: id ?? newId('pkg'),
      title: 'Test package',
      created: created,
      createdBy: {'user': 'test'},
      series: series,
      catalog: catalog ?? sampleCatalog(),
      events: events,
      objects: [ObjectSource.bytes(pdf, 'application/pdf')]);
  return f;
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('fwx-test-'));
  tearDown(() async => tmp.delete(recursive: true));

  test('zip round trip, stored and deflated, read back by member', () async {
    final f = File('${tmp.path}/a.zip');
    final w = await ZipWriter.create(f);
    final big = Uint8List.fromList(List<int>.generate(300000, (i) => (i * 7) % 251));
    await w.addBytes('mimetype', ascii.encode('x/y'), deflate: false);
    await w.addBytes('a/b.json', utf8.encode('{"a":1}' * 1000), deflate: true);
    await w.addBytes('big', big, deflate: false);
    await w.close();
    final r = await ZipReader.open(f);
    expect(r.entries.map((e) => e.name).toList(), equals(['mimetype', 'a/b.json', 'big']));
    expect(utf8.decode(await r.readBytes(r.byName['a/b.json']!)), equals('{"a":1}' * 1000));
    expect(await r.readBytes(r.byName['big']!), equals(big));
    await r.close();
  });

  test('install, reopen, record, export and re-import', () async {
    final s = await FieldStore.open(Directory('${tmp.path}/phone'));
    await s.saveSettings({'user': 'Tess'});
    final res = await s.installPackage(await writePackage(tmp));
    expect(res.newObjects, equals(1));
    expect(s.catalog.documents.length, equals(1));
    final t = s.catalog.templates.single;
    final ins = await s.startInspection(t, title: 'Panel 1', subject: {'kind': 'asset', 'id': 'ast_${'04' * 16}', 'label': 'PNL-0001'});
    await s.record('inspection.answer', ins, {'item': '1', 'value': {'result': 'pass'}, 'note': ''});
    await s.record('inspection.answer', ins, {'item': '2', 'value': {'measured': '1.2'}, 'note': 'worn'});
    final photo = File('${tmp.path}/p.jpg')..writeAsBytesSync([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]);
    final (sha, size) = await s.addFile(photo);
    await s.record('inspection.attach', ins,
        {'object': sha, 'size': size, 'media_type': 'image/jpeg', 'item': '1', 'caption': 'guard'});
    await s.record('inspection.complete', ins, {'result': 'fail', 'summary': 'gap'});
    final st = s.inspection(ins);
    expect(st['outcome'], equals('fail'));
    expect(st['status'], equals('completed'));
    expect(await s.unsentCount(), equals(5));

    final again = await FieldStore.open(Directory('${tmp.path}/phone'));
    expect(again.deviceId, equals(s.deviceId));
    expect(again.userName, equals('Tess'));
    expect(again.log.length, equals(5));
    expect(again.catalog.parts.length, equals(2));

    final out = await again.exportFieldLog(Directory('${tmp.path}/out'));
    expect(await again.unsentCount(), equals(0));
    final a = await FieldArchive.open(out, verifyObjects: true);
    expect(a.events.length, equals(5));
    expect(a.objects.keys, contains(sha));
    await a.close();
    // A second export leaves out photos already sent.
    final out2 = await again.exportFieldLog(Directory('${tmp.path}/out2'));
    final a2 = await FieldArchive.open(out2);
    expect(a2.objects, isEmpty);
    await a2.close();

    final other = await FieldStore.open(Directory('${tmp.path}/phone2'));
    final imp = await other.importFieldLog(out);
    expect(imp.newEvents, equals(5));
    expect(other.inspection(ins)['outcome'], equals('fail'));
    expect(await other.hasObject(sha), isTrue);
    final imp2 = await other.importFieldLog(out);
    expect(imp2.newEvents, equals(0));
    expect(imp2.knownEvents, equals(5));
  });

  test('a newer package of the same series replaces the older', () async {
    final s = await FieldStore.open(Directory('${tmp.path}/phone'));
    await s.installPackage(await writePackage(tmp, created: '2026-11-01T00:00:00.000Z'));
    final r = await s.installPackage(await writePackage(tmp, created: '2026-11-02T00:00:00.000Z'));
    expect(r.replaced, hasLength(1));
    expect(s.catalog.packages, hasLength(1));
    await expectLater(s.installPackage(await writePackage(tmp, created: '2026-10-01T00:00:00.000Z')),
        throwsA(isA<StoreError>()));
  });

  test('damaged archives change nothing', () async {
    final s = await FieldStore.open(Directory('${tmp.path}/phone'));
    final good = await writePackage(tmp);
    final bytes = await good.readAsBytes();
    // Flip one byte of the stored PDF object.
    final at = _indexOf(bytes, utf8.encode('%PDF-1.4 sample'));
    final bad = Uint8List.fromList(bytes)..[at + 3] ^= 0x01;
    final badFile = File('${tmp.path}/bad.fieldworx')..writeAsBytesSync(bad);
    await expectLater(s.installPackage(badFile), throwsA(anyOf([isA<ArchiveError>(), isA<StoreError>()])));
    expect(s.catalog.isEmpty, isTrue);
    final truncated = File('${tmp.path}/trunc.fieldworx')..writeAsBytesSync(bytes.sublist(0, bytes.length - 30));
    await expectLater(s.installPackage(truncated), throwsA(isA<ArchiveError>()));
    final notZip = File('${tmp.path}/x.fieldworx')..writeAsStringSync('hello');
    await expectLater(s.installPackage(notZip), throwsA(isA<ArchiveError>()));
  });

  test('a package whose field records fork this device is refused', () async {
    final s = await FieldStore.open(Directory('${tmp.path}/phone'));
    await s.installPackage(await writePackage(tmp));
    final ins = await s.startInspection(s.catalog.templates.single, title: 'x');
    // Someone else's record 1 for this same device id: a forked history.
    final forged = Event.make(
        device: s.deviceId, seq: 1, prev: '', actor: 'X', type: 'inspection.note', entity: ins, deps: [], body: {});
    await expectLater(s.installPackage(await writePackage(tmp, series: 'other', events: [forged])),
        throwsA(isA<StoreError>()));
    expect(s.catalog.packages, hasLength(1));
  });

  test('bridge-written package installs and its records reduce', () async {
    final s = await FieldStore.open(Directory('${tmp.path}/phone'));
    final res = await s.installPackage(File('$vectors/sample.fieldworx'));
    expect(res.newEvents, equals(8));
    final ent = inspectionEntities(s.log).single;
    expect(s.inspection(ent)['status'], equals('completed'));
    final frm = s.catalog.documents.values.single;
    expect(frm.revisions.map((r) => r.label).toList(), equals(['A', 'B']));
    expect(frm.current!.label, equals('B'));
    expect(await s.hasObject(frm.current!.rendition!.object), isTrue);
  });

  test('a package of units installs; a unit opens by its permanent label and by its earlier id', () async {
    final s = await FieldStore.open(Directory('${tmp.path}/phone'));
    await s.installPackage(File('$vectors/units.fieldworx'));
    final hpu = 'unt_${'0c' * 16}';
    expect(s.catalog.assets.keys.toList()..sort(), equals(['ast_${'05' * 16}', hpu, 'unt_${'0d' * 16}']));
    expect(resolve(s.catalog, labelFor(ResultKind.asset, hpu)).matches.single.id, equals(hpu));
    expect(s.catalog.asset('ast_${'0e' * 16}')?.id, equals(hpu));
    expect(s.catalog.asset(hpu)!.asBuilt, equals(['rev_${'03' * 16}', 'rev_${'09' * 16}']));
  });

  group('resolver', () {
    late Catalog c;
    setUp(() {
      c = Catalog()
        ..add(
            PackageInfo(id: 'pkg_x', title: 't', series: '', created: '', digest: '', source: {}, notices: [], createdBy: {}),
            sampleCatalog());
    });
    test('typed label', () {
      final r = resolve(c, 'FWX:A:PNL-0001');
      expect(r.matches.single.kind, equals(ResultKind.asset));
      expect(resolve(c, 'FWX:P:PNL-0001').matches, isEmpty);
    });
    test('plain codes, case and spaces', () {
      expect(resolve(c, ' sn-1 \r\n').matches.single.why, equals('serial number'));
      expect(resolve(c, 'kc-09').matches.single.id, equals('pn:k-9'));
      expect(resolve(c, 'D-77').matches.single.why, contains('order code'));
      expect(resolve(c, 'DWG-1').matches.single.kind, equals(ResultKind.document));
      expect(resolve(c, ']Q1PNL-0001').matches.single.kind, equals(ResultKind.asset));
    });
    test('reference designators and URLs', () {
      final k2 = resolve(c, 'K2');
      expect(k2.matches.single.subtitle, startsWith('K2 in PNL-1'));
      expect(resolve(c, 'https://example.com/parts/K-9').matches.single.id, equals('pn:k-9'));
    });
    test('nothing is guessed', () {
      expect(resolve(c, 'PNL').matches, isEmpty);
      expect(c.search('PNL').length, greaterThanOrEqualTo(2));
    });
    test('a label of a kind this version doesn’t read matches nothing, and says so', () {
      expect(resolve(c, 'PNL-1').matches.single.kind, equals(ResultKind.part));
      for (final raw in ['FWX:L:PNL-1', 'FWX:W:PNL-1', 'FWX:T:PNL-1', 'FWX:PART2:PNL-1']) {
        final r = resolve(c, raw);
        expect(r.matches, isEmpty, reason: '$raw: the code is a part number, but the label isn’t a part label');
        expect(r.problem, contains('doesn’t read'), reason: raw);
        expect(r.typed, isNull);
      }
      expect(() => labelFor(ResultKind.template, 'x'), throwsArgumentError, reason: 'templates have no label');
    });
  });

  test('catalog checks refuse dangling references', () {
    final c = sampleCatalog();
    ((c['bom']! as List).first as Map<String, Object?>)['child'] = 'pn:missing';
    expect(() => checkCatalog(c), throwsA(isA<CatalogError>()));
    final d = sampleCatalog();
    ((d['assets']! as List).first as Map<String, Object?>)['as_built'] = ['rev_${'99' * 16}'];
    expect(() => checkCatalog(d), throwsA(isA<CatalogError>()));
    checkCatalog(sampleCatalog());
  });

  test('decimal input is normalised, not guessed', () {
    expect(normalizeDecimalInput('12,5'), equals('12.5'));
    expect(normalizeDecimalInput(' +0.30 '), equals('0.30'));
    expect(normalizeDecimalInput('.5'), equals('0.5'));
    expect(normalizeDecimalInput('-.05'), equals('-0.05'));
    expect(normalizeDecimalInput('007'), equals('7'));
    expect(normalizeDecimalInput('1e3'), isNull);
    expect(normalizeDecimalInput('1.2.3'), isNull);
    expect(normalizeDecimalInput(''), isNull);
  });
}

int _indexOf(List<int> hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}
