// SPDX-License-Identifier: GPL-3.0-or-later
// SHA-512 (FIPS 180-4), for Ed25519. Pure Dart because the core has no dependencies. Dart's int is 64-bit two's
// complement on the platforms FieldWorx runs on (the app and the command line, never the web), and its arithmetic wraps,
// which is exactly SHA-512's arithmetic modulo 2^64. Checked against hashlib by core/test/signatures_test.dart.

import 'dart:typed_data';

int _w(int hi, int lo) => (hi << 32) | lo;

final List<int> _k = [
  _w(0x428a2f98, 0xd728ae22), _w(0x71374491, 0x23ef65cd), _w(0xb5c0fbcf, 0xec4d3b2f), _w(0xe9b5dba5, 0x8189dbbc), //
  _w(0x3956c25b, 0xf348b538), _w(0x59f111f1, 0xb605d019), _w(0x923f82a4, 0xaf194f9b), _w(0xab1c5ed5, 0xda6d8118), //
  _w(0xd807aa98, 0xa3030242), _w(0x12835b01, 0x45706fbe), _w(0x243185be, 0x4ee4b28c), _w(0x550c7dc3, 0xd5ffb4e2), //
  _w(0x72be5d74, 0xf27b896f), _w(0x80deb1fe, 0x3b1696b1), _w(0x9bdc06a7, 0x25c71235), _w(0xc19bf174, 0xcf692694), //
  _w(0xe49b69c1, 0x9ef14ad2), _w(0xefbe4786, 0x384f25e3), _w(0x0fc19dc6, 0x8b8cd5b5), _w(0x240ca1cc, 0x77ac9c65), //
  _w(0x2de92c6f, 0x592b0275), _w(0x4a7484aa, 0x6ea6e483), _w(0x5cb0a9dc, 0xbd41fbd4), _w(0x76f988da, 0x831153b5), //
  _w(0x983e5152, 0xee66dfab), _w(0xa831c66d, 0x2db43210), _w(0xb00327c8, 0x98fb213f), _w(0xbf597fc7, 0xbeef0ee4), //
  _w(0xc6e00bf3, 0x3da88fc2), _w(0xd5a79147, 0x930aa725), _w(0x06ca6351, 0xe003826f), _w(0x14292967, 0x0a0e6e70), //
  _w(0x27b70a85, 0x46d22ffc), _w(0x2e1b2138, 0x5c26c926), _w(0x4d2c6dfc, 0x5ac42aed), _w(0x53380d13, 0x9d95b3df), //
  _w(0x650a7354, 0x8baf63de), _w(0x766a0abb, 0x3c77b2a8), _w(0x81c2c92e, 0x47edaee6), _w(0x92722c85, 0x1482353b), //
  _w(0xa2bfe8a1, 0x4cf10364), _w(0xa81a664b, 0xbc423001), _w(0xc24b8b70, 0xd0f89791), _w(0xc76c51a3, 0x0654be30), //
  _w(0xd192e819, 0xd6ef5218), _w(0xd6990624, 0x5565a910), _w(0xf40e3585, 0x5771202a), _w(0x106aa070, 0x32bbd1b8), //
  _w(0x19a4c116, 0xb8d2d0c8), _w(0x1e376c08, 0x5141ab53), _w(0x2748774c, 0xdf8eeb99), _w(0x34b0bcb5, 0xe19b48a8), //
  _w(0x391c0cb3, 0xc5c95a63), _w(0x4ed8aa4a, 0xe3418acb), _w(0x5b9cca4f, 0x7763e373), _w(0x682e6ff3, 0xd6b2b8a3), //
  _w(0x748f82ee, 0x5defb2fc), _w(0x78a5636f, 0x43172f60), _w(0x84c87814, 0xa1f0ab72), _w(0x8cc70208, 0x1a6439ec), //
  _w(0x90befffa, 0x23631e28), _w(0xa4506ceb, 0xde82bde9), _w(0xbef9a3f7, 0xb2c67915), _w(0xc67178f2, 0xe372532b), //
  _w(0xca273ece, 0xea26619c), _w(0xd186b8c7, 0x21c0c207), _w(0xeada7dd6, 0xcde0eb1e), _w(0xf57d4f7f, 0xee6ed178), //
  _w(0x06f067aa, 0x72176fba), _w(0x0a637dc5, 0xa2c898a6), _w(0x113f9804, 0xbef90dae), _w(0x1b710b35, 0x131c471b), //
  _w(0x28db77f5, 0x23047d84), _w(0x32caab7b, 0x40c72493), _w(0x3c9ebe0a, 0x15c9bebc), _w(0x431d67c4, 0x9c100d4c), //
  _w(0x4cc5d4be, 0xcb3e42b6), _w(0x597f299c, 0xfc657e2a), _w(0x5fcb6fab, 0x3ad6faec), _w(0x6c44198c, 0x4a475817),
];

final List<int> _iv = [
  _w(0x6a09e667, 0xf3bcc908), _w(0xbb67ae85, 0x84caa73b), _w(0x3c6ef372, 0xfe94f82b), _w(0xa54ff53a, 0x5f1d36f1), //
  _w(0x510e527f, 0xade682d1), _w(0x9b05688c, 0x2b3e6c1f), _w(0x1f83d9ab, 0xfb41bd6b), _w(0x5be0cd19, 0x137e2179),
];

int _rotr(int x, int n) => (x >>> n) | (x << (64 - n));

void _block(Int64List h, Int64List w, List<int> data, int at) {
  for (var i = 0; i < 16; i++) {
    var v = 0;
    for (var j = 0; j < 8; j++) {
      v = (v << 8) | data[at + 8 * i + j];
    }
    w[i] = v;
  }
  for (var i = 16; i < 80; i++) {
    final x = w[i - 15], y = w[i - 2];
    final s0 = _rotr(x, 1) ^ _rotr(x, 8) ^ (x >>> 7);
    final s1 = _rotr(y, 19) ^ _rotr(y, 61) ^ (y >>> 6);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
  for (var i = 0; i < 80; i++) {
    final s1 = _rotr(e, 14) ^ _rotr(e, 18) ^ _rotr(e, 41);
    final ch = (e & f) ^ (~e & g);
    final t1 = hh + s1 + ch + _k[i] + w[i];
    final s0 = _rotr(a, 28) ^ _rotr(a, 34) ^ _rotr(a, 39);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = s0 + maj;
    hh = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
  h[5] += f;
  h[6] += g;
  h[7] += hh;
}

/// The SHA-512 digest of [data]: 64 bytes.
Uint8List sha512(List<int> data) {
  final h = Int64List.fromList(_iv);
  final w = Int64List(80);
  final n = data.length;
  final padded = Uint8List(((n + 17 + 127) ~/ 128) * 128)
    ..setRange(0, n, data)
    ..[n] = 0x80;
  final bits = n * 8; // messages here are far below 2^61 bytes: the length's top 64 bits are zero
  for (var j = 0; j < 8; j++) {
    padded[padded.length - 1 - j] = (bits >>> (8 * j)) & 0xff;
  }
  for (var at = 0; at < padded.length; at += 128) {
    _block(h, w, padded, at);
  }
  final out = Uint8List(64);
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 8; j++) {
      out[8 * i + j] = (h[i] >>> (56 - 8 * j)) & 0xff;
    }
  }
  return out;
}
