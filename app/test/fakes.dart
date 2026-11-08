// SPDX-License-Identifier: GPL-3.0-or-later
// The phone, faked for widget tests: no camera, PDF engine, file picker or share sheet, but a real store in a
// temporary folder, so every test goes through the same files, checks and records the app uses on a phone.

import 'dart:io';
import 'dart:typed_data';

import 'package:fieldworx/model/app_model.dart';
import 'package:fieldworx/platform/services.dart';
import 'package:fieldworx/screens/shell.dart';
import 'package:fieldworx/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The demo package the app ships. `flutter test` runs with the app folder as its working directory.
final File demoFile = File('assets/demo/demo.fieldworx');

class FakeServices implements FieldServices {
  FakeServices(this.root);

  /// A fresh temporary folder for this phone.
  factory FakeServices.temp() => FakeServices(Directory.systemTemp.createTempSync('fieldworx-test-'));

  final Directory root;

  /// What the file picker returns next, in order; when empty the person "cancels".
  final List<File> picks = [];

  /// Everything handed to the share sheet.
  final List<File> shared = [];

  int photosTaken = 0;
  bool cameraFails = false;
  ValueChanged<String>? _onCode;

  /// The viewer handle of the drawing on screen, if any.
  ViewerHandle? viewer;

  /// Is the camera scanner on screen (and so running)?
  bool get scanning => _onCode != null;

  /// What the camera sees: hands [code] to the scanner on screen, as if it decoded a label.
  void scan(String code) {
    final f = _onCode;
    if (f == null) throw StateError('the scanner is not on screen');
    f(code);
  }

  @override
  Future<Directory> dataDirectory() async => Directory('${root.path}/data')..createSync(recursive: true);

  /// What the phone couldn't do: a test adds to it before the app opens.
  @override
  final List<String> platformWarnings = [];

  @override
  Future<Directory> exportDirectory() async => Directory('${root.path}/export')..createSync(recursive: true);

  @override
  Future<File?> pickFile({required String title, required List<String> extensions}) async =>
      picks.isEmpty ? null : picks.removeAt(0);

  @override
  Future<File?> takePhoto() async {
    if (cameraFails) throw const FileSystemException('no camera');
    photosTaken++;
    final f = File('${root.path}/photo-$photosTaken.png');
    await f.writeAsBytes(tinyPng(photosTaken));
    return f;
  }

  @override
  Future<void> shareFile(File file, {required String subject, String? text}) async => shared.add(file);

  @override
  Future<File> demoPackage() async => demoFile;

  @override
  Widget scanner({Key? key, required ValueChanged<String> onCode}) => _FakeScanner(key: key, services: this, onCode: onCode);

  @override
  Widget pdfViewer({Key? key, required File file, required ViewerHandle handle}) =>
      _FakePdf(key: key, services: this, file: file, handle: handle);

  @override
  Widget qrCode(String text, {double size = 220}) =>
      SizedBox.square(dimension: size, child: Center(child: Text('QR $text')));
}

class _FakeScanner extends StatefulWidget {
  const _FakeScanner({super.key, required this.services, required this.onCode});
  final FakeServices services;
  final ValueChanged<String> onCode;

  @override
  State<_FakeScanner> createState() => _FakeScannerState();
}

class _FakeScannerState extends State<_FakeScanner> {
  @override
  void initState() {
    super.initState();
    widget.services._onCode = widget.onCode;
  }

  @override
  void didUpdateWidget(_FakeScanner old) {
    super.didUpdateWidget(old);
    widget.services._onCode = widget.onCode;
  }

  @override
  void dispose() {
    widget.services._onCode = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFF202020), child: Center(child: Text('camera')));
}

/// Shows the drawing's size and answers "find text" by looking for the text in the PDF's bytes (the demo drawings
/// are written uncompressed), which is enough to drive the viewer's controls.
class _FakePdf extends StatefulWidget {
  const _FakePdf({super.key, required this.services, required this.file, required this.handle});
  final FakeServices services;
  final File file;
  final ViewerHandle handle;

  @override
  State<_FakePdf> createState() => _FakePdfState();
}

class _FakePdfState extends State<_FakePdf> {
  late final String _text = String.fromCharCodes(widget.file.readAsBytesSync());
  int zoom = 0;

  @override
  void initState() {
    super.initState();
    final h = widget.handle;
    widget.services.viewer = h;
    h.onSearch = (q) {
      final n = q.isEmpty ? 0 : q.allMatches(_text).length;
      h.update(matchCount: n, matchIndex: n == 0 ? -1 : 0, searching: false);
    };
    h.onNext = () => h.update(matchIndex: h.matchCount == 0 ? -1 : (h.matchIndex + 1) % h.matchCount);
    h.onPrevious =
        () => h.update(matchIndex: h.matchCount == 0 ? -1 : (h.matchIndex - 1 + h.matchCount) % h.matchCount);
    h.onClear = () => h.update(matchCount: 0, matchIndex: -1);
    h.onZoomIn = () => setState(() => zoom++);
    h.onZoomOut = () => setState(() => zoom--);
    h.onFit = () => setState(() => zoom = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) h.update(page: 1, pages: 1);
    });
  }

  @override
  void dispose() {
    if (widget.services.viewer == widget.handle) widget.services.viewer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(child: Text('PDF ${widget.file.lengthSync()} bytes, zoom $zoom'));
}

// ---------------------------------------------------------------------------------------------------- helpers

/// A phone screen: 360 × [height] logical pixels at 3x.
void phone(WidgetTester tester, {double width = 360, double height = 780}) {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Opens a phone's store (in real time: file work doesn't run inside the widget test's fake clock), named and,
/// unless [demo] is false, with the demo package added.
Future<(AppModel, FakeServices)> openPhone(WidgetTester tester,
    {String user = 'Riley Field', bool demo = true, List<String> platformWarnings = const []}) async {
  final r = await tester.runAsync(() async {
    final services = FakeServices.temp()..platformWarnings.addAll(platformWarnings);
    final m = await AppModel.open(services);
    if (user.isNotEmpty) await m.setUserName(user);
    if (demo) await m.installPackage(demoFile);
    return (m, services);
  });
  return r!;
}

/// Shows the app for [model], as FieldWorxBoot does once the store is open.
Future<void> showApp(WidgetTester tester, AppModel model) async {
  await tester.pumpWidget(FieldWorxApp(model: model));
  await tester.pump();
}

/// Lets real file work started by a tap finish, then shows the result: file operations run in real time, but what
/// they resume runs on the test's fake clock, so each step of the work needs a turn of each. Repeats until [finder]
/// finds something (and [until] holds); fails with [what] if that never happens.
Future<void> waitFor(WidgetTester tester, Finder? finder, {bool Function()? until, String? what, int frames = 400}) async {
  bool done() => (finder == null || finder.evaluate().isNotEmpty) && (until == null || until());
  for (var i = 0; i < frames; i++) {
    if (done()) {
      await tester.pump(const Duration(milliseconds: 400)); // let a page transition finish
      await tester.pump(const Duration(milliseconds: 400));
      return;
    }
    for (var step = 0; step < 12; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('timed out waiting for ${what ?? finder ?? 'a condition'}');
}

/// Taps [finder] and waits (see [waitFor]) for [next] to appear.
Future<void> tapAndWait(WidgetTester tester, Finder finder, Finder next, {bool Function()? until}) async {
  await tester.tap(finder);
  await waitFor(tester, next, until: until);
}

/// A page's primary or secondary action button, by its label. (No `.first` here or in other finders that may be
/// evaluated before the widget is built: `.first` of nothing throws instead of finding nothing.)
Finder button(String label) => find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>());

/// A 1×1 PNG whose colour depends on [n], so each photo has its own content and hash.
Uint8List tinyPng(int n) {
  Uint8List be32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
  List<int> chunk(String type, List<int> data) {
    final td = [...type.codeUnits, ...data];
    return [...be32(data.length), ...td, ...be32(_crc32(td))];
  }

  final ihdr = [...be32(1), ...be32(1), 8, 2, 0, 0, 0];
  final raw = [0, (n * 37) & 255, (n * 91) & 255, (n * 53) & 255];
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...chunk('IHDR', ihdr),
    ...chunk('IDAT', ZLibCodec().encode(raw)),
    ...chunk('IEND', const []),
  ]);
}

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

Finder navTab(String label) => find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Finder iconButton(String tooltip) => find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip);

/// The list row (EntityRow) showing all of [texts].
Finder row(List<String> texts) =>
    find.byElementPredicate((e) => e.widget is EntityRow && texts.every((t) => _hasText(e, t)), description: 'row $texts');

bool _hasText(Element root, String text) {
  var found = false;
  void visit(Element e) {
    final w = e.widget;
    if (w is Text && w.data == text) found = true;
    if (!found) e.visitChildren(visit);
  }

  visit(root);
  return found;
}

Future<void> back(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).last).pop();
  await tester.pumpAndSettle();
}

/// Scrolls the page until [f] is on screen (from the top, if it isn't built at all).
Future<void> reveal(WidgetTester tester, Finder f) async {
  final scrollable = find.byType(Scrollable).first;
  if (f.evaluate().isEmpty) {
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
  }
  await tester.scrollUntilVisible(f, 250, scrollable: scrollable);
  await tester.pump();
}

/// Scrolls [f] into view and taps it.
Future<void> tapOn(WidgetTester tester, Finder f) async {
  await reveal(tester, f);
  await tester.tap(f);
  await tester.pump();
}
