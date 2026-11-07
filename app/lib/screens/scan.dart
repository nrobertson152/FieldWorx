// SPDX-License-Identifier: GPL-3.0-or-later
// Scanning, the centre of the app: point the camera at a label (or type the code, or use a rugged phone's built-in
// scanner, which types into the field below) and go straight to what it is. Several matches are shown, never
// guessed; no match says so and offers a search.

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../model/app_model.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/fx_icon.dart';
import 'entities.dart';
import 'find.dart';
import 'library.dart';

class ScanTab extends StatefulWidget {
  const ScanTab({super.key, required this.active});

  /// The camera runs only while the tab is showing and nothing is on top of it.
  final bool active;

  @override
  State<ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<ScanTab> {
  final _typed = TextEditingController();
  bool _away = false;
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _handle(String raw) async {
    final now = DateTime.now();
    if (_away || (raw == _last && now.difference(_lastAt).inMilliseconds < 2500)) return;
    _last = raw;
    _lastAt = now;
    HapticFeedback.mediumImpact();
    final m = AppScope.read(context);
    final r = m.resolveScan(raw);
    setState(() => _away = true);
    if (r.isUnique) {
      final x = r.matches.single;
      await openEntity(context, x.kind, x.id);
    } else {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ScanResultScreen(result: r)));
    }
    if (mounted) setState(() => _away = false);
  }

  Future<void> _openTyped() async {
    final t = _typed.text.trim();
    if (t.isEmpty) return;
    _typed.clear();
    _last = null;
    await _handle(t);
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final fx = context.fx;
    if (m.catalog.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('FieldWorx')),
        body: Center(child: SingleChildScrollView(child: NoPackage())),
      );
    }
    final camera = widget.active && !_away;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan')),
      body: Column(children: [
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            color: const Color(0xFF000000),
            child: Stack(fit: StackFit.expand, children: [
              if (camera) m.services.scanner(onCode: _handle),
              if (!camera)
                Center(
                  child: Text('Camera paused', style: TextStyle(color: const Color(0xFFFFFFFF).withValues(alpha: 0.7))),
                ),
              IgnorePointer(child: CustomPaint(painter: _FramePainter(fx.accent))),
              Positioned(
                left: 16,
                right: 16,
                top: 14,
                child: Text(
                  'Point at a FieldWorx label, a part number barcode or a serial plate',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 14, shadows: [Shadow(blurRadius: 4)]),
                ),
              ),
            ]),
          ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 20), children: [
            TextField(
              controller: _typed,
              textInputAction: TextInputAction.go,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: 'Type a code, or use the phone’s scanner key',
                prefixIcon: const Padding(padding: EdgeInsets.all(12), child: FxIcon('keyboard', size: 22)),
                suffixIcon: IconButton(onPressed: _openTyped, icon: const FxIcon('chevron_right')),
              ),
              onSubmitted: (_) => _openTyped(),
            ),
            if (m.recentScans.isNotEmpty) ...[
              const SectionHeader('Recent'),
              RowsCard(children: [
                for (final s in m.recentScans.take(8))
                  EntityRow(
                    icon: s.kind == null ? 'warning' : kindIcon(s.kind!),
                    title: s.label,
                    subtitle: '${s.code} · ${shortTime(s.time).substring(11)}',
                    onTap: s.kind == null
                        ? () {
                            _last = null;
                            _handle(s.code);
                          }
                        : () => openEntity(context, s.kind!, s.id),
                  ),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The same square the decoder scans (cropPercent 0.7 of the shorter side).
    final side = size.shortestSide * 0.7;
    final r = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    final shade = Paint()..color = const Color(0x66000000);
    canvas.drawPath(
        Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size),
            Path()..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(14)))),
        shade);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final l = side * 0.16;
    for (final (c, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(c, c + Offset(l * dx, 0), p);
      canvas.drawLine(c, c + Offset(0, l * dy), p);
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.color != color;
}

class ScanResultScreen extends StatelessWidget {
  const ScanResultScreen({super.key, required this.result});
  final ScanResult result;

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    final r = result;
    return Scaffold(
      appBar: AppBar(title: Text(r.matches.isEmpty ? 'Not found' : '${r.matches.length} matches')),
      body: PageList(children: [
        StatusBlock(
          icon: 'scan',
          kind: r.typed == null ? 'Scanned' : 'FieldWorx label: ${kindName(r.typed!)}',
          title: r.code,
          subtitle: r.raw.trim() != r.code ? r.raw.trim() : '',
        ),
        if (r.matches.isEmpty) ...[
          const SizedBox(height: 12),
          NoticeBanner(
            'Nothing in this phone’s packages has this ${r.typed == null ? 'code' : kindName(r.typed!).toLowerCase()} '
            'as a tag, serial, part, project or document number, maker’s or supplier’s code, or reference designator. '
            'It may be in a package that isn’t on this phone, or the label may be wrong.',
            tone: Tone.warn,
          ),
          const SizedBox(height: 12),
          SecondaryAction('Search for “${r.code}”',
              icon: 'search',
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => SearchPage(initial: r.code)))),
        ] else ...[
          const SizedBox(height: 6),
          Text('This code matches more than one thing. Choose:', style: TextStyle(color: fx.muted)),
          const SizedBox(height: 8),
          RowsCard(children: [
            for (final x in r.matches)
              EntityRow(
                icon: kindIcon(x.kind),
                title: x.title,
                subtitle: [kindName(x.kind), x.subtitle].where((s) => s.isNotEmpty).join(' · '),
                chips: [StatusChip(x.why)],
                onTap: () => openEntity(context, x.kind, x.id),
              ),
          ]),
        ],
      ]),
    );
  }
}

/// Search as its own page (from a scan that found nothing).
class SearchPage extends StatelessWidget {
  const SearchPage({super.key, required this.initial});
  final String initial;

  @override
  Widget build(BuildContext context) => SearchBody(initial: initial, standalone: true);
}
