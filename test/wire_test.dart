import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_proxy/protocol/wire.dart';

void main() {
  test('signed VarInts and position extremes round trip', () {
    for (final n in [0, 1, 127, 128, 255, 2147483647, -1, -2147483648]) {
      final w = Writer()..varInt(n);
      expect(Reader(w.take()).varInt(), n);
    }
    for (final pos in [
      [-33554432, -2048, 33554431],
      [0, 0, 0],
      [-1, -64, -20],
    ]) {
      final w = Writer()..position(pos[0], pos[1], pos[2]);
      expect(Reader(w.take()).position(), {
        'x': pos[0],
        'y': pos[1],
        'z': pos[2],
      });
    }
  });
  test('TCP fragmentation and coalescing preserve packets', () {
    final f = PacketFramer();
    final body = Uint8List.fromList(List.generate(1024, (i) => i & 255));
    final packet = framePacket(49, body);
    final results = <Uint8List>[];
    for (final b in packet) {
      results.addAll(f.add([b]));
    }
    expect(results.length, 1);
    final r = Reader(results.single);
    expect(r.varInt(), 49);
    expect(r.raw(1024), body);
    expect(f.add([...framePacket(1, []), ...framePacket(2, [])]).length, 2);
  });
  test('reject malformed frames and truncated fields', () {
    expect(
      () => PacketFramer().add([255, 255, 255, 255, 255]),
      throwsFormatException,
    );
    expect(() => PacketFramer().add([0]), throwsFormatException);
    expect(
      () => Reader([128, 128, 128, 128, 16]).varInt(),
      throwsFormatException,
    );
    expect(() => Reader([4, 65]).string(), throwsFormatException);
    expect(() => Reader([1]).i64(), throwsFormatException);
  });
}
