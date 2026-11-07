// SPDX-License-Identifier: GPL-3.0-or-later
// Findings on the phone (docs/PROTOCOL.md section 11): a part replaced, with a photo, recorded as a proposal and then
// voided; a change carried out, chosen from those due on the unit; and a finding that says nothing isn't recorded. The
// unit's own record never changes on the phone.

import 'dart:io';

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Finder field(String label) => find.widgetWithText(TextField, label);

Future<void> type(WidgetTester tester, Finder f, String text) async {
  await reveal(tester, f);
  await tester.enterText(f, text);
  await tester.pump();
}

void main() {
  testWidgets('a part replaced, with a photo: recorded as a finding, never as a change to the unit, and voided',
      (tester) async {
    phone(tester, height: 1800);
    final (m, s) = await openPhone(tester);
    await showApp(tester, m);
    final before = m.store.log.length;

    s.scan('FWX:A:HPU-0002');
    await waitFor(tester, find.text('HPU-75 for Bayside Marine'));
    await reveal(tester, find.text('FINDINGS (0)'));
    await tapOn(tester, button('Report a finding'));
    await waitFor(tester, find.text('Report on HPU-0002'));
    expect(button('Record finding'), findsNothing, reason: 'nothing to record until it says what happened');

    await tapOn(tester, find.widgetWithText(OutlinedButton, 'Replaced a part'));
    await tester.pumpAndSettle();
    await type(tester, field('Position on the unit (like P1)'), 'P1');
    await type(tester, field('Part number').first, 'PMP-10');
    await type(tester, field('Serial').first, '111');
    await tapOn(tester, find.widgetWithText(OutlinedButton, 'Scrapped'));
    await type(tester, field('Part number').last, 'PMP-11');
    await type(tester, field('Serial').last, '222');
    await tapOn(tester, button('Take a photo'));
    await waitFor(tester, find.text('1 photo to add'));
    await tapAndWait(tester, button('Record finding'), find.text('FINDINGS (1)'));

    final f = m.store.findings().single;
    expect((f['what'], f['position'], f['disposition'], f['status']), ('replaced', 'P1', 'scrapped', 'recorded'));
    expect(f['removed'], {'number': 'PMP-10', 'serial': '111', 'lot': ''});
    expect(f['fitted'], {'number': 'PMP-11', 'serial': '222', 'lot': ''});
    expect(f['on'], utcNow().substring(0, 10), reason: 'done today unless the form says otherwise');
    expect((f['attachments']! as List).length, 1);
    expect(m.store.log.length - before, 2, reason: 'the finding and its photo');
    expect(m.unsent, 2);
    expect(m.catalog.asset(f['asset']! as String)!.components, isEmpty, reason: 'the unit’s record is unchanged');

    await tapAndWait(tester, row(['Replaced at P1: PMP-10 S/N 111 out, PMP-11 S/N 222 in']), find.text('FINDING'));
    expect(find.text('scrapped'), findsOneWidget);
    // The message after recording says what to do next, and covers the page's bottom action while it shows, as a
    // message does on a phone: wait for it to go, as a person would.
    expect(find.text('Recorded. Send a field log so the office sees it.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tapOn(tester, button('Void…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'recorded on the wrong unit');
    await tapAndWait(tester, find.widgetWithText(FilledButton, 'Void'),
        find.textContaining('Voided: recorded on the wrong unit'));
    expect(m.store.findings().single['status'], 'voided');
    expect(button('Void…'), findsNothing, reason: 'a void can’t be undone; record a new finding instead');
  });

  testWidgets('a change carried out is chosen from those due on the unit; a finding that says nothing is refused',
      (tester) async {
    phone(tester, height: 2000);
    final (m, s) = await openPhone(tester, demo: false);
    await tester.runAsync(() => m.installPackage(File('../spec/vectors/units.fieldworx')));
    await showApp(tester, m);

    s.scan('FWX:A:unt_${'0c' * 16}');
    await waitFor(tester, find.text('NH-26-0001'));
    await reveal(tester, find.text('FINDINGS (0)'));
    await tapOn(tester, button('Report a finding'));
    await waitFor(tester, find.text('Report on NH-26-0001'));

    await tapOn(tester, find.widgetWithText(OutlinedButton, 'Something else'));
    await tester.pumpAndSettle();
    await tapOn(tester, button('Record finding'));
    await tester.pumpAndSettle();
    expect(find.text('Say what you found.'), findsOneWidget);
    expect(m.store.findings(), isEmpty, reason: 'nothing is recorded that the office couldn’t read');

    await tapOn(tester, find.widgetWithText(OutlinedButton, 'Carried out a change'));
    await tester.pumpAndSettle();
    await tapOn(tester, find.widgetWithText(OutlinedButton, 'ECO-0042'));
    await type(tester, field('Date done (year-month-day)'), '2026-11-02');
    await tapAndWait(tester, button('Record finding'), find.text('FINDINGS (1)'));
    final f = m.store.findings().single;
    expect((f['what'], f['change'], f['on'], f['asset']), ('change', 'ECO-0042', '2026-11-02', 'unt_${'0c' * 16}'));
    expect(find.text('Carried out ECO-0042'), findsOneWidget);
  });
}
