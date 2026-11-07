// SPDX-License-Identifier: GPL-3.0-or-later
/// FieldWorx core: the protocol (canonical JSON, archives, field events, inspections, findings), the engineering catalog,
/// scan resolution and the on-device store. Pure Dart; the Flutter app and the command-line tool both use it.
library;

export 'src/archive.dart';
export 'src/catalog.dart';
export 'src/decimal.dart';
export 'src/events.dart';
export 'src/finding.dart';
export 'src/fxjson.dart' show FxJsonError, encode, encodeText, parse, parseBytes, parseCanonical, digest, digestBytes;
export 'src/inspection.dart';
export 'src/resolver.dart';
export 'src/sha256.dart';
export 'src/store.dart';
export 'src/zip.dart' show ZipError;
