// SPDX-License-Identifier: GPL-3.0-or-later
// Ed25519 signatures (RFC 8032) in pure Dart, because the core has no dependencies (docs/PROTOCOL.md section 12).
//
// The arithmetic is TweetNaCl's (public domain: Bernstein, van Gastel, Janssen, Lange, Schwabe, Smetsers): a field
// element is 16 limbs of 16 bits in 64-bit ints. Decoding a key, and verifying, make the checks RFC 8032 asks for and the
// Python reference (bridge/fieldworx_bridge/ed25519.py) makes: a canonical y, a point of the curve, not x = 0 with the
// sign bit set, and S below the group order. So the two agree on every vector in spec/vectors/signatures.json.

import 'dart:typed_data';

import 'sha512.dart';

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);

Int64List _gf([List<int> init = const []]) {
  final o = Int64List(16);
  for (var i = 0; i < init.length; i++) {
    o[i] = init[i];
  }
  return o;
}

Int64List _fromBig(BigInt v) {
  var x = v % _p;
  final o = Int64List(16);
  final mask = BigInt.from(0xffff);
  for (var i = 0; i < 16; i++) {
    o[i] = (x & mask).toInt();
    x = x >> 16;
  }
  return o;
}

final BigInt _dBig = (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final BigInt _yBig = (BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p;
final BigInt _iBig = BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);
final BigInt _xBig = () {
  final y2 = _yBig * _yBig % _p;
  final x2 = (y2 - BigInt.one) * (_dBig * y2 + BigInt.one).modInverse(_p) % _p;
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) x = x * _iBig % _p;
  return x.isOdd ? _p - x : x;
}();
final Int64List _d = _fromBig(_dBig);
final Int64List _d2 = _fromBig(_dBig * BigInt.two);
final Int64List _bx = _fromBig(_xBig);
final Int64List _by = _fromBig(_yBig);
final Int64List _sqrtM1 = _fromBig(_iBig);

/// The group order L, little-endian.
const List<int> _l = [
  0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
];

void _car(Int64List o) {
  for (var i = 0; i < 16; i++) {
    final c = o[i] >> 16; // arithmetic shift: the floor, for negative limbs too
    o[i] -= c << 16;
    if (i < 15) {
      o[i + 1] += c;
    } else {
      o[0] += 38 * c;
    }
  }
}

void _sel(Int64List p, Int64List q, int b) {
  final c = ~(b - 1);
  for (var i = 0; i < 16; i++) {
    final t = c & (p[i] ^ q[i]);
    p[i] ^= t;
    q[i] ^= t;
  }
}

Uint8List _pack25519(Int64List n) {
  final t = Int64List.fromList(n);
  _car(t);
  _car(t);
  _car(t);
  final m = Int64List(16);
  for (var j = 0; j < 2; j++) {
    m[0] = t[0] - 0xffed;
    for (var i = 1; i < 15; i++) {
      m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
      m[i - 1] &= 0xffff;
    }
    m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
    final b = (m[15] >> 16) & 1;
    m[14] &= 0xffff;
    _sel(t, m, 1 - b);
  }
  final o = Uint8List(32);
  for (var i = 0; i < 16; i++) {
    o[2 * i] = t[i] & 0xff;
    o[2 * i + 1] = (t[i] >> 8) & 0xff;
  }
  return o;
}

Int64List _unpack25519(List<int> n) {
  final o = Int64List(16);
  for (var i = 0; i < 16; i++) {
    o[i] = n[2 * i] + (n[2 * i + 1] << 8);
  }
  o[15] &= 0x7fff;
  return o;
}

Int64List _add(Int64List a, Int64List b) {
  final o = Int64List(16);
  for (var i = 0; i < 16; i++) {
    o[i] = a[i] + b[i];
  }
  return o;
}

Int64List _sub(Int64List a, Int64List b) {
  final o = Int64List(16);
  for (var i = 0; i < 16; i++) {
    o[i] = a[i] - b[i];
  }
  return o;
}

final Int64List _t = Int64List(31);

Int64List _mul(Int64List a, Int64List b) {
  final t = _t;
  for (var i = 0; i < 31; i++) {
    t[i] = 0;
  }
  for (var i = 0; i < 16; i++) {
    final ai = a[i];
    for (var j = 0; j < 16; j++) {
      t[i + j] += ai * b[j];
    }
  }
  for (var i = 0; i < 15; i++) {
    t[i] += 38 * t[i + 16];
  }
  final o = Int64List(16);
  for (var i = 0; i < 16; i++) {
    o[i] = t[i];
  }
  _car(o);
  _car(o);
  return o;
}

Int64List _sq(Int64List a) => _mul(a, a);

Int64List _inv(Int64List i) {
  var c = Int64List.fromList(i);
  for (var a = 253; a >= 0; a--) {
    c = _sq(c);
    if (a != 2 && a != 4) c = _mul(c, i);
  }
  return c;
}

Int64List _pow2523(Int64List i) {
  var c = Int64List.fromList(i);
  for (var a = 250; a >= 0; a--) {
    c = _sq(c);
    if (a != 1) c = _mul(c, i);
  }
  return c;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

bool _neq(Int64List a, Int64List b) => !_same(_pack25519(a), _pack25519(b));

int _par(Int64List a) => _pack25519(a)[0] & 1;

/// p = p + q, in extended coordinates. Every read happens before any write, so p and q may be the same point.
void _addPoint(List<Int64List> p, List<Int64List> q) {
  final a = _mul(_sub(p[1], p[0]), _sub(q[1], q[0]));
  final b = _mul(_add(p[0], p[1]), _add(q[0], q[1]));
  final c = _mul(_mul(p[3], q[3]), _d2);
  var d = _mul(p[2], q[2]);
  d = _add(d, d);
  final e = _sub(b, a), f = _sub(d, c), g = _add(d, c), h = _add(b, a);
  p[0] = _mul(e, f);
  p[1] = _mul(h, g);
  p[2] = _mul(g, f);
  p[3] = _mul(e, h);
}

void _cswap(List<Int64List> p, List<Int64List> q, int b) {
  for (var i = 0; i < 4; i++) {
    _sel(p[i], q[i], b);
  }
}

Uint8List _packPoint(List<Int64List> p) {
  final zi = _inv(p[2]);
  final tx = _mul(p[0], zi), ty = _mul(p[1], zi);
  final r = _pack25519(ty);
  r[31] ^= _par(tx) << 7;
  return r;
}

List<Int64List> _scalarmult(List<Int64List> q0, List<int> s) {
  final p = [_gf(), _gf([1]), _gf([1]), _gf()];
  final q = [for (final x in q0) Int64List.fromList(x)];
  for (var i = 255; i >= 0; i--) {
    final b = (s[i >> 3] >> (i & 7)) & 1;
    _cswap(p, q, b);
    _addPoint(q, p);
    _addPoint(p, p);
    _cswap(p, q, b);
  }
  return p;
}

List<Int64List> _scalarbase(List<int> s) => _scalarmult([_bx, _by, _gf([1]), _mul(_bx, _by)], s);

Uint8List _modL(Int64List x) {
  for (var i = 63; i >= 32; i--) {
    var carry = 0;
    var j = i - 32;
    for (; j < i - 12; j++) {
      x[j] += carry - 16 * x[i] * _l[j - (i - 32)];
      carry = (x[j] + 128) >> 8;
      x[j] -= carry << 8;
    }
    x[j] += carry;
    x[i] = 0;
  }
  var carry = 0;
  for (var j = 0; j < 32; j++) {
    x[j] += carry - (x[31] >> 4) * _l[j];
    carry = x[j] >> 8;
    x[j] &= 255;
  }
  for (var j = 0; j < 32; j++) {
    x[j] -= carry * _l[j];
  }
  final r = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    x[i + 1] += x[i] >> 8;
    r[i] = x[i] & 255;
  }
  return r;
}

Uint8List _reduce(List<int> h) {
  final x = Int64List(64);
  for (var i = 0; i < h.length; i++) {
    x[i] = h[i];
  }
  return _modL(x);
}

Uint8List _expand(List<int> seed) {
  if (seed.length != 32) throw ArgumentError('an Ed25519 seed is 32 bytes');
  final d = sha512(seed);
  d[0] &= 248;
  d[31] &= 127;
  d[31] |= 64;
  return d;
}

/// The point [key] encodes, or null: y below p, on the curve, and not x = 0 with the sign bit set (RFC 8032, 5.1.3).
List<Int64List>? _decode(List<int> key) {
  if (key.length != 32) return null;
  final y = _unpack25519(key);
  final back = _pack25519(y);
  for (var i = 0; i < 31; i++) {
    if (back[i] != key[i]) return null; // y >= p: not canonical
  }
  if (back[31] != (key[31] & 0x7f)) return null;
  final z = _gf([1]);
  final y2 = _sq(y);
  final u = _sub(y2, z); // x^2 = u / v
  final v = _add(z, _mul(y2, _d));
  final v2 = _sq(v);
  final v4 = _sq(v2);
  final v6 = _mul(v4, v2);
  var t = _mul(_mul(v6, u), v); // u v^7
  t = _pow2523(t); // (u v^7)^((p-5)/8)
  var x = _mul(_mul(_mul(_mul(t, u), v), v), v); // u v^3 (u v^7)^((p-5)/8)
  if (_neq(_mul(_sq(x), v), u)) x = _mul(x, _sqrtM1);
  if (_neq(_mul(_sq(x), v), u)) return null;
  final sign = key[31] >> 7;
  if (sign == 1 && _same(_pack25519(x), Uint8List(32))) return null;
  if (_par(x) != sign) x = _sub(_gf(), x);
  return [x, y, z, _mul(x, y)];
}

/// Whether 32 bytes encode a point of the curve, as a public key must.
bool isPublicKey(List<int> key) => _decode(key) != null;

/// The public key of a 32-byte seed.
Uint8List publicKey(List<int> seed) => _packPoint(_scalarbase(_expand(seed).sublist(0, 32)));

/// The 64-byte signature of [message] made with [seed] (whose public key is [public], if the caller has it).
/// Deterministic: the same seed and message always give the same signature.
Uint8List sign(List<int> seed, List<int> message, [List<int>? public]) {
  final d = _expand(seed);
  final pk = public ?? _packPoint(_scalarbase(d.sublist(0, 32)));
  final r = _reduce(sha512([...d.sublist(32), ...message]));
  final bigR = _packPoint(_scalarbase(r));
  final h = _reduce(sha512([...bigR, ...pk, ...message]));
  final x = Int64List(64);
  for (var i = 0; i < 32; i++) {
    x[i] = r[i];
  }
  for (var i = 0; i < 32; i++) {
    for (var j = 0; j < 32; j++) {
      x[i + j] += h[i] * d[j];
    }
  }
  return Uint8List.fromList([...bigR, ..._modL(x)]);
}

/// True only for a valid signature: a damaged key or signature is false, never an exception.
bool verify(List<int> key, List<int> message, List<int> signature) {
  if (key.length != 32 || signature.length != 64) return false;
  final a = _decode(key);
  if (a == null) return false;
  final s = signature.sublist(32);
  var below = false; // S < L, compared from the most significant byte (RFC 8032, 5.1.7)
  for (var i = 31; i >= 0; i--) {
    if (s[i] != _l[i]) {
      below = s[i] < _l[i];
      break;
    }
  }
  if (!below) return false;
  final negA = [_sub(_gf(), a[0]), a[1], a[2], _sub(_gf(), a[3])];
  final h = _reduce(sha512([...signature.sublist(0, 32), ...key, ...message]));
  final p = _scalarmult(negA, h);
  _addPoint(p, _scalarbase(s));
  return _same(_packPoint(p), signature.sublist(0, 32));
}

/// Bytes from lowercase or uppercase hex; a FormatException for anything else.
Uint8List hexBytes(String hex) {
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) throw const FormatException('not hex');
  return Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}
