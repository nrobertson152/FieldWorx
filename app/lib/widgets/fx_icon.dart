// SPDX-License-Identifier: GPL-3.0-or-later
// Icons in the family's stroke language: OpenSchematix's gui/icons.py (also used by OpenMeridian), a 24 x 24 grid
// of round-capped strokes with one accent-coloured detail. The ops are the same as there:
//   l polyline, p polygon, pf filled polygon, r rectangle, o circle, of filled circle,
//   a arc (cx, cy, r, start, extent; degrees, counter-clockwise from 3 o'clock, as Tk draws them), t text.
// A "!" suffix paints that op in the accent colour.

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../theme/theme.dart';

typedef _Op = List<Object>;

final Map<String, List<_Op>> fxIcons = {
  // From OpenSchematix / OpenMeridian.
  'search': [
    ['o', 10, 10, 6.5],
    ['l', 14.8, 14.8, 20.5, 20.5],
  ],
  'part': [
    ['p', 12, 3, 20, 7.5, 20, 16.5, 12, 21, 4, 16.5, 4, 7.5],
    ['l', 4, 7.5, 12, 12, 20, 7.5],
    ['l!', 12, 12, 12, 21],
  ],
  'bom': [
    ['r', 5, 3.5, 19, 20.5],
    ['l', 8, 8, 16, 8],
    ['l', 8, 12, 16, 12],
    ['l!', 8, 16, 13, 16],
  ],
  'document': [
    ['p', 5, 3, 14, 3, 18, 7, 18, 21, 5, 21],
    ['l', 14, 3, 14, 7, 18, 7],
    ['l', 8, 12, 15, 12],
    ['l!', 8, 16, 13, 16],
  ],
  'pdf': [
    ['p', 5, 3, 14, 3, 19, 8, 19, 21, 5, 21],
    ['l', 14, 3, 14, 8, 19, 8],
    ['t!', 12, 15, 'PDF', 6],
  ],
  'project': [
    ['r', 3, 4, 10, 9],
    ['l', 6.5, 9, 6.5, 18, 13, 18],
    ['l', 6.5, 13, 13, 13],
    ['r!', 13, 11, 21, 15],
    ['r', 13, 16, 21, 20],
  ],
  'revision': [
    ['a', 12, 12, 8, 160, -300],
    ['l', 4.5, 5.5, 4.4, 9.5, 8.4, 9.2],
    ['l!', 12, 8, 12, 12, 15, 14],
  ],
  'check': [
    ['o', 12, 12, 8.5],
    ['l!', 8, 12.3, 11, 15.3, 16.5, 9],
  ],
  'warning': [
    ['p!', 12, 3.5, 21, 20, 3, 20],
    ['l', 12, 9, 12, 14.5],
    ['of', 12, 17.2, 1],
  ],
  'error': [
    ['o!', 12, 12, 8.5],
    ['l', 8.5, 8.5, 15.5, 15.5],
    ['l', 15.5, 8.5, 8.5, 15.5],
  ],
  'info': [
    ['o!', 12, 12, 8.5],
    ['l', 12, 11, 12, 17],
    ['of', 12, 7.6, 1.1],
  ],
  'export': [
    ['l', 4, 14, 4, 20, 20, 20, 20, 14],
    ['l!', 12, 4, 12, 15],
    ['l!', 8, 8, 12, 4, 16, 8],
  ],
  'import': [
    ['l', 4, 14, 4, 20, 20, 20, 20, 14],
    ['l!', 12, 4, 12, 15],
    ['l!', 8, 11, 12, 15, 16, 11],
  ],
  'stock': [
    ['r', 3, 13, 11, 21],
    ['r', 13, 13, 21, 21],
    ['r!', 8, 3, 16, 11],
  ],
  'clock': [
    ['o', 12, 12, 8.5],
    ['l', 12, 7, 12, 12, 15.5, 14],
  ],
  'chevron_right': [
    ['l', 10, 6, 16, 12, 10, 18],
  ],
  'close': [
    ['l', 6, 6, 18, 18],
    ['l', 18, 6, 6, 18],
  ],
  'plus': [
    ['l', 12, 5, 12, 19],
    ['l', 5, 12, 19, 12],
  ],
  'refresh': [
    ['a', 12, 12, 7, 30, 300],
    ['l!', 18.5, 4.5, 18.5, 9.5, 13.5, 9.5],
  ],
  'theme': [
    ['o', 12, 12, 8.5],
    ['pf', 12, 3.5, 12, 20.5, 7, 19, 4, 15, 3.5, 12, 4, 9, 7, 5],
  ],
  'lock': [
    ['r', 6, 11, 18, 20],
    ['l', 8.5, 11, 8.5, 8],
    ['a', 12, 8, 3.5, 0, 180],
    ['l', 15.5, 8, 15.5, 11],
  ],
  'library': [
    ['r', 4, 4, 8, 20],
    ['r', 9.5, 4, 13.5, 20],
    ['p!', 15, 5.5, 18.5, 4.5, 21, 19, 17.5, 20],
  ],
  'settings': [
    ['o', 12, 12, 3],
    for (var i = 0; i < 8; i++)
      [
        'l',
        12 + 5.5 * math.cos(i * math.pi / 4),
        12 + 5.5 * math.sin(i * math.pi / 4),
        12 + 8.5 * math.cos(i * math.pi / 4),
        12 + 8.5 * math.sin(i * math.pi / 4),
      ],
    ['o', 12, 12, 5.5],
  ],
  // FieldWorx's own, drawn on the same grid.
  'scan': [
    ['l', 4, 8.5, 4, 4, 8.5, 4],
    ['l', 15.5, 4, 20, 4, 20, 8.5],
    ['l', 20, 15.5, 20, 20, 15.5, 20],
    ['l', 8.5, 20, 4, 20, 4, 15.5],
    ['l!', 6.5, 12, 17.5, 12],
  ],
  'inspect': [
    ['r', 5, 3.5, 19, 20.5],
    ['l!', 7.8, 9, 9.3, 10.5, 11.8, 7.8],
    ['l', 13.5, 9.3, 16.5, 9.3],
    ['l!', 7.8, 15, 9.3, 16.5, 11.8, 13.8],
    ['l', 13.5, 15.3, 16.5, 15.3],
  ],
  'asset': [
    ['r', 3, 8, 21, 19],
    ['o', 8.5, 13.5, 2.6],
    ['l', 13.5, 11.5, 18, 11.5],
    ['l', 13.5, 15.5, 18, 15.5],
    ['l!', 6, 8, 6, 5, 11, 5, 11, 8],
  ],
  'camera': [
    ['r', 3, 7, 21, 19],
    ['l', 8, 7, 9.5, 4.5, 14.5, 4.5, 16, 7],
    ['o!', 12, 13, 3.5],
  ],
  'torch': [
    ['p', 8, 3, 16, 3, 16, 7, 14, 10, 14, 21, 10, 21, 10, 10, 8, 7],
    ['l!', 12, 13.5, 12, 16.5],
  ],
  'keyboard': [
    ['r', 3, 6, 21, 18],
    ['l', 6.5, 10, 7.5, 10],
    ['l', 10, 10, 11, 10],
    ['l', 13, 10, 14, 10],
    ['l', 16.5, 10, 17.5, 10],
    ['l!', 7, 14, 17, 14],
  ],
  'qr': [
    ['r', 4, 4, 10, 10],
    ['r', 14, 4, 20, 10],
    ['r', 4, 14, 10, 20],
    ['r!', 14, 14, 16.5, 16.5],
    ['l', 19.5, 14, 19.5, 19.5, 14, 19.5],
  ],
  'package': [
    ['p', 12, 3, 20, 7, 20, 17, 12, 21, 4, 17, 4, 7],
    ['l', 4, 7, 12, 11, 20, 7],
    ['l', 12, 11, 12, 21],
    ['l!', 8, 5, 16, 9],
  ],
  'person': [
    ['o', 12, 8, 3.8],
    ['a!', 12, 21, 7.5, 0, 180],
  ],
  'note': [
    ['p', 5, 4, 19, 4, 19, 15, 14, 20, 5, 20],
    ['l', 14, 20, 14, 15, 19, 15],
    ['l!', 8, 9, 16, 9],
    ['l', 8, 12.5, 13, 12.5],
  ],
  'location': [
    ['p', 12, 21, 6.5, 13, 6, 9.5, 8, 5.5, 12, 3.5, 16, 5.5, 18, 9.5, 17.5, 13],
    ['o!', 12, 9.5, 2.5],
  ],
};

class FxIcon extends StatelessWidget {
  const FxIcon(this.name, {super.key, this.size = 24, this.color, this.accent, this.semanticLabel});
  final String name;
  final double size;
  final Color? color, accent;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    final icon = CustomPaint(
      size: Size.square(size),
      painter: _FxIconPainter(fxIcons[name] ?? fxIcons['document']!, color ?? fx.text, accent ?? fx.accent),
    );
    return semanticLabel == null ? ExcludeSemantics(child: icon) : Semantics(label: semanticLabel, child: icon);
  }
}

class _FxIconPainter extends CustomPainter {
  _FxIconPainter(this.ops, this.color, this.accent);
  final List<_Op> ops;
  final Color color, accent;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24.0;
    final w = math.max(1.0, 1.6 * k);
    double n(Object v) => (v as num).toDouble();
    for (final op in ops) {
      final kind = (op[0] as String).replaceAll('!', '');
      final col = (op[0] as String).endsWith('!') ? accent : color;
      final stroke = Paint()
        ..color = col
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final fill = Paint()
        ..color = col
        ..style = PaintingStyle.fill;
      final args = op.sublist(1);
      switch (kind) {
        case 'l':
        case 'p':
        case 'pf':
          final path = Path()..moveTo(n(args[0]) * k, n(args[1]) * k);
          for (var i = 2; i + 1 < args.length; i += 2) {
            path.lineTo(n(args[i]) * k, n(args[i + 1]) * k);
          }
          if (kind != 'l') path.close();
          if (kind == 'pf') canvas.drawPath(path, fill);
          canvas.drawPath(path, stroke);
        case 'r':
          canvas.drawRRect(
              RRect.fromLTRBR(n(args[0]) * k, n(args[1]) * k, n(args[2]) * k, n(args[3]) * k, Radius.circular(1.2 * k)),
              stroke);
        case 'o':
          canvas.drawCircle(Offset(n(args[0]) * k, n(args[1]) * k), n(args[2]) * k, stroke);
        case 'of':
          canvas.drawCircle(Offset(n(args[0]) * k, n(args[1]) * k), n(args[2]) * k, fill);
        case 'a':
          final c = Offset(n(args[0]) * k, n(args[1]) * k), r = n(args[2]) * k;
          final start = -n(args[3]) * math.pi / 180, sweep = -n(args[4]) * math.pi / 180;
          canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep, false, stroke);
        case 't':
          final tp = TextPainter(
            text: TextSpan(
                text: args[2] as String,
                style: TextStyle(color: col, fontSize: n(args[3]) * k * 1.25, fontWeight: FontWeight.w700)),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(n(args[0]) * k - tp.width / 2, n(args[1]) * k - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_FxIconPainter old) => old.ops != ops || old.color != color || old.accent != accent;
}
