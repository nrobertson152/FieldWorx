// SPDX-License-Identifier: GPL-3.0-or-later
// The family themes: readable everywhere FieldWorx puts text (in sunlight, on a phone), and every page draws in each.

import 'package:fieldworx/theme/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

void main() {
  test('every theme keeps text at 4.5:1 or better (WCAG AA)', () {
    for (final name in fxThemes.keys) {
      final fx = buildTheme(name).extension<FxColors>()!;
      void atLeast(Color fg, Color bg, String what) =>
          expect(contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '$name: $what');
      atLeast(fx.text, fx.surface, 'text');
      atLeast(fx.text, fx.bg, 'text on the background');
      atLeast(fx.muted, fx.surface, 'secondary text');
      atLeast(fx.selectFg, fx.selectBg, 'selection');
      atLeast(fx.accentText, fx.accentFill, 'filled buttons');
      for (final t in Tone.values) {
        atLeast(fx.toneFg(t), fx.toneBg(t), '$t chips and banners');
        atLeast(fx.tone(t), fx.surface, '$t text');
      }
    }
  });

  test('fillFor only moves a colour as far as it must', () {
    const white = Color(0xFFFFFFFF);
    expect(fillFor(const Color(0xFF1B1F24), white), const Color(0xFF1B1F24));
    final blue = fillFor(const Color(0xFF4C8DFF), white);
    expect(contrast(white, blue), greaterThanOrEqualTo(4.5));
    expect(contrast(white, blue), lessThan(5.5));
  });

  testWidgets('every theme draws the unit, part and inspection pages', (tester) async {
    phone(tester);
    final (m, s) = await openPhone(tester);
    await showApp(tester, m);
    for (final name in fxThemes.keys) {
      await tester.runAsync(() => m.setTheme(name));
      await tester.pumpAndSettle();
      final fx = Theme.of(tester.element(find.byType(NavigationBar))).extension<FxColors>()!;
      expect(fx.name, name);

      s.scan('FWX:A:HPU-0001');
      await waitFor(tester, find.text('AS BUILT'));
      await reveal(tester, find.text('HPU-0001 final acceptance test'));
      await tester.tap(find.text('HPU-0001 final acceptance test'));
      await tester.pumpAndSettle();
      expect(find.text('INSPECTION'), findsOneWidget);
      await back(tester);
      await back(tester);

      s.scan('PMP-10');
      await waitFor(tester, find.text('Gear pump 10 cc/rev'));
      await back(tester);
      expect(tester.takeException(), isNull);
    }
  });
}
