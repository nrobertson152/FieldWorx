// SPDX-License-Identifier: GPL-3.0-or-later
// The app's state: the on-device store (core/lib/src/store.dart) plus what the screens need to notice changes.

import 'dart:io';

import 'package:fieldworx_core/fieldworx_core.dart';
import 'package:material_ui/material_ui.dart';

import '../platform/services.dart';
import '../version.dart';

class RecentScan {
  RecentScan(this.code, this.time, this.label, this.kind, this.id);
  final String code, time, label, id;
  final ResultKind? kind;
}

class AppModel extends ChangeNotifier {
  AppModel(this.store, this.services);

  final FieldStore store;
  final FieldServices services;
  final List<RecentScan> recentScans = [];
  int _unsent = 0;

  Catalog get catalog => store.catalog;
  String get userName => store.userName;
  String get theme => store.theme;
  int get unsent => _unsent;
  bool get canRecord => store.fieldError == null;

  static Future<AppModel> open(FieldServices services) async {
    final store = await FieldStore.open(await services.dataDirectory());
    final m = AppModel(store, services);
    await m._refreshUnsent();
    return m;
  }

  Future<void> _refreshUnsent() async => _unsent = await store.unsentCount();

  Future<void> _changed() async {
    await _refreshUnsent();
    notifyListeners();
  }

  Future<void> setUserName(String name) async {
    await store.saveSettings({'user': name.trim()});
    notifyListeners();
  }

  Future<void> setTheme(String name) async {
    await store.saveSettings({'theme': name});
    notifyListeners();
  }

  Future<InstallResult> installPackage(File f) async {
    try {
      return await store.installPackage(f);
    } finally {
      await _changed();
    }
  }

  Future<void> removePackage(String id) async {
    await store.removePackage(id);
    await _changed();
  }

  Future<ImportResult> importFieldLog(File f) async {
    try {
      return await store.importFieldLog(f);
    } finally {
      await _changed();
    }
  }

  Future<File> exportFieldLog({bool allPhotos = false}) async {
    final f = await store.exportFieldLog(await services.exportDirectory(),
        allPhotos: allPhotos, tool: 'FieldWorx $appVersion (${Platform.operatingSystem})');
    await _changed();
    return f;
  }

  ScanResult resolveScan(String raw) {
    final r = resolve(catalog, raw);
    final first = r.matches.isEmpty ? null : r.matches.first;
    recentScans.removeWhere((s) => s.code == r.code);
    recentScans.insert(0, RecentScan(r.code, utcNow(), first?.title ?? 'Not found', first?.kind, first?.id ?? ''));
    if (recentScans.length > 20) recentScans.removeLast();
    notifyListeners();
    return r;
  }

  // ------------------------------------------------------------------------------------------ inspections
  List<Map<String, Object?>> inspections() => store.inspections();
  Map<String, Object?> inspection(String id) => store.inspection(id);

  /// Inspections recorded against an asset, part or document, newest first; [also] adds records made against its
  /// earlier ids (a unit's `ast_` id from an asset register row, from before it joined RevisionWorx's unit register).
  List<Map<String, Object?>> inspectionsFor(String subjectId, {Iterable<String> also = const []}) {
    final ids = {subjectId, ...also};
    final out = [
      for (final s in store.inspections())
        if (s['valid'] == true && ids.contains((s['subject'] as Map)['id'])) s,
    ]..sort((a, b) => ((b['started'] as Map)['time'] as String).compareTo((a['started'] as Map)['time'] as String));
    return out;
  }

  Future<String> startInspection(TemplateEntry t, {required String title, Map<String, String>? subject}) async {
    final id = await store.startInspection(t, title: title, subject: subject);
    await _changed();
    return id;
  }

  Future<void> answer(String ins, String item, Map<String, Object?> value, {String note = ''}) async {
    await store.record('inspection.answer', ins, {'item': item, 'value': value, 'note': note});
    await _changed();
  }

  Future<void> note(String ins, String text, {String item = ''}) async {
    await store.record('inspection.note', ins, {'text': text, 'item': item});
    await _changed();
  }

  Future<void> attachPhoto(String ins, File photo, {String item = '', String caption = ''}) async {
    final (sha, size) = await store.addFile(photo);
    await store.record('inspection.attach', ins,
        {'object': sha, 'size': size, 'media_type': photoMediaType(photo.path), 'item': item, 'caption': caption});
    await _changed();
  }

  Future<void> complete(String ins, String result, String summary) async {
    await store.record('inspection.complete', ins, {'result': result, 'summary': summary});
    await _changed();
  }

  Future<void> reopen(String ins, String reason) async {
    await store.record('inspection.reopen', ins, {'reason': reason});
    await _changed();
  }

  Future<void> voidInspection(String ins, String reason) async {
    await store.record('inspection.void', ins, {'reason': reason});
    await _changed();
  }

  // --------------------------------------------------------------------------------------------- findings
  Map<String, Object?> finding(String id) => store.finding(id);

  /// Findings about a unit (or its earlier ids), newest first.
  List<Map<String, Object?>> findingsFor(String assetId, {Iterable<String> also = const []}) {
    final ids = {assetId, ...also};
    final out = [
      for (final s in store.findings())
        if (s['valid'] == true && ids.contains(s['asset'])) s,
    ]..sort((a, b) => ((b['recorded'] as Map)['time'] as String).compareTo((a['recorded'] as Map)['time'] as String));
    return out;
  }

  Future<String> recordFinding(Map<String, Object?> body) async {
    final id = await store.recordFinding(body);
    await _changed();
    return id;
  }

  Future<void> attachFindingPhoto(String id, File photo, {String caption = ''}) async {
    final (sha, size) = await store.addFile(photo);
    await store.record('finding.attach', id,
        {'object': sha, 'size': size, 'media_type': photoMediaType(photo.path), 'caption': caption});
    await _changed();
  }

  Future<void> voidFinding(String id, String reason) async {
    await store.record('finding.void', id, {'reason': reason});
    await _changed();
  }

  File objectFile(String sha) => store.objectFile(sha);
}

/// The media type of a photo from the camera or gallery, by its file name (cameras write JPEG; some phones HEIC).
String photoMediaType(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.heic') || p.endsWith('.heif')) return 'image/heic';
  if (p.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

/// Makes the model available to every screen below it.
class AppScope extends InheritedNotifier<AppModel> {
  const AppScope({super.key, required AppModel model, required super.child}) : super(notifier: model);

  static AppModel of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppModel read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
