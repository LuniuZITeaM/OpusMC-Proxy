import 'dart:convert';
import 'dart:typed_data';

/// One bottom-to-top bridge section. Null light means unchanged, including in
/// type-2 messages; an explicitly supplied zero array means clear that layer.
class BridgeSection {
  final List<int> palette;
  final List<int>? indices;
  final List<int>? skyLight;
  final List<int>? blockLight;

  BridgeSection._(this.palette, this.indices, this.skyLight, this.blockLight);

  int stateAt(int index) => palette[indices?[index] ?? 0];
}

/// OpusMC's little-endian binary bridge, as consumed by net.js onBinary.
/// Packet methods return Java 26.2 payloads without framing or packet IDs.
class BridgeChunk {
  static const maxSections = 255;
  static const maxInputBytes = 8 * 1024 * 1024;
  final int type;
  final int cx;
  final int cz;
  final List<BridgeSection> sections;
  final List<int>? biomes;

  /// Opaque bytes after the known layout; the official client ignores them.
  final int trailingByteCount;

  BridgeChunk._(
    this.type,
    this.cx,
    this.cz,
    this.sections,
    this.biomes,
    this.trailingByteCount,
  );

  static BridgeChunk decode(List<int> bytes) {
    if (bytes.length > maxInputBytes) {
      throw const FormatException('Bridge chunk exceeds input limit');
    }
    if (bytes.any((b) => b < 0 || b > 255)) {
      throw const FormatException('Bridge input contains a non-byte');
    }
    final r = _BridgeReader(Uint8List.fromList(bytes));
    final type = r.u8();
    if (type != 1 && type != 2) {
      throw const FormatException('Unknown bridge chunk type');
    }
    final cx = r.i32(), cz = r.i32(), count = r.u8();
    final sections = <BridgeSection>[];
    for (var s = 0; s < count; s++) {
      final length = r.u16();
      if (length < 1 || length > 4096) {
        throw const FormatException('Invalid bridge palette length');
      }
      final palette = List<int>.generate(length, (_) => r.u16());
      List<int>? indices;
      if (length > 1) {
        indices = List<int>.generate(
          4096,
          (_) => length <= 256 ? r.u8() : r.u16(),
        );
        if (indices.any((i) => i >= length)) {
          throw const FormatException('Bridge palette index out of bounds');
        }
      }
      final flags = r.u8();
      if (flags & ~3 != 0) {
        throw const FormatException('Unknown bridge light flags');
      }
      final sky = flags & 1 != 0 ? r.raw(2048) : null;
      final block = flags & 2 != 0 ? r.raw(2048) : null;
      sections.add(
        BridgeSection._(
          List.unmodifiable(palette),
          indices == null ? null : List.unmodifiable(indices),
          sky == null ? null : List.unmodifiable(sky),
          block == null ? null : List.unmodifiable(block),
        ),
      );
    }
    final biomes = type == 1 ? List<int>.unmodifiable(r.raw(256)) : null;
    // net.js onBinary stops here for type 1, and after the sections for type 2.
    // It does not require EOF. Keep the validated prefix and ignore the opaque
    // tail rather than guessing a format or forwarding it into Java packets.
    return BridgeChunk._(
      type,
      cx,
      cz,
      List.unmodifiable(sections),
      biomes,
      r.remaining,
    );
  }

  void _checkSectionCount(int count) {
    if (count < 1 || count > maxSections || sections.length > count) {
      throw ArgumentError.value(
        count,
        'sectionCount',
        'Must fit all bridge sections, in 1..255',
      );
    }
  }

  /// biomeIds maps the bridge's byte biome indices to the Java biome registry.
  /// The bridge supplies a 16x16 horizontal biome grid, sampled at quart origins
  /// and repeated vertically. Missing block sections are padded with air.
  Uint8List chunkPacket({
    required int sectionCount,
    required List<int> biomeIds,
    int Function(int)? mapBlockState,
  }) {
    if (type != 1) throw StateError('A light update has no chunk data');
    _checkSectionCount(sectionCount);
    if (biomeIds.isEmpty ||
        biomeIds.length > 256 ||
        biomeIds.any((id) => id < 0 || id >= 66)) {
      throw ArgumentError.value(
        biomeIds,
        'biomeIds',
        'Expected 1..256 vanilla 26.2 biome registry IDs (0..65)',
      );
    }
    final biomeValues = List<int>.generate(64, (i) {
      final source = biomes![((i >> 2) & 3) * 64 + (i & 3) * 4];
      if (source >= biomeIds.length) {
        throw const FormatException('Unknown bridge biome index');
      }
      return biomeIds[source];
    });
    final data = _ChunkWriter();
    final heights = List<int>.filled(256, 0);
    for (var s = 0; s < sectionCount; s++) {
      final section = s < sections.length ? sections[s] : null;
      final mappedPalette = section?.palette
          .map((id) => mapBlockState?.call(id) ?? id)
          .toList();
      final states = s < sections.length
          ? List<int>.generate(
              4096,
              (i) => mappedPalette![section!.indices?[i] ?? 0],
            )
          : List<int>.filled(4096, 0);
      var nonAir = 0, fluids = 0;
      for (var i = 0; i < states.length; i++) {
        final state = states[i];
        if (!_isAir(state)) {
          nonAir++;
          if (_hasFluid(state)) fluids++;
          heights[i & 255] = s * 16 + (i >> 8) + 1;
        }
      }
      // LevelChunkSection.write in 26.2 includes BOTH counts.
      data.i16(nonAir);
      data.i16(fluids);
      _palette(data, states, minBits: 4, maxLocalBits: 8, globalBits: 15);
      _palette(
        data,
        biomeValues,
        minBits: 1,
        maxLocalBits: 3,
        globalBits: 7, // Vanilla 26.2 has 66 biome registry entries.
      );
    }
    final encoded = data.take();
    if (encoded.length > 2097152) {
      throw const FormatException('Java chunk data exceeds two megabytes');
    }
    final out = _ChunkWriter()
      ..i32(cx)
      ..i32(cz);
    // ClientboundLevelChunkPacketData: map<Heightmap.Types, long[]>.
    // WORLD_SURFACE is exact. Motion-blocking predicates are not available in
    // this bridge; omit those optional entries instead of inventing their data.
    out.varInt(1);
    out.varInt(1); // Heightmap.Types.WORLD_SURFACE (not an NBT tag).
    final heightLongs = _pack(heights, (sectionCount * 16).bitLength);
    out.varInt(heightLongs.length);
    for (final value in heightLongs) {
      out.i64(value);
    }
    out.varInt(encoded.length);
    out.raw(encoded);
    out.varInt(0); // No block entity NBT exists in the bridge.
    _light(out);
    return out.take();
  }

  Uint8List lightPacket({required int sectionCount}) {
    _checkSectionCount(sectionCount);
    final out = _ChunkWriter()
      ..varInt(cx)
      ..varInt(cz);
    _light(out);
    return out.take();
  }

  void _light(_ChunkWriter out) {
    final skyMask = <int>[], blockMask = <int>[];
    final emptySky = <int>[], emptyBlock = <int>[];
    final skyArrays = <List<int>>[], blockArrays = <List<int>>[];
    void add(
      List<int>? bytes,
      int bit,
      List<int> mask,
      List<int> empty,
      List<List<int>> arrays,
    ) {
      if (bytes == null) return; // Absent never means clear.
      if (bytes.every((b) => b == 0)) {
        empty.add(bit);
      } else {
        mask.add(bit);
        arrays.add(bytes);
      }
    }

    for (var s = 0; s < sections.length; s++) {
      // Java includes one extra light section below and above the dimension.
      add(sections[s].skyLight, s + 1, skyMask, emptySky, skyArrays);
      add(sections[s].blockLight, s + 1, blockMask, emptyBlock, blockArrays);
    }
    for (final bits in [skyMask, blockMask, emptySky, emptyBlock]) {
      final longs = List<int>.filled(
        bits.isEmpty ? 0 : (bits.last ~/ 64) + 1,
        0,
      );
      for (final bit in bits) {
        longs[bit ~/ 64] |= 1 << (bit % 64);
      }
      out.varInt(longs.length);
      for (final value in longs) {
        out.i64(value);
      }
    }
    for (final arrays in [skyArrays, blockArrays]) {
      out.varInt(arrays.length);
      for (final bytes in arrays) {
        out.varInt(2048);
        out.raw(bytes);
      }
    }
  }
}

void _palette(
  _ChunkWriter out,
  List<int> values, {
  required int minBits,
  required int maxLocalBits,
  required int globalBits,
}) {
  final ids = <int, int>{};
  final indices = [
    for (final value in values) ids.putIfAbsent(value, () => ids.length),
  ];
  if (ids.length == 1) {
    out.u8(0);
    out.varInt(ids.keys.single);
    return; // 26.2: no zero long count, even for single-valued containers.
  }
  var bits = (ids.length - 1).bitLength;
  if (bits < minBits) bits = minBits;
  final direct = bits > maxLocalBits;
  if (direct) bits = globalBits;
  if (direct && values.any((id) => id >= (1 << bits))) {
    throw const FormatException('State ID exceeds Java registry palette width');
  }
  out.u8(bits);
  if (!direct) {
    out.varInt(ids.length);
    for (final id in ids.keys) {
      out.varInt(id);
    }
  }
  // PalettedContainer uses fixed-size long arrays, with no length prefix.
  for (final word in _pack(direct ? values : indices, bits)) {
    out.i64(word);
  }
}

List<int> _pack(List<int> values, int bits) {
  final perLong = 64 ~/ bits;
  final words = List<int>.filled((values.length + perLong - 1) ~/ perLong, 0);
  for (var i = 0; i < values.length; i++) {
    words[i ~/ perLong] |= values[i] << ((i % perLong) * bits);
  }
  return words;
}

// IDs from 26.2 Blocks registration order, expanded using VSTATES properties.
bool _isAir(int state) => state == 0 || state == 15292 || state == 15293;
bool _hasFluid(int state) =>
    state < _fluidStates.length * 8 &&
    (_fluidStates[state >> 3] & (1 << (state & 7))) != 0;

// Fluid-state membership for all 32366 states; water/lava, aquatic plants,
// bubble columns and waterlogged=true, in sorted StateDefinition property order.
final Uint8List _fluidStates = base64Decode(
  'AAAAAACgqqqqqsr///8/AAAAAAAIAAAAAAAAAAAAAFBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAqKqqqqqqAgDAAQAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACoqqqqqqqqqqqqqqqqAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgKqqqqqqqqqq'
  'qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqioAAAAAAAAAgKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
  'qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
  'qqqqqqqqqqqqqqqqqqqqqqqqqqqqAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYGZmZgYAAAAAAAAAAAAAAAAAAFRVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVAQAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAMDMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzExVVVVVVVU1MzMzAwAAAAAAAMDM'
  'zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMDAAAAEBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVRWoqqqqqqqqqqqq'
  'qo7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI6DmZmZmaqqqqqqqqqqqioAAAAAAKCqqqqqqqqqqqqKKgAA'
  'AAAAAAAAAAAAAAAAAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQDgOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7j'
  'OI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI4DAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAqqoqAAAAAAAAAAAAAAAAVVVVVVVVVVVV'
  'VVVVVQAAADAzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzNTVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVpaqqqqqqqqqq'
  'qqqqKlRVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVBQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAVFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwMzMz'
  'MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUFVVVVVVVVVVVQUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAMD///8BAKqqqqoAqKqqqqqqqqqqqqqqqqqqqhIAwFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV1XEcx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ec'
  'x3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ec'
  'x3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ec'
  'x3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ec'
  'x3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ec'
  'x3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ec'
  'x3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ec'
  'x3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3FUVVVVAQAAAAAAAAAAAAAAoKqqqqqqqqqqqqqqqgoAAAAAAAAA'
  'AAAAAFQVzMzMzMzMzMxUVVVVVVVVVVVVVVVVVVVVAQAAAAAAAABUVVVVVVVVVVVVVVVVVVVVVVVVVQEAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAABUVVVVVVVVVVVVAQAAAAAAAAAAAAAAAABVVVVVVVVVVVVVx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ec'
  'x3Ecx1FBVVVVVVVVVVVVVXUcx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3EcqqqqqqqqqqqqqioAAACO4ziO'
  '4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziOA1VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUAAAAA'
  'UFVVVVVVpaqqqqqqqqqqqqo6juM4juM4juM4juM4juM4juM4juM4juM4juM4juM4juM4juM4juM4DlVVVVVVVVVVVVXVcRzHcRzH'
  'cRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcVBVVVVVVVVVVVVVHcdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdx'
  'HMdxHMdxHMdxHAegqqqqqqqqqqqqqjqO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4zgOVVVVVVVVVVVVVdVx'
  'HMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxqKqqqqqqqqqqqqqO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO'
  '4ziO4ziO4ziO4ziO4ziOg6qqqqqqqqqqqqrqOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOFRVVVVVVVVV'
  'VVVVx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx3Ecx6GqqqqqqqqqqqqqOo7jOI7jOI7jOI7jOI7jOI7jOI7j'
  'OI7jOI7jOI7jOI7jOI7jOI7jOA6oqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
  'qqqqqqoyMzMzMzMzMzMzMzMzMzMzQxUAAABVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVUAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV'
  'VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVWqqqqqqgAAAAAAAAAAAAAAAABQVVVVVVVVFVBVVVVVVVVVVVVVHcdxHMdxHMdxHMdx'
  'HMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHIeqqqqqqqqqqqqq6jiO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO'
  '4ziO4zhUVVVVVVVVVVVVVcdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMehqqqqqqqqqqqqqjqO4ziO4ziO'
  '4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4ziO4zgOAABAVRUAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
);

class _BridgeReader {
  final Uint8List bytes;
  late final ByteData data = ByteData.sublistView(bytes);
  int offset = 0;
  _BridgeReader(this.bytes);
  int get remaining => bytes.length - offset;
  void need(int n) {
    if (n > remaining) throw const FormatException('Truncated bridge chunk');
  }

  int u8() {
    need(1);
    return bytes[offset++];
  }

  int u16() {
    need(2);
    final v = data.getUint16(offset, Endian.little);
    offset += 2;
    return v;
  }

  int i32() {
    need(4);
    final v = data.getInt32(offset, Endian.little);
    offset += 4;
    return v;
  }

  Uint8List raw(int n) {
    need(n);
    final v = Uint8List.sublistView(bytes, offset, offset + n);
    offset += n;
    return v;
  }
}

// Private to keep this module independent of the parent agent's wire.dart.
class _ChunkWriter {
  final _bytes = BytesBuilder(copy: false);
  void raw(List<int> bytes) => _bytes.add(bytes);
  void u8(int v) => _bytes.addByte(v & 255);
  void i16(int v) {
    final b = ByteData(2)..setInt16(0, v);
    raw(b.buffer.asUint8List());
  }

  void i32(int v) {
    final b = ByteData(4)..setInt32(0, v);
    raw(b.buffer.asUint8List());
  }

  void i64(int v) {
    final b = ByteData(8)..setInt64(0, v);
    raw(b.buffer.asUint8List());
  }

  void varInt(int v) {
    v &= 0xffffffff;
    do {
      final b = v & 127;
      v = v >>> 7;
      u8(b | (v == 0 ? 0 : 128));
    } while (v != 0);
  }

  Uint8List take() => _bytes.takeBytes();
}
