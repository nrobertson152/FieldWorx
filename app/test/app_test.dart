// SPDX-License-Identifier: GPL-3.0-or-later
// The v0.1 workflows end to end, on the real store with the demo package: first run, scanning, documents and the
// drawing viewer, part lookup, an inspection from start to field log, conflicts between two phones, and the library.

import 'dart:io';

import 'package:fieldworx/screens/shell.dart';
import 'package:fieldworx/version.dart';
import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

/// The card of inspection item [id] (its header reads "<id>  <prompt>").
Finder itemCard(String id) => find.ancestor(of: find.text('$id  '), matching: find.byType(Card));

Finder inItem(String id, Finder f) => find.descendant(of: itemCard(id), matching: f);

/// The line under an answered item: "<who> · <when>".
Finder answeredBy(String id, String who) => inItem(id, find.textContaining('$who · '));

void main() {
  test('the version shown in the app is the one in pubspec.yaml', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('\nversion: $appVersion+'));
  });

  testWidgets('first run: a name, then the demo package, then the camera', (tester) async {
    phone(tester);
    final s = FakeServices.temp();
    addTearDown(() => s.root.deleteSync(recursive: true));
    await tester.pumpWidget(FieldWorxBoot(services: s));
    await waitFor(tester, find.text('Your name'));

    expect(tester.widget<ButtonStyleButton>(button('Continue')).onPressed, isNull, reason: 'no name yet');
    await tester.enterText(find.byType(TextField), 'Riley Field');
    await tester.pump();
    await tapAndWait(tester, button('Continue'), find.text('No package on this phone yet'));
    expect(s.scanning, isFalse, reason: 'nothing to scan against yet');

    await tapAndWait(tester, button('Try the demo (HPU-75)'), find.text('Scan'), until: () => s.scanning);
    expect(find.textContaining('Added “HPU-75 demo (Northline Hydraulics)”'), findsOneWidget);
    expect(find.textContaining('35 field records'), findsOneWidget);
  });

  group('scanning', () {
    testWidgets('a unit label opens the unit: as-built revisions, what changed since, and its history',
        (tester) async {
      phone(tester);
      final (m, s) = await openPhone(tester);
      await showApp(tester, m);

      s.scan('FWX:A:HPU-0001');
      await waitFor(tester, find.text('AS BUILT'));
      expect(s.scanning, isFalse, reason: 'the camera stops while a page is open');
      expect(find.text('HPU-75 for Acme Manufacturing'), findsOneWidget);
      expect(find.text('S/N NH-26-0001'), findsOneWidget);
      expect(find.text('1 drawing revised since'), findsOneWidget);
      expect(find.text('FRM-200 rev A'), findsOneWidget);
      expect(find.text('current is rev B'), findsOneWidget);
      expect(find.text('HPU-75-GA rev A'), findsOneWidget);

      await reveal(tester, find.text('HPU-0001 final acceptance test'));
      expect(find.text('INSPECTIONS (1)'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);

      await back(tester);
      expect(s.scanning, isTrue, reason: 'back on the Scan tab, the camera runs again');
      expect(find.text('RECENT'), findsOneWidget);
      expect(find.text('HPU-0001'), findsOneWidget);
    });

    testWidgets('a serial plate, a part number and a reference designator', (tester) async {
      phone(tester);
      final (m, s) = await openPhone(tester);
      await showApp(tester, m);

      s.scan('NH-26-0002');
      await waitFor(tester, find.text('HPU-75 for Bayside Marine'));
      expect(find.text('current is rev B'), findsNothing, reason: 'HPU-0002 was built to the released frame');
      await back(tester);

      // Typed, as a rugged phone's scanner key would.
      await tester.enterText(find.byType(TextField), 'k1');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await waitFor(tester, find.text('CT-09-24DC'));
      expect(find.text('Contactor 9 A, 24 V DC coil'), findsOneWidget);
      expect(find.text('K1'), findsOneWidget, reason: 'its reference designator in the panel');
      expect(find.text('KC-09-24DC'), findsOneWidget, reason: 'Kestrel Electric part number');
    });

    testWidgets('a code that matches two things asks; an unknown code says so', (tester) async {
      phone(tester);
      final (m, s) = await openPhone(tester);
      await showApp(tester, m);

      s.scan('FRM-200');
      await waitFor(tester, find.text('2 matches'));
      expect(find.text('part number'), findsOneWidget);
      expect(find.text('document number'), findsOneWidget);
      await tapAndWait(tester, row(['FRM-200', 'document number']), find.text('REVISIONS (2)'));
      await back(tester);
      await back(tester);

      s.scan('FWX:P:NOPE-1');
      await waitFor(tester, find.text('Not found'));
      expect(find.text('FIELDWORX LABEL: PART'), findsOneWidget);
      await tapAndWait(tester, button('Search for “NOPE-1”'), find.text('No matches'));
    });
  });

  testWidgets('a document: revisions, units built to it, the drawing viewer and a superseded revision',
      (tester) async {
    phone(tester, height: 900);
    final (m, s) = await openPhone(tester);
    await showApp(tester, m);

    await tester.tap(navTab('Find'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'frm-200');
    await tester.pump();
    await tapAndWait(tester, row(['FRM-200', 'Document']), find.text('REVISIONS (2)'));
    expect(find.text('rev B · Released'), findsOneWidget);
    expect(find.text('Superseded'), findsOneWidget);
    await reveal(tester, find.text('older than rev B'));
    expect(find.textContaining('built to rev A'), findsOneWidget);
    expect(find.textContaining('built to rev B'), findsOneWidget);

    await tapAndWait(tester, button('Open drawing · rev B'), find.text('Page 1 of 1'));
    expect(find.text('FRM-200 rev B · Released'), findsOneWidget);
    expect(find.textContaining('bytes, zoom 0'), findsOneWidget);
    await tester.tap(iconButton('Zoom in'));
    await tester.pump();
    expect(find.textContaining('zoom 1'), findsOneWidget);

    await tester.tap(iconButton('Find text'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'LIFTING');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    final n = s.viewer!.matchCount;
    expect(n, greaterThan(0), reason: 'rev B adds the lifting lugs');
    expect(find.text('1/$n'), findsOneWidget);
    await tester.tap(iconButton('Stop finding'));
    await tester.pump();
    await back(tester);

    await reveal(tester, find.text('Rev A'));
    await tapAndWait(tester, row(['Rev A']), find.text('Superseded. The current revision is B.'));
  });

  testWidgets('a part: stock (not live), vendors, where it is used, and its label', (tester) async {
    phone(tester);
    final (m, s) = await openPhone(tester);
    await showApp(tester, m);

    s.scan('GP10-R-SAE'); // the pump maker's part number
    await waitFor(tester, find.text('PMP-10'));
    expect(find.text('Gear pump 10 cc/rev'), findsOneWidget);
    expect(find.textContaining('in stock'), findsOneWidget);
    expect(find.textContaining('It isn’t live.'), findsOneWidget);
    await reveal(tester, find.text('DMS-44120'));
    expect(find.text('Delta Motion Supply'), findsOneWidget);
    await reveal(tester, find.text('USED IN (1)'));
    expect(find.text('HPU-75'), findsOneWidget);

    await tester.tap(iconButton('Show label'));
    await tester.pumpAndSettle();
    expect(find.text('QR FWX:P:PMP-10'), findsOneWidget);
    expect(find.text('FWX:P:PMP-10'), findsOneWidget);
  });

  testWidgets('an inspection from the unit to the field log: answers, a failed reading corrected, a photo',
      (tester) async {
    phone(tester, height: 4200); // every item card on screen at once
    final (m, s) = await openPhone(tester);
    await showApp(tester, m);
    final before = m.store.log.length;

    s.scan('FWX:A:HPU-0002');
    await waitFor(tester, find.text('HPU-75 for Bayside Marine'));
    await tester.tap(button('Start an inspection'));
    await tester.pumpAndSettle();
    expect(find.text('Inspect HPU-0002'), findsOneWidget);
    await tapAndWait(tester, row(['ITP-HPU-75 rev 1']), find.text('INSPECTION'));
    expect(find.text('13 required items to go'), findsOneWidget);

    Future<void> check(String id, String choice) async {
      await tapOn(tester, inItem(id, find.widgetWithText(OutlinedButton, choice)));
      await waitFor(tester, answeredBy(id, 'Riley Field'), what: 'item $id answered');
    }

    Future<void> measure(String id, String value, String outcome) async {
      await reveal(tester, inItem(id, find.byType(TextField)));
      await tester.enterText(inItem(id, find.byType(TextField)), value);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await waitFor(tester, inItem(id, find.text(outcome)), what: 'item $id: $outcome');
    }

    // 1.1: the serial, and the nameplate photo it requires.
    await reveal(tester, inItem('1.1', find.byType(TextField)));
    await tester.enterText(inItem('1.1', find.byType(TextField)), 'NH-26-0002');
    FocusManager.instance.primaryFocus?.unfocus();
    await waitFor(tester, inItem('1.1', find.text('Photo needed')));
    await tapOn(tester, inItem('1.1', find.text('Photo')));
    await waitFor(tester, inItem('1.1', find.text('Done')), what: 'photo attached');
    expect(s.photosTaken, 1);

    await check('1.2', 'B');
    for (final id in ['2.1', '2.2', '2.4', '3.2', '4.1', '4.3', '4.4']) {
      await check(id, 'Pass');
    }
    await measure('2.3', '0.01', 'Pass');
    await measure('3.1', '170', 'Fail');
    expect(find.textContaining('Complete · Fail'), findsNothing, reason: 'items are still open');
    await measure('3.1', '159,5', 'Pass'); // a decimal comma, as typed on many keyboards
    expect(inItem('3.1', find.text('159.5')), findsOneWidget);
    await measure('3.4', '75', 'Pass');
    await measure('4.2', '600', 'Pass');

    await tester.tap(button('Complete · Pass'));
    await tester.pumpAndSettle();
    expect(find.text('Complete as Pass?'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Ready to ship.');
    await tapAndWait(tester, find.widgetWithText(FilledButton, 'Complete'), find.textContaining('Completed by Riley Field'));
    await reveal(tester, find.text('Completed'));
    expect(find.text('Completed'), findsOneWidget);

    // Two answers to 3.1 are both kept: the reading is corrected, not overwritten.
    final mine = m.store.log.length - before;
    expect(mine, 1 + 1 + 1 + 1 + 7 + 1 + 2 + 2 + 1, reason: 'start, 1.1, photo, 1.2, checks, 2.3, 3.1 twice, 3.4 '
        '4.2, complete');
    expect(m.unsent, mine);

    await back(tester);
    await back(tester);
    await tester.tap(navTab('Library'));
    await tester.pumpAndSettle();
    await tapAndWait(tester, button('Send field log ($mine new)'), find.text('Send field log'),
        until: () => s.shared.isNotEmpty);
    expect(m.unsent, 0);

    final (kind, events, objects, by) = (await tester.runAsync(() async {
      final a = await FieldArchive.open(s.shared.single, verifyObjects: true);
      try {
        return (a.kind, a.events.length, a.objects.length, a.manifest['created_by']);
      } finally {
        await a.close();
      }
    }))!;
    expect(kind, 'fieldlog');
    expect(events, before + mine);
    expect(objects, 1, reason: 'the nameplate photo');
    expect(by, containsPair('user', 'Riley Field'));
  });

  testWidgets('answers made on two phones without seeing each other are both kept until someone chooses',
      (tester) async {
    phone(tester, height: 4200);
    final (a, _) = await openPhone(tester, user: 'Ana');
    final (b, _) = await openPhone(tester, user: 'Ben');
    final id = (await tester.runAsync(() async {
      final id = await a.startInspection(a.catalog.sortedTemplates().first, title: 'Pump check');
      await b.importFieldLog(await a.exportFieldLog());
      await a.answer(id, '2.1', {'result': 'pass'});
      await b.answer(id, '2.1', {'result': 'fail'}, note: 'guard loose');
      await a.importFieldLog(await b.exportFieldLog());
      return id;
    }))!;
    await showApp(tester, a);

    await tester.tap(navTab('Inspect'));
    await tester.pumpAndSettle();
    await tapAndWait(tester, row(['Pump check']), find.text('INSPECTION'));
    expect(find.textContaining('1 item was answered on two devices'), findsOneWidget);
    expect(find.text('Two answers, recorded without seeing each other:'), findsOneWidget);
    expect(find.textContaining('Settle 1 conflict first'), findsOneWidget);

    final bens = find.ancestor(of: find.textContaining('Fail · Ben'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: bens, matching: find.text('Use this')));
    await waitFor(tester, null,
        until: () => find.text('Two answers, recorded without seeing each other:').evaluate().isEmpty,
        what: 'the conflict settled');
    expect(find.textContaining('answered on two devices'), findsNothing);
    expect(answeredBy('2.1', 'Ana'), findsOneWidget);
    final item = ((a.inspection(id)['items']! as List).cast<Map<String, Object?>>()).firstWhere((i) => i['id'] == '2.1');
    expect(item['outcome'], 'fail');
  });

  group('library', () {
    testWidgets('a damaged package is refused and changes nothing', (tester) async {
      phone(tester);
      final (m, s) = await openPhone(tester);
      await showApp(tester, m);
      final bad = File('${s.root.path}/bad.fieldworx')..writeAsBytesSync([...demoFile.readAsBytesSync().take(5000)]);
      s.picks.add(bad);

      await tester.tap(navTab('Library'));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.widgetWithText(TextButton, 'Add'), find.textContaining('can’t be used'));
      expect(m.catalog.packages.length, 1);
    });

    testWidgets('package details, removing it (field records stay), theme and name', (tester) async {
      phone(tester, height: 1600);
      final (m, _) = await openPhone(tester);
      await showApp(tester, m);
      await tester.tap(navTab('Library'));
      await tester.pumpAndSettle();
      expect(find.text('35 records (0 made here)'), findsOneWidget);

      await tester.tap(find.text('HPU-75 demo (Northline Hydraulics)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('TNK-100 has no released revision'), findsOneWidget);
      expect(find.textContaining('dwhitfield'), findsOneWidget);
      await tapOn(tester, button('Remove from this phone'));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.widgetWithText(FilledButton, 'Remove'), find.text('PACKAGES (0)'));
      expect(find.text('35 records (0 made here)'), findsOneWidget, reason: 'field records are never removed');

      await tapOn(tester, find.text('Theme'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High Contrast'));
      await waitFor(tester, null, until: () => m.theme == 'high_contrast');
      await back(tester);

      await tapOn(tester, find.text('Riley Field'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'R. Field');
      await tapAndWait(tester, find.widgetWithText(FilledButton, 'Save'), find.text('R. Field'),
          until: () => m.userName == 'R. Field');
      expect(m.userName, 'R. Field');
    });
  });
}
