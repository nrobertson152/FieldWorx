// SPDX-License-Identifier: GPL-3.0-or-later
// fxtool: the phone's core on the command line, for checking files and for end-to-end tests with the bridge.
//
//   dart run bin/fxtool.dart verify FILE                     check a package or field log, print a summary
//   dart run bin/fxtool.dart simulate PACKAGE OUT_DIR        act as a phone: install, inspect the first asset
//                                                            with the first template, record a finding about it,
//                                                            export a field log

import 'dart:convert';
import 'dart:io';

import 'package:fieldworx_core/fieldworx_core.dart';

Future<int> verify(String path) async {
  try {
    final a = await FieldArchive.open(File(path), verifyObjects: true);
    try {
      if (a.catalog != null) checkCatalog(a.catalog);
      FieldLog().importEvents(a.events);
      stdout.writeln(jsonEncode({
        'ok': true,
        'kind': a.kind,
        'id': a.id,
        'digest': a.digest,
        'events': a.events.length,
        'objects': a.objects.length,
        if (a.catalog != null) 'documents': (a.catalog!['documents']! as List).length,
        if (a.catalog != null) 'parts': (a.catalog!['parts']! as List).length,
      }));
      return 0;
    } finally {
      await a.close();
    }
  } on Exception catch (e) {
    stdout.writeln(jsonEncode({'ok': false, 'error': e.toString()}));
    return 1;
  }
}

Future<int> simulate(String package, String outDir) async {
  final root = await Directory.systemTemp.createTemp('fxtool-phone-');
  try {
    final s = await FieldStore.open(root);
    await s.saveSettings({'user': 'fxtool'});
    await s.installPackage(File(package));
    final c = s.catalog;
    if (c.templates.isEmpty) throw StateError('the package has no inspection templates');
    final t = c.sortedTemplates().first;
    final asset = c.assets.values.isEmpty ? null : c.assets.values.first;
    final ins = await s.startInspection(t,
        title: '${asset?.label ?? 'Test'} ${t.title}',
        subject: asset == null ? null : {'kind': 'asset', 'id': asset.id, 'label': asset.label});
    for (final it in templateItems(t.template)) {
      final kind = it['kind'];
      final Map<String, Object?> value;
      if (kind == 'check') {
        value = {'result': 'pass'};
      } else if (kind == 'measure') {
        final lo = it['min']! as String, hi = it['max']! as String, nom = it['nominal']! as String;
        value = {'measured': nom.isNotEmpty ? nom : (lo.isNotEmpty ? lo : (hi.isNotEmpty ? hi : '0'))};
      } else if (kind == 'text') {
        value = {'text': 'checked by fxtool'};
      } else {
        value = {'choice': (it['choices']! as List).first};
      }
      await s.record('inspection.answer', ins, {'item': it['id'], 'value': value, 'note': ''});
      if (it['photo'] == 'required') {
        final f = File('${root.path}/photo.jpg')
          ..writeAsBytesSync([0xff, 0xd8, 0xff, 0xe0, ...utf8.encode('fxtool ${it['id']}'), 0xff, 0xd9]);
        final (sha, size) = await s.addFile(f);
        await s.record('inspection.attach', ins,
            {'object': sha, 'size': size, 'media_type': 'image/jpeg', 'item': it['id'], 'caption': 'photo'});
      }
    }
    final state = s.inspection(ins);
    if (state['outcome'] != 'pass') throw StateError('expected a pass, got ${state['outcome']}');
    await s.record('inspection.complete', ins, {'result': 'pass', 'summary': 'simulated'});
    // A finding about the same unit, for the office to accept into RevisionWorx (PROTOCOL section 11).
    final finding = asset == null
        ? null
        : await s.recordFinding({
            'asset': asset.id, 'what': 'note', 'position': '', 'removed': null, 'fitted': null, 'disposition': '', //
            'change': '', 'on': '', 'text': 'Guard on P1 loose; tightened. (fxtool)', 'package': t.package.id,
          });
    final out = await s.exportFieldLog(Directory(outDir), tool: 'fxtool');
    stdout.writeln(jsonEncode({
      'ok': true, 'inspection': ins, 'finding': finding, 'fieldlog': out.path, 'events': s.log.length, //
      'device': s.deviceId, 'key': s.signingKey.publicHex, 'fingerprint': s.fingerprint,
    }));
    return 0;
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  if (args.length == 2 && args[0] == 'verify') {
    exitCode = await verify(args[1]);
  } else if (args.length == 3 && args[0] == 'simulate') {
    exitCode = await simulate(args[1], args[2]);
  } else {
    stderr.writeln('usage: fxtool verify FILE | fxtool simulate PACKAGE OUT_DIR');
    exitCode = 2;
  }
}
