// SPDX-License-Identifier: GPL-3.0-or-later
// The real phone: camera scanning (zxing-cpp through flutter_zxing), drawings (PDFium through pdfrx), the system
// camera for photos, the system file picker and share sheet. Nothing here talks to a network.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_zxing/flutter_zxing.dart'
    show Code, EccLevel, EncodeParams, Format, ReaderWidget, ResolutionPreset, zx;
import 'package:image_picker/image_picker.dart' as ip;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart' as pp;
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart' as sp;

import '../theme/theme.dart';
import 'services.dart';

class PluginServices implements FieldServices {
  @override
  Future<Directory> dataDirectory() async => Directory('${(await pp.getApplicationSupportDirectory()).path}/fieldworx');

  @override
  Future<Directory> exportDirectory() async {
    final d = Directory('${(await pp.getTemporaryDirectory()).path}/fieldworx-out');
    await d.create(recursive: true);
    return d;
  }

  @override
  Future<File?> pickFile({required String title, required List<String> extensions}) async {
    // No type filter: Android and iOS don't know FieldWorx's file types, and a filter would hide them. The file is
    // checked completely after it's chosen anyway.
    final f = await fs.openFile(confirmButtonText: title);
    return f == null ? null : File(f.path);
  }

  @override
  Future<File?> takePhoto() async {
    final x = await ip.ImagePicker().pickImage(source: ip.ImageSource.camera, maxWidth: 2400, imageQuality: 85);
    return x == null ? null : File(x.path);
  }

  @override
  Future<void> shareFile(File file, {required String subject, String? text}) async {
    await sp.SharePlus.instance.share(sp.ShareParams(files: [sp.XFile(file.path)], subject: subject, text: text));
  }

  @override
  Future<File> demoPackage() async {
    final data = await rootBundle.load('assets/demo/demo.fieldworx');
    final f = File('${(await exportDirectory()).path}/demo.fieldworx');
    await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    return f;
  }

  @override
  Widget scanner({Key? key, required ValueChanged<String> onCode}) => _Scanner(key: key, onCode: onCode);

  @override
  Widget pdfViewer({Key? key, required File file, required ViewerHandle handle}) =>
      _PdfView(key: key, file: file, handle: handle);

  @override
  Widget qrCode(String text, {double size = 220}) => _Qr(text: text, size: size);
}

class _Scanner extends StatelessWidget {
  const _Scanner({super.key, required this.onCode});
  final ValueChanged<String> onCode;

  @override
  Widget build(BuildContext context) => ReaderWidget(
        onScan: (Code code) {
          final t = code.text;
          if (code.isValid && t != null && t.isNotEmpty) onCode(t);
        },
        codeFormat: Format.any,
        tryHarder: true,
        tryInverted: true,
        showGallery: false,
        showToggleCamera: false,
        showFlashlight: true,
        showScannerOverlay: false,
        cropPercent: 0.7,
        resolution: ResolutionPreset.high,
        scanDelay: const Duration(milliseconds: 250),
        scanDelaySuccess: const Duration(milliseconds: 1500),
        actionButtonsAlignment: Alignment.bottomRight,
        actionButtonsPadding: const EdgeInsets.all(16),
      );
}

class _PdfView extends StatefulWidget {
  const _PdfView({super.key, required this.file, required this.handle});
  final File file;
  final ViewerHandle handle;

  @override
  State<_PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<_PdfView> {
  final _controller = PdfViewerController();
  late final PdfTextSearcher _searcher = PdfTextSearcher(_controller)..addListener(_onSearch);

  @override
  void initState() {
    super.initState();
    final h = widget.handle;
    h.onSearch = (t) => t.trim().isEmpty ? _searcher.resetTextSearch() : _searcher.startTextSearch(t.trim());
    h.onNext = () => _searcher.goToNextMatch();
    h.onPrevious = () => _searcher.goToPrevMatch();
    h.onClear = () => _searcher.resetTextSearch();
    h.onZoomIn = () => _controller.zoomUp();
    h.onZoomOut = () => _controller.zoomDown();
  }

  void _onSearch() {
    widget.handle.update(
      matchCount: _searcher.matches.length,
      matchIndex: _searcher.currentIndex ?? -1,
      searching: _searcher.isSearching,
    );
  }

  @override
  void dispose() {
    _searcher.removeListener(_onSearch);
    _searcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.fx;
    return PdfViewer.file(
      widget.file.path,
      controller: _controller,
      params: PdfViewerParams(
        backgroundColor: fx.dark ? const Color(0xFF15171A) : const Color(0xFFE4E7EB),
        margin: 10,
        pagePaintCallbacks: [_searcher.pageTextMatchPaintCallback],
        onViewerReady: (doc, controller) => widget.handle.update(pages: doc.pages.length, page: 1),
        onPageChanged: (n) => widget.handle.update(page: n ?? 0),
        errorBannerBuilder: (context, error, stackTrace, documentRef) {
          WidgetsBinding.instance.addPostFrameCallback((_) => widget.handle.update(error: '$error'));
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('This drawing can’t be shown: $error', textAlign: TextAlign.center),
            ),
          );
        },
      ),
    );
  }
}

class _Qr extends StatelessWidget {
  const _Qr({required this.text, required this.size});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final e = zx.encodeBarcode(
      contents: text,
      params: EncodeParams(format: Format.qrCode, width: 400, height: 400, margin: 16, eccLevel: EccLevel.medium),
    );
    final data = e.data, w = e.width, h = e.height;
    if (!e.isValid || data == null || w == null || h == null) {
      return SizedBox.square(dimension: size, child: Center(child: Text(e.error ?? 'No QR code')));
    }
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _QrPainter(data, w, h)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data, this.w, this.h);
  final Uint8List data;
  final int w, h;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final black = Paint()..color = const Color(0xFF000000);
    final sx = size.width / w, sy = size.height / h;
    for (var y = 0; y < h; y++) {
      var x = 0;
      while (x < w) {
        if (data[y * w + x] < 128) {
          final start = x;
          while (x < w && data[y * w + x] < 128) {
            x++;
          }
          canvas.drawRect(Rect.fromLTWH(start * sx, y * sy, (x - start) * sx + 0.5, sy + 0.5), black);
        } else {
          x++;
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}
