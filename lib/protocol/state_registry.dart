/// State names identify blocks across independently numbered registries.
/// Property ordering and the default namespace have no semantic significance.
String canonicalState(String state) {
  final bracket = state.indexOf('[');
  final name = (bracket < 0 ? state : state.substring(0, bracket)).replaceFirst(
    RegExp(r'^minecraft:'),
    '',
  );
  if (bracket < 0) return name;
  if (!state.endsWith(']')) {
    throw const FormatException('Malformed block state');
  }
  final properties = state.substring(bracket + 1, state.length - 1).split(',')
    ..sort();
  return '$name[${properties.join(',')}]';
}

/// Map every upstream state ID to a legal client state ID. Unsupported states
/// use visible stone rather than accidentally borrowing an unrelated numeric ID.
class BlockStateRegistry {
  BlockStateRegistry._(this.ids, this.unsupported, this.identity);

  final List<int> ids;
  final List<String> unsupported;
  final bool identity;

  factory BlockStateRegistry.map(
    List<dynamic> upstream,
    List<dynamic> vanilla,
  ) {
    if (upstream.isEmpty || upstream.length > 65536 || vanilla.isEmpty) {
      throw const FormatException('方块状态表长度无效');
    }
    String parse(dynamic value) {
      if (value is! String || value.isEmpty || value.length > 2048) {
        throw const FormatException('方块状态表包含无效条目');
      }
      return canonicalState(value);
    }

    final target = <String, int>{};
    for (var i = 0; i < vanilla.length; i++) {
      final state = parse(vanilla[i]);
      if (target.containsKey(state)) {
        throw const FormatException('客户端方块状态表包含重复条目');
      }
      target[state] = i;
    }
    final stone = target['stone'];
    if (target['air'] != 0 || stone == null) {
      throw const FormatException('客户端方块状态表缺少基础方块');
    }
    final source = upstream.map(parse).toList();
    if (!source.contains('air')) {
      throw const FormatException('上游方块状态表缺少 air');
    }
    final missing = <String>[];
    final ids = <int>[];
    var identity = upstream.length == vanilla.length;
    for (var i = 0; i < source.length; i++) {
      final id = target[source[i]];
      if (id == null) missing.add(source[i]);
      ids.add(id ?? stone);
      if (ids.last != i) identity = false;
    }
    return BlockStateRegistry._(
      List.unmodifiable(ids),
      List.unmodifiable(missing),
      identity,
    );
  }

  int translate(int upstreamId) {
    if (upstreamId < 0 || upstreamId >= ids.length) {
      throw FormatException('上游方块状态编号越界：$upstreamId（共 ${ids.length} 项）');
    }
    return ids[upstreamId];
  }
}
