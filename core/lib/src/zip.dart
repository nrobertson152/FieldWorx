// SPDX-License-Identifier: GPL-3.0-or-later
// Just enough ZIP for FieldWorx archives: read (stored and deflate, ZIP64 directories) from a random-access file
// without loading members into memory, and write (stored and deflate, patching sizes into local headers).
// Member names are only ever used as lookup keys, never as paths on disk.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ZipError implements Exception {
  ZipError(this.message);
  final String message;
  @override
  String toString() => 'ZipError: $message';
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

class Crc32 {
  int _c = 0xffffffff;
  void add(List<int> data) {
    var c = _c;
    for (final b in data) {
      c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
    }
    _c = c;
  }

  int get value => (_c ^ 0xffffffff) & 0xffffffff;
}

class ZipEntry {
  ZipEntry(this.name, this.method, this.flags, this.crc, this.compressedSize, this.size, this.localOffset);
  final String name;
  final int method;
  final int flags;
  final int crc;
  final int compressedSize;
  final int size;
  final int localOffset;
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
int _u64(Uint8List b, int o) => _u32(b, o) + _u32(b, o + 4) * 0x100000000;

class ZipReader {
  ZipReader._(this._file, this.entries);

  final RandomAccessFile _file;
  final List<ZipEntry> entries;
  late final Map<String, ZipEntry> byName = {for (final e in entries) e.name: e};

  static Future<ZipReader> open(File file, {int maxEntries = 200100}) async {
    final raf = await file.open();
    try {
      return ZipReader._(raf, await _readDirectory(raf, maxEntries));
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  Future<void> close() => _file.close();

  static Future<Uint8List> _readAt(RandomAccessFile f, int pos, int n) async {
    await f.setPosition(pos);
    final b = await f.read(n);
    if (b.length != n) throw ZipError('file is truncated');
    return b;
  }

  static Future<List<ZipEntry>> _readDirectory(RandomAccessFile f, int maxEntries) async {
    final len = await f.length();
    if (len < 22) throw ZipError('not a ZIP file');
    final tailLen = len < 65557 ? len : 65557;
    final tail = await _readAt(f, len - tailLen, tailLen);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_u32(tail, i) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw ZipError('not a ZIP file');
    if (_u16(tail, eocd + 4) != 0 || _u16(tail, eocd + 6) != 0) throw ZipError('multi-disk ZIP files are not supported');
    var count = _u16(tail, eocd + 10);
    var cdSize = _u32(tail, eocd + 12);
    var cdOffset = _u32(tail, eocd + 16);
    if (count == 0xffff || cdSize == 0xffffffff || cdOffset == 0xffffffff) {
      final locPos = len - tailLen + eocd - 20;
      if (locPos < 0) throw ZipError('ZIP64 locator missing');
      final loc = await _readAt(f, locPos, 20);
      if (_u32(loc, 0) != 0x07064b50) throw ZipError('ZIP64 locator missing');
      final z64 = await _readAt(f, _u64(loc, 8), 56);
      if (_u32(z64, 0) != 0x06064b50) throw ZipError('ZIP64 directory missing');
      count = _u64(z64, 32);
      cdSize = _u64(z64, 40);
      cdOffset = _u64(z64, 48);
    }
    if (count > maxEntries) throw ZipError('too many members');
    if (cdOffset + cdSize > len) throw ZipError('directory outside the file');
    final cd = await _readAt(f, cdOffset, cdSize);
    final out = <ZipEntry>[];
    var p = 0;
    for (var n = 0; n < count; n++) {
      if (p + 46 > cd.length || _u32(cd, p) != 0x02014b50) throw ZipError('directory damaged');
      final flags = _u16(cd, p + 8);
      final method = _u16(cd, p + 10);
      final crc = _u32(cd, p + 16);
      var csize = _u32(cd, p + 20);
      var usize = _u32(cd, p + 24);
      final nlen = _u16(cd, p + 28), xlen = _u16(cd, p + 30), clen = _u16(cd, p + 32);
      var local = _u32(cd, p + 42);
      if (p + 46 + nlen + xlen + clen > cd.length) throw ZipError('directory damaged');
      final nameBytes = cd.sublist(p + 46, p + 46 + nlen);
      String name;
      try {
        name = const Utf8Decoder().convert(nameBytes);
      } on FormatException {
        throw ZipError('member name is not UTF-8');
      }
      var x = p + 46 + nlen;
      final xEnd = x + xlen;
      while (x + 4 <= xEnd) {
        final id = _u16(cd, x), sz = _u16(cd, x + 2);
        if (id == 0x0001) {
          var q = x + 4;
          if (usize == 0xffffffff) {
            usize = _u64(cd, q);
            q += 8;
          }
          if (csize == 0xffffffff) {
            csize = _u64(cd, q);
            q += 8;
          }
          if (local == 0xffffffff) {
            local = _u64(cd, q);
          }
        }
        x += 4 + sz;
      }
      if ((flags & 1) != 0) throw ZipError('encrypted members are not supported');
      if (method != 0 && method != 8) throw ZipError('member $name uses an unsupported compression');
      out.add(ZipEntry(name, method, flags, crc, csize, usize, local));
      p += 46 + nlen + xlen + clen;
    }
    return out;
  }

  Future<int> _dataStart(ZipEntry e) async {
    final h = await _readAt(_file, e.localOffset, 30);
    if (_u32(h, 0) != 0x04034b50) throw ZipError('member ${e.name} is damaged');
    return e.localOffset + 30 + _u16(h, 26) + _u16(h, 28);
  }

  /// Streams the uncompressed bytes of [e] to [onChunk], checking the size against [e.size] (never inflating more
  /// than about 64 KiB of input ahead) and the CRC.
  Future<void> extract(ZipEntry e, FutureOr<void> Function(Uint8List chunk) onChunk) async {
    final start = await _dataStart(e);
    final crc = Crc32();
    var produced = 0;
    final out = <Uint8List>[];
    void take(List<int> chunk) {
      produced += chunk.length;
      if (produced > e.size) throw ZipError('member ${e.name} is larger than it says');
      final u = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      crc.add(u);
      out.add(u);
    }

    Future<void> flush() async {
      for (final c in out) {
        await onChunk(c);
      }
      out.clear();
    }

    if (e.method == 0 && e.compressedSize != e.size) throw ZipError('member ${e.name} is damaged');
    final inflater = e.method == 8 ? ZLibDecoder(raw: true).startChunkedConversion(_ChunkSink(take)) : null;
    await _file.setPosition(start);
    var remaining = e.compressedSize;
    // Compressed data that doesn't decompress is a damaged member, refused like any other (not zlib's own error).
    void inflate(List<int> b, {bool last = false}) {
      try {
        if (last) {
          inflater!.close();
        } else {
          inflater!.add(b);
        }
      } on FormatException {
        throw ZipError('member ${e.name} is damaged: its compressed data doesn’t decompress');
      }
    }

    while (remaining > 0) {
      final n = remaining < 65536 ? remaining : 65536;
      final b = await _file.read(n);
      if (b.isEmpty) throw ZipError('file is truncated');
      remaining -= b.length;
      if (inflater == null) {
        take(b);
      } else {
        inflate(b);
      }
      await flush();
    }
    if (inflater != null) inflate(const [], last: true);
    await flush();
    if (produced != e.size) throw ZipError('member ${e.name} has the wrong size');
    if (crc.value != e.crc) throw ZipError('member ${e.name} is damaged (CRC)');
  }

  Future<Uint8List> readBytes(ZipEntry e, {int limit = 256 * 1024 * 1024}) async {
    if (e.size > limit) throw ZipError('member ${e.name} is too large');
    final out = BytesBuilder(copy: false);
    await extract(e, out.add);
    return out.takeBytes();
  }
}

class _ChunkSink implements Sink<List<int>> {
  _ChunkSink(this.onData);
  final void Function(List<int>) onData;
  @override
  void add(List<int> data) => onData(data);
  @override
  void close() {}
}

/// Writes a ZIP file member by member. Sizes and CRCs are patched into each local header afterwards, so members
/// can be streamed from files. Not ZIP64: refuses to go past 4 GB.
class ZipWriter {
  ZipWriter._(this._raf);
  final RandomAccessFile _raf;
  final List<(ZipEntry, Uint8List)> _central = [];
  int _pos = 0;
  static const int _limit = 0xfffffff0;

  static Future<ZipWriter> create(File file) async => ZipWriter._(await file.open(mode: FileMode.writeOnly));

  Future<void> _write(List<int> b) async {
    await _raf.writeFrom(b);
    _pos += b.length;
    if (_pos > _limit) throw ZipError('archive would be larger than 4 GB');
  }

  Uint8List _header(Uint8List name, int method, int crc, int csize, int size) {
    final h = ByteData(30);
    h.setUint32(0, 0x04034b50, Endian.little);
    h.setUint16(4, 20, Endian.little);
    h.setUint16(6, 0x0800, Endian.little); // UTF-8 names
    h.setUint16(8, method, Endian.little);
    h.setUint16(10, 0, Endian.little); // time 00:00
    h.setUint16(12, ((2026 - 1980) << 9) | (1 << 5) | 1, Endian.little); // 2026-01-01, like the bridge
    h.setUint32(14, crc, Endian.little);
    h.setUint32(18, csize, Endian.little);
    h.setUint32(22, size, Endian.little);
    h.setUint16(26, name.length, Endian.little);
    h.setUint16(28, 0, Endian.little);
    return h.buffer.asUint8List();
  }

  /// Adds a member from a stream of chunks. [deflate] compresses it.
  Future<void> addStream(String name, Stream<List<int>> data, {required bool deflate}) async {
    final nameBytes = Uint8List.fromList(const Utf8Encoder().convert(name));
    final local = _pos;
    final method = deflate ? 8 : 0;
    await _write(_header(nameBytes, method, 0, 0, 0));
    await _write(nameBytes);
    final crc = Crc32();
    var size = 0, csize = 0;
    if (deflate) {
      final pending = <List<int>>[];
      final sink = _ChunkSink(pending.add);
      final enc = ZLibEncoder(raw: true, level: 6).startChunkedConversion(sink);
      await for (final chunk in data) {
        crc.add(chunk);
        size += chunk.length;
        enc.add(chunk);
        for (final p in pending) {
          await _write(p);
          csize += p.length;
        }
        pending.clear();
      }
      enc.close();
      for (final p in pending) {
        await _write(p);
        csize += p.length;
      }
    } else {
      await for (final chunk in data) {
        crc.add(chunk);
        size += chunk.length;
        await _write(chunk);
      }
      csize = size;
    }
    final end = _pos;
    await _raf.setPosition(local);
    await _raf.writeFrom(_header(nameBytes, method, crc.value, csize, size));
    await _raf.setPosition(end);
    _central.add((ZipEntry(name, method, 0x0800, crc.value, csize, size, local), nameBytes));
  }

  Future<void> addBytes(String name, List<int> data, {required bool deflate}) =>
      addStream(name, Stream.value(data), deflate: deflate);

  Future<void> close() async {
    final cdStart = _pos;
    for (final (e, name) in _central) {
      final h = ByteData(46);
      h.setUint32(0, 0x02014b50, Endian.little);
      h.setUint16(4, 0x0314, Endian.little); // made by: Unix, 2.0
      h.setUint16(6, 20, Endian.little);
      h.setUint16(8, e.flags, Endian.little);
      h.setUint16(10, e.method, Endian.little);
      h.setUint16(12, 0, Endian.little);
      h.setUint16(14, ((2026 - 1980) << 9) | (1 << 5) | 1, Endian.little);
      h.setUint32(16, e.crc, Endian.little);
      h.setUint32(20, e.compressedSize, Endian.little);
      h.setUint32(24, e.size, Endian.little);
      h.setUint16(28, name.length, Endian.little);
      h.setUint32(38, 0x81a40000, Endian.little); // -rw-r--r--
      h.setUint32(42, e.localOffset, Endian.little);
      await _write(h.buffer.asUint8List());
      await _write(name);
    }
    final cdSize = _pos - cdStart;
    final many = _central.length > 0xfffe;
    if (many) {
      // ZIP64 end records, only for the member count (offsets stay below 4 GB).
      final z64At = _pos;
      final z = ByteData(56);
      z.setUint32(0, 0x06064b50, Endian.little);
      z.setUint64(4, 44, Endian.little);
      z.setUint16(12, 45, Endian.little);
      z.setUint16(14, 45, Endian.little);
      z.setUint64(24, _central.length, Endian.little);
      z.setUint64(32, _central.length, Endian.little);
      z.setUint64(40, cdSize, Endian.little);
      z.setUint64(48, cdStart, Endian.little);
      await _write(z.buffer.asUint8List());
      final loc = ByteData(20);
      loc.setUint32(0, 0x07064b50, Endian.little);
      loc.setUint64(8, z64At, Endian.little);
      loc.setUint32(16, 1, Endian.little);
      await _write(loc.buffer.asUint8List());
    }
    final end = ByteData(22);
    end.setUint32(0, 0x06054b50, Endian.little);
    end.setUint16(8, many ? 0xffff : _central.length, Endian.little);
    end.setUint16(10, many ? 0xffff : _central.length, Endian.little);
    end.setUint32(12, cdSize, Endian.little);
    end.setUint32(16, cdStart, Endian.little);
    await _write(end.buffer.asUint8List());
    await _raf.flush();
    await _raf.close();
  }

  Future<void> abandon() async {
    try {
      await _raf.close();
    } catch (_) {}
  }
}
