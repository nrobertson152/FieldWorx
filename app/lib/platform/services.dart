// SPDX-License-Identifier: GPL-3.0-or-later
// What FieldWorx needs from the phone, behind one interface so screens can be tested without a camera, a PDF
// engine or a file picker (test/fakes.dart implements it). The real implementation is in plugins.dart.

import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// Lets a screen drive the drawing viewer (page, zoom, find text) without knowing which engine draws it.
class ViewerHandle extends ChangeNotifier {
  int page = 0;
  int pages = 0;
  int matchIndex = -1;
  int matchCount = 0;
  bool searching = false;
  String? error;

  // Set by the viewer implementation.
  void Function(String text)? onSearch;
  void Function()? onNext, onPrevious, onClear, onZoomIn, onZoomOut, onFit;

  void search(String text) => onSearch?.call(text);
  void next() => onNext?.call();
  void previous() => onPrevious?.call();
  void clear() => onClear?.call();
  void zoomIn() => onZoomIn?.call();
  void zoomOut() => onZoomOut?.call();
  void fit() => onFit?.call();

  void update({int? page, int? pages, int? matchIndex, int? matchCount, bool? searching, String? error}) {
    this.page = page ?? this.page;
    this.pages = pages ?? this.pages;
    this.matchIndex = matchIndex ?? this.matchIndex;
    this.matchCount = matchCount ?? this.matchCount;
    this.searching = searching ?? this.searching;
    this.error = error ?? this.error;
    notifyListeners();
  }
}

abstract class FieldServices {
  /// Where the store lives (kept out of backups: see android/app/src/main/res/xml).
  Future<Directory> dataDirectory();

  /// A scratch folder for field logs being shared.
  Future<Directory> exportDirectory();

  /// Lets the person choose a file; null if they cancelled.
  Future<File?> pickFile({required String title, required List<String> extensions});

  /// Takes a photo with the system camera; null if they cancelled.
  Future<File?> takePhoto();

  /// Hands a file to the system share sheet (USB, e-mail, a shared drive app, nearby share...).
  Future<void> shareFile(File file, {required String subject, String? text});

  /// The demo package shipped with the app, as a file.
  Future<File> demoPackage();

  /// The camera scanner. [onCode] gets each decoded label once.
  Widget scanner({Key? key, required ValueChanged<String> onCode});

  /// A PDF drawing, pinch-zoomable, searchable through [handle].
  Widget pdfViewer({Key? key, required File file, required ViewerHandle handle});

  /// A QR code for [text].
  Widget qrCode(String text, {double size = 220});
}
