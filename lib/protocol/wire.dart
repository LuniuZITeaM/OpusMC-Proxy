import 'dart:convert';
import 'dart:typed_data';

class Writer {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  void raw(List<int> v) => _bytes.add(v);
  void u8(int v) => _bytes.addByte(v & 255);
  void boolValue(bool v) => u8(v ? 1 : 0);
  void _number(int n, void Function(ByteData) set) {
    final b = ByteData(n);
    set(b);
    raw(b.buffer.asUint8List());
  }

  void i16(int v) => _number(2, (b) => b.setInt16(0, v));
  void i32(int v) => _number(4, (b) => b.setInt32(0, v));
  void i64(int v) => _number(8, (b) => b.setInt64(0, v));
  void f32(num v) => _number(4, (b) => b.setFloat32(0, v.toDouble()));
  void f64(num v) => _number(8, (b) => b.setFloat64(0, v.toDouble()));
  void varInt(int v) {
    v &= 0xffffffff;
    do {
      final n = v & 127;
      v = v >>> 7;
      u8(n | (v == 0 ? 0 : 128));
    } while (v != 0);
  }

  void string(String v) {
    final b = utf8.encode(v);
    varInt(b.length);
    raw(b);
  }

  void text(String v) {
    u8(8);
    final b = utf8.encode(v);
    if (b.length > 65535) throw const FormatException('Text too long');
    i16(b.length);
    raw(b);
  }

  void uuid(String v) {
    final h = v.replaceAll('-', '');
    if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(h)) {
      throw const FormatException('Invalid UUID');
    }
    raw([
      for (int i = 0; i < 32; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16),
    ]);
  }

  void position(int x, int y, int z) =>
      i64(((x & 0x3ffffff) << 38) | ((z & 0x3ffffff) << 12) | (y & 4095));
  Uint8List take() => _bytes.takeBytes();
}

class Reader {
  final Uint8List bytes;
  int offset = 0;
  Reader(List<int> bytes) : bytes = Uint8List.fromList(bytes);
  int get remaining => bytes.length - offset;
  void _need(int n) {
    if (n < 0 || remaining < n) throw const FormatException('Truncated packet');
  }

  int u8() {
    _need(1);
    return bytes[offset++];
  }

  bool boolValue() => u8() != 0;
  T _number<T>(int n, T Function(ByteData) read) {
    _need(n);
    final v = read(ByteData.sublistView(bytes, offset, offset + n));
    offset += n;
    return v;
  }

  int i16() => _number(2, (b) => b.getInt16(0));
  int i32() => _number(4, (b) => b.getInt32(0));
  int i64() => _number(8, (b) => b.getInt64(0));
  double f32() => _number(4, (b) => b.getFloat32(0));
  double f64() => _number(8, (b) => b.getFloat64(0));
  int varInt() {
    int v = 0;
    for (int i = 0; i < 5; i++) {
      final b = u8();
      if (i == 4 && b > 15) throw const FormatException('VarInt overflow');
      v |= (b & 127) << (i * 7);
      if (b < 128) return v.toSigned(32);
    }
    throw const FormatException('VarInt too long');
  }

  Uint8List raw(int n) {
    _need(n);
    final v = Uint8List.sublistView(bytes, offset, offset + n);
    offset += n;
    return v;
  }

  String string([int max = 32767]) {
    final n = varInt();
    if (n < 0 || n > max * 3) {
      throw const FormatException('Invalid string length');
    }
    final s = utf8.decode(raw(n));
    if (s.length > max) throw const FormatException('String too long');
    return s;
  }

  Map<String, int> position() {
    final n = i64();
    return {
      'x': (n >> 38).toSigned(26),
      'y': (n & 4095).toSigned(12),
      'z': ((n >> 12) & 0x3ffffff).toSigned(26),
    };
  }
}

/// Incremental TCP framing, bounded before allocation. Compression is disabled.
class PacketFramer {
  static const maxLength = 8 * 1024 * 1024;
  final List<int> _buffer = [];
  List<Uint8List> add(List<int> bytes) {
    if (_buffer.length + bytes.length > maxLength + 65536) {
      throw const FormatException('Receive buffer limit');
    }
    _buffer.addAll(bytes);
    final packets = <Uint8List>[];
    int start = 0;
    while (start < _buffer.length) {
      int length = 0, header = 0;
      bool complete = false;
      for (int i = 0; i < 5 && start + i < _buffer.length; i++) {
        final b = _buffer[start + i];
        length |= (b & 127) << (7 * i);
        header++;
        if (b < 128) {
          complete = true;
          break;
        }
        if (i == 4) throw const FormatException('Invalid frame length');
      }
      if (!complete) break;
      if (length <= 0 || length > maxLength) {
        throw const FormatException('Frame length out of range');
      }
      if (_buffer.length - start - header < length) break;
      packets.add(
        Uint8List.fromList(
          _buffer.sublist(start + header, start + header + length),
        ),
      );
      start += header + length;
    }
    if (start > 0) _buffer.removeRange(0, start);
    return packets;
  }
}

Uint8List framePacket(int id, List<int> payload) {
  final body = Writer()
    ..varInt(id)
    ..raw(payload);
  final b = body.take();
  return (Writer()
        ..varInt(b.length)
        ..raw(b))
      .take();
}
