import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_proxy/protocol/state_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'full bundled 26.2 registry maps identically and in reverse order',
    () async {
      final snapshot = jsonDecode(
        await rootBundle.loadString('assets/registries.json'),
      ) as Map;
      final states = snapshot['states'] as List;
      final same = BlockStateRegistry.map(states, states);
      expect(same.identity, isTrue);
      expect(same.unsupported, isEmpty);
      final reversed = BlockStateRegistry.map(states.reversed.toList(), states);
      expect(reversed.unsupported, isEmpty);
      expect(
        reversed.ids,
        List.generate(states.length, (i) => states.length - i - 1),
      );
    },
  );
  const vanilla = [
    'minecraft:air',
    'minecraft:stone',
    'minecraft:oak_slab[type=bottom,waterlogged=false]',
    'minecraft:oak_slab[type=bottom,waterlogged=true]',
  ];
  test('mapping accepts different lengths, orders and namespace spelling', () {
    final registry = BlockStateRegistry.map([
      'oak_slab[waterlogged=true,type=bottom]',
      'air',
      'stone',
    ], vanilla);
    expect(registry.ids, [3, 0, 1]);
    expect(registry.identity, isFalse);
    expect(registry.unsupported, isEmpty);
    expect(registry.translate(0), 3);
    expect(() => registry.translate(-1), throwsFormatException);
    expect(() => registry.translate(3), throwsFormatException);
    expect(() => registry.ids[0] = 2, throwsUnsupportedError);
  });
  test('unavailable states use visible stone and report exact names', () {
    final registry = BlockStateRegistry.map([
      'air',
      'mod:unknown',
      'oak_slab[type=top,waterlogged=false]',
    ], vanilla);
    expect(registry.ids, [0, 1, 1]);
    expect(registry.unsupported, [
      'mod:unknown',
      'oak_slab[type=top,waterlogged=false]',
    ]);
  });
  test('matching states retain identity while corrupt tables fail', () {
    expect(BlockStateRegistry.map(vanilla, vanilla).identity, isTrue);
    for (final source in <List<dynamic>>[
      [],
      [null],
      ['stone'],
      ['air', 'oak_log[axis=x'],
    ]) {
      expect(
        () => BlockStateRegistry.map(source, vanilla),
        throwsFormatException,
      );
    }
    expect(
      () => BlockStateRegistry.map(['air'], ['air', 'minecraft:air', 'stone']),
      throwsFormatException,
    );
  });
}
