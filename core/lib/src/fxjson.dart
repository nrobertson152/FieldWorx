// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical JSON (docs/PROTOCOL.md section 2). Must produce exactly the bytes the Python reference
// (bridge/fieldworx_bridge/fxjson.py) produces; spec/vectors/fxjson.json keeps them in step.
//
// Values: null, bool, int within +/-(2^53 - 1), String, List, Map<String, Object?>. No doubles anywhere:
// decimals travel as strings. Keys sort by code point, no whitespace, minimal escapes.

import 'dart:convert';
import 'dart:typed_data';

import 'sha256.dart';

const int maxSafeInt = 9007199254740991;
const int maxDepth = 64;

class FxJsonError implements Exception {
  FxJsonError(this.message);
  final String message;
  @override
  String toString() => 'FxJsonError: $message';
}

/// Compares two strings by Unicode code point (which is also UTF-8 byte order).
int compareCodePoints(String a, String b) {
  final ra = a.runes.iterator, rb = b.runes.iterator;
  while (true) {
    final ha = ra.moveNext(), hb = rb.moveNext();
    if (!ha || !hb) return ha == hb ? 0 : (ha ? 1 : -1);
    final d = ra.current - rb.current;
    if (d != 0) return d;
  }
}

void _string(String s, StringBuffer out) {
  out.writeCharCode(0x22);
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 < s.length) {
        final d = s.codeUnitAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) {
          out.writeCharCode(c);
          out.writeCharCode(d);
          i++;
          continue;
        }
      }
      throw FxJsonError('text contains an unpaired surrogate');
    }
    if (c >= 0xDC00 && c <= 0xDFFF) throw FxJsonError('text contains an unpaired surrogate');
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (c < 0x20) {
          out.write(r'\u00');
          out.write(c.toRadixString(16).padLeft(2, '0'));
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.writeCharCode(0x22);
}

void _encode(Object? v, StringBuffer out, int depth) {
  if (depth > maxDepth) throw FxJsonError('nested more than $maxDepth levels');
  if (v == null) {
    out.write('null');
  } else if (v is bool) {
    out.write(v ? 'true' : 'false');
  } else if (v is int) {
    if (v > maxSafeInt || v < -maxSafeInt) throw FxJsonError('integer $v is outside +/-(2^53 - 1)');
    out.write(v.toString());
  } else if (v is double) {
    throw FxJsonError('floating-point numbers are not allowed; send decimals as text');
  } else if (v is String) {
    _string(v, out);
  } else if (v is List) {
    out.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) out.write(',');
      _encode(v[i], out, depth + 1);
    }
    out.write(']');
  } else if (v is Map) {
    final keys = <String>[];
    for (final k in v.keys) {
      if (k is! String) throw FxJsonError('object keys must be text');
      keys.add(k);
    }
    keys.sort(compareCodePoints);
    out.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) out.write(',');
      _string(keys[i], out);
      out.write(':');
      _encode(v[keys[i]], out, depth + 1);
    }
    out.write('}');
  } else {
    throw FxJsonError('cannot encode ${v.runtimeType}');
  }
}

/// Canonical text of [value].
String encodeText(Object? value) {
  final out = StringBuffer();
  _encode(value, out, 0);
  return out.toString();
}

/// Canonical bytes (UTF-8) of [value].
Uint8List encode(Object? value) => Uint8List.fromList(utf8.encode(encodeText(value)));

/// Parses JSON strictly: no floats, constants, duplicate keys, unpaired surrogates or nesting deeper than 64.
/// The input need not be canonical.
Object? parse(String text) {
  final p = _Parser(text);
  p.ws();
  final v = p.value(0);
  p.ws();
  if (p.i != text.length) p.fail('unexpected text after the value');
  return v;
}

Object? parseBytes(List<int> data) {
  final String text;
  try {
    text = utf8.decode(data);
  } on FormatException {
    throw FxJsonError('not UTF-8');
  }
  return parse(text);
}

/// Parses bytes that must already be canonical: re-encoding gives exactly the same bytes.
Object? parseCanonical(List<int> data) {
  final v = parseBytes(data);
  final again = encode(v);
  if (again.length != data.length) throw FxJsonError('not in canonical form');
  for (var i = 0; i < again.length; i++) {
    if (again[i] != data[i]) throw FxJsonError('not in canonical form');
  }
  return v;
}

/// SHA-256 (hex) of `fieldworx/<domain>\0` followed by [canonical].
String digestBytes(String domain, List<int> canonical) {
  final h = Sha256()
    ..add(ascii.encode('fieldworx/$domain'))
    ..add(const [0])
    ..add(canonical);
  return h.hexDigest();
}

String digest(String domain, Object? value) => digestBytes(domain, encode(value));

class _Parser {
  _Parser(this.s);
  final String s;
  int i = 0;

  Never fail(String why) => throw FxJsonError('not valid JSON: $why at $i');

  void ws() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
      } else {
        break;
      }
    }
  }

  Object? value(int depth) {
    if (depth > maxDepth) throw FxJsonError('nested more than $maxDepth levels');
    if (i >= s.length) fail('unexpected end');
    final c = s.codeUnitAt(i);
    if (c == 0x7B) return object(depth);
    if (c == 0x5B) return array(depth);
    if (c == 0x22) return string();
    if (c == 0x2D || (c >= 0x30 && c <= 0x39)) return number();
    if (s.startsWith('true', i)) {
      i += 4;
      return true;
    }
    if (s.startsWith('false', i)) {
      i += 5;
      return false;
    }
    if (s.startsWith('null', i)) {
      i += 4;
      return null;
    }
    fail('unexpected character');
  }

  Map<String, Object?> object(int depth) {
    i++;
    final m = <String, Object?>{};
    ws();
    if (i < s.length && s.codeUnitAt(i) == 0x7D) {
      i++;
      return m;
    }
    while (true) {
      ws();
      if (i >= s.length || s.codeUnitAt(i) != 0x22) fail('expected a key');
      final k = string();
      ws();
      if (i >= s.length || s.codeUnitAt(i) != 0x3A) fail('expected :');
      i++;
      ws();
      if (m.containsKey(k)) throw FxJsonError("key '$k' appears twice");
      m[k] = value(depth + 1);
      ws();
      if (i >= s.length) fail('unexpected end');
      final c = s.codeUnitAt(i);
      i++;
      if (c == 0x2C) continue;
      if (c == 0x7D) return m;
      fail('expected , or }');
    }
  }

  List<Object?> array(int depth) {
    i++;
    final l = <Object?>[];
    ws();
    if (i < s.length && s.codeUnitAt(i) == 0x5D) {
      i++;
      return l;
    }
    while (true) {
      ws();
      l.add(value(depth + 1));
      ws();
      if (i >= s.length) fail('unexpected end');
      final c = s.codeUnitAt(i);
      i++;
      if (c == 0x2C) continue;
      if (c == 0x5D) return l;
      fail('expected , or ]');
    }
  }

  int number() {
    final start = i;
    if (s.codeUnitAt(i) == 0x2D) i++;
    if (i >= s.length) fail('bad number');
    if (s.codeUnitAt(i) == 0x30) {
      i++;
    } else if (s.codeUnitAt(i) >= 0x31 && s.codeUnitAt(i) <= 0x39) {
      while (i < s.length && s.codeUnitAt(i) >= 0x30 && s.codeUnitAt(i) <= 0x39) {
        i++;
      }
    } else {
      fail('bad number');
    }
    if (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x2E || c == 0x65 || c == 0x45) {
        throw FxJsonError('number is not an integer; send decimals as text');
      }
    }
    final text = s.substring(start, i);
    if (text.length > 17) throw FxJsonError('integer $text is outside +/-(2^53 - 1)');
    final v = int.parse(text);
    if (v > maxSafeInt || v < -maxSafeInt) throw FxJsonError('integer $text is outside +/-(2^53 - 1)');
    return v;
  }

  String string() {
    i++;
    final out = StringBuffer();
    while (true) {
      if (i >= s.length) fail('unterminated string');
      final c = s.codeUnitAt(i);
      if (c == 0x22) {
        i++;
        break;
      }
      if (c < 0x20) fail('control character in string');
      if (c == 0x5C) {
        i++;
        if (i >= s.length) fail('bad escape');
        final e = s.codeUnitAt(i);
        i++;
        switch (e) {
          case 0x22:
            out.writeCharCode(0x22);
          case 0x5C:
            out.writeCharCode(0x5C);
          case 0x2F:
            out.writeCharCode(0x2F);
          case 0x62:
            out.writeCharCode(0x08);
          case 0x66:
            out.writeCharCode(0x0C);
          case 0x6E:
            out.writeCharCode(0x0A);
          case 0x72:
            out.writeCharCode(0x0D);
          case 0x74:
            out.writeCharCode(0x09);
          case 0x75:
            out.writeCharCode(hex4());
          default:
            fail('bad escape');
        }
      } else {
        out.writeCharCode(c);
        i++;
      }
    }
    final r = out.toString();
    _checkSurrogates(r);
    return r;
  }

  int hex4() {
    if (i + 4 > s.length) fail('bad \\u escape');
    final h = s.substring(i, i + 4);
    final v = int.tryParse(h, radix: 16);
    if (v == null || h.contains(RegExp(r'[^0-9a-fA-F]'))) fail('bad \\u escape');
    i += 4;
    return v;
  }
}

void _checkSurrogates(String r) {
  for (var k = 0; k < r.length; k++) {
    final c = r.codeUnitAt(k);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (k + 1 < r.length) {
        final d = r.codeUnitAt(k + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) {
          k++;
          continue;
        }
      }
      throw FxJsonError('text contains an unpaired surrogate');
    }
    if (c >= 0xDC00 && c <= 0xDFFF) throw FxJsonError('text contains an unpaired surrogate');
  }
}

/// Typed access helpers for decoded JSON (throw [FxJsonError] on a wrong shape).
Map<String, Object?> asMap(Object? v, String what) {
  if (v is Map<String, Object?>) return v;
  if (v is Map) {
    return v.map((k, val) {
      if (k is! String) throw FxJsonError('$what has a non-text key');
      return MapEntry(k, val);
    });
  }
  throw FxJsonError('$what must be an object');
}

List<Object?> asList(Object? v, String what) {
  if (v is List) return v.cast<Object?>();
  throw FxJsonError('$what must be a list');
}

String asString(Object? v, String what) {
  if (v is String) return v;
  throw FxJsonError('$what must be text');
}

int asInt(Object? v, String what) {
  if (v is int) return v;
  throw FxJsonError('$what must be an integer');
}

bool asBool(Object? v, String what) {
  if (v is bool) return v;
  throw FxJsonError('$what must be true or false');
}
