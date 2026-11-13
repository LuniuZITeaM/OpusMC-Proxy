import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_agent/protocol/chunks.dart';

void main() {
  test('chunk remaps palette before air/fluid counts and heightmaps', () {
    final chunk = BridgeChunk.decode(
      _fixture(
        sections: [
          _Section([7, 0, 4], indices: List.generate(4096, (i) => i % 3)),
        ],
      ),
    );
    final mapped = {7: 0, 0: 86, 4: 1}; // Upstream air is not ID zero.
    final packet = _Packet(
      chunk.chunkPacket(
        sectionCount: 1,
        biomeIds: [0],
        mapBlockState: (id) => mapped[id]!,
      ),
    );
    packet.bytes(8);
    final heights = _heights(packet, 1);
    expect(heights[0], 15); // Its topmost upstream state 7 maps to air.
    final data = _Packet(packet.bytes(packet.varInt()));
    expect(data.i16(), 2730);
    expect(data.i16(), 1365);
    expect(
      _palette(data, 4096),
      List.generate(4096, (i) => mapped[[7, 0, 4][i % 3]]),
    );
    // Source palette remains unchanged, so repeated encodes cannot double-map.
    expect(chunk.sections.single.palette, [7, 0, 4]);
  });
  test(
    'decodes little endian signed coordinates, palettes and partial light',
    () {
      final chunk = BridgeChunk.decode(
        _fixture(
          type: 2,
          cx: -2147483648,
          cz: 2147483647,
          sections: [
            _Section(
              [1, 65535],
              indices: List.generate(4096, (i) => i & 1),
              block: List.filled(2048, 0xa5),
            ),
          ],
        ),
      );
      expect(chunk.type, 2);
      expect(chunk.cx, -2147483648);
      expect(chunk.cz, 2147483647);
      expect(chunk.sections.single.stateAt(4095), 65535);
      expect(chunk.sections.single.skyLight, isNull);
      expect(chunk.sections.single.blockLight!.first, 0xa5);
      expect(chunk.biomes, isNull);
      expect(() => chunk.sections.clear(), throwsUnsupportedError);
      expect(
        () => chunk.sections.single.palette[0] = 9,
        throwsUnsupportedError,
      );
    },
  );

  test('26.2 single value sections have two counts and no long count', () {
    final payload = BridgeChunk.decode(
      _fixture(
        cx: -3,
        cz: 5,
        sections: [
          _Section([1]),
        ],
      ),
    ).chunkPacket(sectionCount: 2, biomeIds: [7]);
    final packet = _Packet(payload);
    expect(packet.i32(), -3);
    expect(packet.i32(), 5);
    final heights = _heights(packet, 2);
    expect(heights, everyElement(16));
    final data = _Packet(packet.bytes(packet.varInt()));
    // Every section: nonAir, fluid, block bits+state, biome bits+state.
    expect(data.bytes(8), [0x10, 0, 0, 0, 0, 1, 0, 7]);
    expect(data.bytes(8), [0, 0, 0, 0, 0, 0, 0, 7]);
    expect(data.remaining, 0);
    expect(packet.varInt(), 0); // Block entities.
    final light = _lights(packet);
    expect(light.masks, everyElement(isEmpty));
    expect(packet.remaining, 0);
  });

  test('non-air counts exclude all air variants and count fluid states', () {
    final states = [0, 15292, 15293, 1, 86, 101, 102, 117];
    final chunk = BridgeChunk.decode(
      _fixture(
        sections: [
          _Section(
            states,
            indices: List.generate(4096, (i) => i % states.length),
          ),
        ],
      ),
    );
    final packet = _Packet(chunk.chunkPacket(sectionCount: 1, biomeIds: [0]));
    packet.bytes(8);
    final heights = _heights(packet, 1);
    expect(heights[0], 0);
    expect(heights[3], 16);
    final data = _Packet(packet.bytes(packet.varInt()));
    expect(data.i16(), 2560);
    expect(data.i16(), 2048);
    expect(_palette(data, 4096), List.generate(4096, (i) => states[i % 8]));
    expect(_palette(data, 64), everyElement(0));
    expect(data.remaining, 0);
  });

  test('waterlogged states count fluids without counting dry neighbors', () {
    // Vanilla 26.2 oak_slab[type=bottom,waterlogged=true/false].
    final packet = _Packet(
      BridgeChunk.decode(
        _fixture(
          sections: [
            _Section([
              13332,
              13333,
            ], indices: List.generate(4096, (i) => i & 1)),
          ],
        ),
      ).chunkPacket(sectionCount: 1, biomeIds: [0]),
    );
    packet.bytes(8);
    _heights(packet, 1);
    final data = _Packet(packet.bytes(packet.varInt()));
    expect(data.i16(), 4096);
    expect(data.i16(), 2048);
  });

  for (final size in [2, 17, 33, 65, 129, 256, 257, 4096]) {
    test('round trips palette size $size with padded, fixed-size longs', () {
      final palette = List.generate(size, (i) => i + 1);
      final indices = List.generate(4096, (i) => (i * 19) % size);
      final bridge = BridgeChunk.decode(
        _fixture(sections: [_Section(palette, indices: indices)]),
      );
      expect(bridge.sections.single.indices, indices);
      final packet = _Packet(
        bridge.chunkPacket(sectionCount: 1, biomeIds: [0]),
      );
      packet.bytes(8);
      _heights(packet, 1);
      final data = _Packet(packet.bytes(packet.varInt()));
      expect(data.i16(), 4096);
      data.i16();
      expect(
        data.data.getUint8(data.offset),
        size > 256 ? 15 : (size <= 16 ? 4 : (size - 1).bitLength),
      );
      expect(_palette(data, 4096), [for (final i in indices) palette[i]]);
      expect(_palette(data, 64), everyElement(0));
      expect(data.remaining, 0);
      expect(packet.varInt(), 0);
      _lights(packet);
      expect(packet.remaining, 0);
    });
  }

  test('quart biomes map horizontal bridge indices and repeat vertically', () {
    final source = List.generate(256, (i) => (i ~/ 64) * 4 + (i % 16 ~/ 4));
    final ids = List.generate(16, (i) => i + 40);
    final packet = _Packet(
      BridgeChunk.decode(
        _fixture(
          sections: [
            _Section([0]),
          ],
          biomes: source,
        ),
      ).chunkPacket(sectionCount: 2, biomeIds: ids),
    );
    packet.bytes(8);
    _heights(packet, 2);
    final data = _Packet(packet.bytes(packet.varInt()));
    final expected = List.generate(
      64,
      (i) => ids[source[((i >> 2) & 3) * 64 + (i & 3) * 4]],
    );
    for (var s = 0; s < 2; s++) {
      data.bytes(4);
      _palette(data, 4096);
      // Java's 66-biome registry requires 7 bits even for a mapping below 64.
      expect(data.data.getUint8(data.offset), 7);
      expect(_palette(data, 64), expected);
    }
    expect(data.remaining, 0);
  });

  test('light masks distinguish absent, nonzero, and explicit zero arrays', () {
    final sky = List<int>.generate(2048, (i) => i & 255);
    final block = List<int>.filled(2048, 0x34);
    final packet = _Packet(
      BridgeChunk.decode(
        _fixture(
          type: 2,
          cx: -1,
          cz: -2,
          sections: [
            _Section([0], sky: sky),
            _Section([0], block: block),
            _Section([0], sky: List.filled(2048, 0)),
          ],
        ),
      ).lightPacket(sectionCount: 24),
    );
    expect(packet.varInt(), -1);
    expect(packet.varInt(), -2);
    final light = _lights(packet);
    expect(light.masks, [
      [2],
      [4],
      [8],
      [],
    ]);
    expect(light.sky, [sky]);
    expect(light.block, [block]);
    expect(packet.remaining, 0);
  });

  test('light masks cross the signed long boundary and multiple words', () {
    final sections = List.generate(65, (_) => _Section([0]));
    sections[62] = _Section([0], sky: List.filled(2048, 15));
    sections[64] = _Section([0], block: List.filled(2048, 0));
    final packet = _Packet(
      BridgeChunk.decode(_fixture(type: 2, sections: sections))
          .lightPacket(sectionCount: 65),
    );
    packet.varInt();
    packet.varInt();
    final light = _lights(packet);
    expect(light.masks[0], [1 << 63]);
    expect(light.masks[3], [0, 2]);
    expect(light.sky.single, everyElement(15));
    expect(packet.remaining, 0);
  });

  test(
    'world surface uses dimension-relative heights and padded long packing',
    () {
      final indices = List.filled(4096, 0);
      indices[4095] = 1;
      final packet = _Packet(
        BridgeChunk.decode(
          _fixture(
            sections: [
              _Section([0]),
              _Section([0, 1], indices: indices),
            ],
          ),
        ).chunkPacket(sectionCount: 24, biomeIds: [0]),
      );
      packet.bytes(8);
      final heights = _heights(packet, 24);
      expect(heights[255], 32);
      expect(heights.take(255), everyElement(0));
    },
  );

  test('decode copies the input before exposing immutable data', () {
    final bytes = _fixture(
      sections: [
        _Section([1], sky: List.filled(2048, 12)),
      ],
    );
    final chunk = BridgeChunk.decode(bytes);
    bytes.fillRange(0, bytes.length, 0);
    expect(chunk.sections.single.palette, [1]);
    expect(chunk.sections.single.skyLight, everyElement(12));
  });

  test(
    'rejects malformed types, palette lengths, flags, indices and tails',
    () {
      final valid = _fixture(
        type: 2,
        sections: [
          _Section([0]),
        ],
      );
      for (final mutate in <void Function(Uint8List)>[
        (b) => b[0] = 3,
        (b) {
          b[10] = 0;
          b[11] = 0;
        },
        (b) {
          b[10] = 1;
          b[11] = 16;
        },
        (b) => b[14] = 4,
      ]) {
        final bad = Uint8List.fromList(valid);
        mutate(bad);
        expect(() => BridgeChunk.decode(bad), throwsFormatException);
      }
      final badIndex = _fixture(
        type: 2,
        sections: [
          _Section([0, 1], indices: List.filled(4096, 2)),
        ],
      );
      expect(() => BridgeChunk.decode(badIndex), throwsFormatException);
      expect(() => BridgeChunk.decode([...valid, 0]), throwsFormatException);
      expect(() => BridgeChunk.decode([256]), throwsFormatException);
      expect(
        () => BridgeChunk.decode(List.filled(BridgeChunk.maxInputBytes + 1, 0)),
        throwsFormatException,
      );
    },
  );

  test(
    'every truncated prefix fails, including light and biome boundaries',
    () {
      final bytes = _fixture(
        sections: [
          _Section(
            [0],
            sky: List.filled(2048, 0xff),
            block: List.filled(2048, 7),
          ),
        ],
      );
      for (var n = 0; n < bytes.length; n++) {
        expect(
          () => BridgeChunk.decode(Uint8List.sublistView(bytes, 0, n)),
          throwsFormatException,
          reason: 'prefix $n',
        );
      }
    },
  );

  test('encoder rejects invalid dimension and biome mapping arguments', () {
    final chunk = BridgeChunk.decode(
      _fixture(
        sections: [
          _Section([0]),
          _Section([1]),
        ],
      ),
    );
    for (final n in [0, -1, 1, 256]) {
      expect(
        () => chunk.chunkPacket(sectionCount: n, biomeIds: [0]),
        throwsArgumentError,
      );
      expect(() => chunk.lightPacket(sectionCount: n), throwsArgumentError);
    }
    for (final ids in <List<int>>[
      [],
      [-1],
      [32768],
      List.filled(257, 0),
    ]) {
      expect(
        () => chunk.chunkPacket(sectionCount: 2, biomeIds: ids),
        throwsArgumentError,
      );
    }
    final unknownBiome = BridgeChunk.decode(
      _fixture(
        sections: [
          _Section([0]),
        ],
        biomes: List.filled(256, 1),
      ),
    );
    expect(
      () => unknownBiome.chunkPacket(sectionCount: 1, biomeIds: [0]),
      throwsFormatException,
    );
    final update = BridgeChunk.decode(_fixture(type: 2, sections: []));
    expect(
      () => update.chunkPacket(sectionCount: 1, biomeIds: [0]),
      throwsStateError,
    );
  });
}

class _Section {
  final List<int> palette;
  final List<int>? indices, sky, block;
  _Section(this.palette, {this.indices, this.sky, this.block});
}

Uint8List _fixture({
  int type = 1,
  int cx = 0,
  int cz = 0,
  required List<_Section> sections,
  List<int>? biomes,
}) {
  final out = BytesBuilder();
  void u16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  out.addByte(type);
  for (final coord in [cx, cz]) {
    final b = ByteData(4)..setInt32(0, coord, Endian.little);
    out.add(b.buffer.asUint8List());
  }
  out.addByte(sections.length);
  for (final section in sections) {
    u16(section.palette.length);
    for (final value in section.palette) {
      u16(value);
    }
    if (section.palette.length > 1) {
      final indices = section.indices ?? List.filled(4096, 0);
      if (section.palette.length <= 256) {
        out.add(indices);
      } else {
        for (final value in indices) {
          u16(value);
        }
      }
    }
    out.addByte(
      (section.sky == null ? 0 : 1) | (section.block == null ? 0 : 2),
    );
    if (section.sky != null) out.add(section.sky!);
    if (section.block != null) out.add(section.block!);
  }
  if (type == 1) out.add(biomes ?? List.filled(256, 0));
  return out.takeBytes();
}

// Independent packet reader: fixed-size palette storage, length-prefixed
// heightmaps and light BitSets are intentionally decoded by different paths.
class _Packet {
  final ByteData data;
  int offset = 0;
  _Packet(List<int> bytes)
    : data = ByteData.sublistView(Uint8List.fromList(bytes));
  int get remaining => data.lengthInBytes - offset;
  int u8() => data.getUint8(offset++);
  int i16() {
    final v = data.getInt16(offset);
    offset += 2;
    return v;
  }

  int i32() {
    final v = data.getInt32(offset);
    offset += 4;
    return v;
  }

  int i64() {
    final v = data.getInt64(offset);
    offset += 8;
    return v;
  }

  int varInt() {
    var v = 0;
    for (var shift = 0; shift < 35; shift += 7) {
      final b = u8();
      v |= (b & 127) << shift;
      if (b < 128) return v.toSigned(32);
    }
    throw const FormatException('Bad test VarInt');
  }

  List<int> bytes(int n) => List.generate(n, (_) => u8());
}

List<int> _unpack(_Packet r, int count, int bits) {
  final perWord = 64 ~/ bits;
  final words = List.generate((count + perWord - 1) ~/ perWord, (_) => r.i64());
  return List.generate(
    count,
    (i) => (words[i ~/ perWord] >>> ((i % perWord) * bits)) & ((1 << bits) - 1),
  );
}

List<int> _palette(_Packet r, int count) {
  final bits = r.u8();
  if (bits == 0) return List.filled(count, r.varInt());
  final direct = bits > (count == 4096 ? 8 : 3);
  final palette = direct ? null : List.generate(r.varInt(), (_) => r.varInt());
  final values = _unpack(r, count, bits);
  return palette == null ? values : [for (final i in values) palette[i]];
}

List<int> _heights(_Packet r, int sectionCount) {
  expect(r.varInt(), 1); // Map size, not an NBT root.
  expect(r.varInt(), 1); // WORLD_SURFACE enum ID.
  final bits = (sectionCount * 16).bitLength;
  expect(r.varInt(), (256 + 64 ~/ bits - 1) ~/ (64 ~/ bits));
  return _unpack(r, 256, bits);
}

({List<List<int>> masks, List<List<int>> sky, List<List<int>> block}) _lights(
  _Packet r,
) {
  final masks = List.generate(
    4,
    (_) => List.generate(r.varInt(), (_) => r.i64()),
  );
  List<List<int>> arrays() => List.generate(r.varInt(), (_) {
    expect(r.varInt(), 2048);
    return r.bytes(2048);
  });
  return (masks: masks, sky: arrays(), block: arrays());
}
