import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_proxy/protocol/inventory_bridge.dart';
import 'package:opus_mc_proxy/protocol/wire.dart';

class _Harness {
  final packets = <(String, Uint8List)>[];
  final messages = <Map<String, dynamic>>[];
  final logs = <String>[];
  late final bridge = InventoryBridge(
    emit: (type, w) => packets.add((type, w.take())),
    upstream: messages.add,
    registries: {
      'items': {
        'minecraft:air': 0,
        'minecraft:stone': 1,
        'minecraft:diamond_sword': 900,
      },
      'menus': {'minecraft:generic_9x3': 2, 'minecraft:lectern': 17},
    },
    log: logs.add,
  );

  void inventory({
    int id = 0,
    int state = 13,
    List<dynamic>? items,
    dynamic cursor,
  }) {
    bridge.onMessage({
      't': 'win',
      'id': id,
      'stateId': state,
      'items': items ?? List<dynamic>.filled(46, null),
      'carried': cursor,
    });
  }

  Reader last(String type) {
    expect(packets.last.$1, type);
    return Reader(packets.last.$2);
  }

  bool packet(String type, Writer w) => bridge.onPacket(type, Reader(w.take()));
}

Map<String, dynamic> _stone([int count = 1, String signature = 'opaque']) => {
  'n': 'stone',
  'c': count,
  'x': signature,
};

void _hash(Writer w, int? id, [int count = 1]) {
  w.boolValue(id != null);
  if (id != null) {
    w.varInt(id);
    w.varInt(count);
    w.varInt(0);
    w.varInt(0);
  }
}

Writer _click({
  int id = 0,
  int state = 13,
  int slot = 36,
  int button = 0,
  int mode = 0,
  Map<int, (int?, int)> changed = const {},
  (int?, int) carried = (null, 0),
}) {
  final w = Writer()
    ..varInt(id)
    ..varInt(state)
    ..i16(slot)
    ..u8(button)
    ..varInt(mode)
    ..varInt(changed.length);
  for (final entry in changed.entries) {
    w.i16(entry.key);
    _hash(w, entry.value.$1, entry.value.$2);
  }
  _hash(w, carried.$1, carried.$2);
  return w;
}

void main() {
  test('synthetic states advance when upstream omits vanilla state IDs', () {
    final h = _Harness();
    h.bridge.onMessage({
      't': 'win',
      'id': 0,
      'items': List<dynamic>.filled(46, null),
    });
    var r = h.last('CONTAINER_SET_CONTENT');
    expect([r.varInt(), r.varInt()], [0, 1]);
    h.bridge.onMessage({'t': 'wslot', 'id': 0, 'i': 36, 'item': _stone()});
    r = h.last('CONTAINER_SET_SLOT');
    expect([r.varInt(), r.varInt()], [0, 2]);
    h.packet('CONTAINER_CLICK', _click(state: 2, carried: (1, 1)));
    expect(h.messages.single['carried'], _stone());
  });

  test(
    'hotbar and offhand swaps preserve distinct signatures of same item ID',
    () {
      for (final pair in [(0, 36), (40, 45)]) {
        final h = _Harness();
        h.inventory(
          items: List<dynamic>.filled(46, null)
            ..[9] = _stone(1, 'clicked')
            ..[pair.$2] = _stone(1, 'swapped'),
          cursor: _stone(2, 'cursor'),
        );
        h.packet(
          'CONTAINER_CLICK',
          _click(
            slot: 9,
            button: pair.$1,
            mode: 2,
            changed: {9: (1, 1), pair.$2: (1, 1)},
            carried: (1, 2),
          ),
        );
        expect(h.messages.single['changed'], [
          [9, _stone(1, 'swapped')],
          [pair.$2, _stone(1, 'clicked')],
        ]);
        expect(h.messages.single['carried'], _stone(2, 'cursor'));
      }
    },
  );

  test(
    'a click prediction never overwrites the authoritative cached source',
    () {
      final h = _Harness();
      h.inventory(
        items: List<dynamic>.filled(46, null)..[36] = _stone(8, 'source'),
      );
      h.packet(
        'CONTAINER_CLICK',
        _click(changed: {36: (null, 0)}, carried: (1, 8)),
      );
      h.packet('CONTAINER_CLICK', _click(state: 12));
      final r = h.last('CONTAINER_SET_CONTENT');
      expect([r.varInt(), r.varInt(), r.varInt()], [0, 13, 46]);
      for (var i = 0; i < 36; i++) {
        expect(r.varInt(), 0);
      }
      expect([r.varInt(), r.varInt(), r.varInt(), r.varInt()], [8, 1, 0, 0]);
    },
  );

  test(
    'clientbound contents encode 26.2 basic slots, cursor and VarInt ID',
    () {
      final h = _Harness();
      h.inventory(
        id: 300,
        items: [
          null,
          {'n': 'diamond_sword', 'c': 1, 'x': 'signed', 'd': 5},
        ],
        cursor: _stone(2),
      );
      final r = h.last('CONTAINER_SET_CONTENT');
      expect(r.varInt(), 300);
      expect(r.varInt(), 13);
      expect(r.varInt(), 2);
      expect(r.varInt(), 0);
      expect([r.varInt(), r.varInt(), r.varInt(), r.varInt()], [1, 900, 0, 0]);
      expect([r.varInt(), r.varInt(), r.varInt(), r.varInt()], [2, 1, 0, 0]);
      expect(r.remaining, 0);
    },
  );

  test(
    'open, property, held, cursor, player slot, window slot and close codecs',
    () {
      final h = _Harness();
      expect(
        h.bridge.onMessage({
          't': 'open',
          'id': 300,
          'kind': 'generic_9x3',
          'title': 'Chest',
        }),
        isTrue,
      );
      var r = h.last('OPEN_SCREEN');
      expect([r.varInt(), r.varInt(), r.u8(), r.i16()], [300, 2, 8, 5]);
      expect(String.fromCharCodes(r.raw(5)), 'Chest');
      expect(r.remaining, 0);
      h.bridge.onMessage({'t': 'prop', 'id': 300, 'k': 1, 'v': -32});
      r = h.last('CONTAINER_SET_DATA');
      expect([r.varInt(), r.i16(), r.i16()], [300, 1, -32]);
      expect(r.remaining, 0);
      h.bridge.onMessage({'t': 'held', 'slot': 8});
      expect(h.last('SET_HELD_SLOT').varInt(), 8);
      h.bridge.onMessage({'t': 'cursor', 'item': null});
      expect(h.last('SET_CURSOR_ITEM').varInt(), 0);
      h.bridge.onMessage({'t': 'pinv', 'i': 40, 'item': _stone()});
      r = h.last('SET_PLAYER_INVENTORY');
      expect(
        [r.varInt(), r.varInt(), r.varInt(), r.varInt(), r.varInt()],
        [40, 1, 1, 0, 0],
      );
      expect(r.remaining, 0);
      h.bridge.onMessage({
        't': 'wslot',
        'id': 300,
        'state': 27,
        'i': 3,
        'item': null,
      });
      r = h.last('CONTAINER_SET_SLOT');
      expect([r.varInt(), r.varInt(), r.i16(), r.varInt()], [300, 27, 3, 0]);
      expect(r.remaining, 0);
      h.bridge.onMessage({'t': 'wclose', 'id': 300});
      expect(h.last('CONTAINER_CLOSE').varInt(), 300);
    },
  );

  test('pickup restores upstream signature and all opaque stack fields', () {
    final h = _Harness();
    final original = {
      ..._stone(32, 'do-not-decode/+=='),
      'e': [
        ['sharpness', 2],
      ],
      'extra': {'v': 7},
    };
    final items = List<dynamic>.filled(46, null)..[36] = original;
    h.inventory(items: items);
    expect(
      h.packet(
        'CONTAINER_CLICK',
        _click(changed: {36: (null, 0)}, carried: (1, 16)),
      ),
      isTrue,
    );
    expect(h.messages.single, {
      't': 'click',
      'id': 0,
      'slot': 36,
      'button': 0,
      'mode': 0,
      'changed': [
        [36, null],
      ],
      'carried': {...original, 'c': 16},
    });
    expect(original['c'], 32);
    expect(h.logs, isEmpty);
  });

  test(
    'placing and splitting use authoritative cursor identity over target',
    () {
      final h = _Harness();
      final items = List<dynamic>.filled(46, null)..[36] = _stone(1, 'target');
      h.inventory(items: items, cursor: _stone(12, 'cursor'));
      h.packet(
        'CONTAINER_CLICK',
        _click(changed: {36: (1, 5)}, carried: (1, 8), slot: 37),
      );
      final changed = h.messages.single['changed'] as List;
      expect(changed.single, [36, _stone(5, 'cursor')]);
      expect(h.messages.single['carried'], _stone(8, 'cursor'));
    },
  );

  test('shift move resolves signed stacks from original inventory slots', () {
    final h = _Harness();
    h.inventory(
      items: List<dynamic>.filled(46, null)..[36] = _stone(10, 'source'),
    );
    h.packet(
      'CONTAINER_CLICK',
      _click(mode: 1, changed: {36: (null, 0), 9: (1, 10)}),
    );
    expect(h.messages.single['changed'], [
      [36, null],
      [9, _stone(10, 'source')],
    ]);
  });

  test(
    'player inventory updates mirror hotbar, armour and offhand into clicks',
    () {
      for (final pair in [
        (0, 36),
        (8, 44),
        (9, 9),
        (36, 8),
        (39, 5),
        (40, 45),
      ]) {
        final h = _Harness();
        h.inventory();
        h.bridge.onMessage({
          't': 'pinv',
          'i': pair.$1,
          'item': _stone(3, 'slot-${pair.$1}'),
        });
        h.packet('CONTAINER_CLICK', _click(slot: pair.$2, carried: (1, 3)));
        expect(h.messages.single['carried'], _stone(3, 'slot-${pair.$1}'));
      }
    },
  );

  test('container inventory mirrors player slots in both directions', () {
    final h = _Harness();
    h.inventory();
    h.bridge.onMessage({'t': 'open', 'id': 300, 'kind': 'generic_9x3'});
    h.inventory(
      id: 300,
      items: List<dynamic>.filled(63, null)..[54] = _stone(6, 'chest-hotbar'),
    );
    h.packet('CONTAINER_CLICK', _click(carried: (1, 6)));
    expect(h.messages.last['carried'], _stone(6, 'chest-hotbar'));
    h.bridge.onMessage({'t': 'pinv', 'i': 0, 'item': _stone(7, 'pinv-hotbar')});
    h.packet('CONTAINER_CLICK', _click(id: 300, slot: 54, carried: (1, 7)));
    expect(h.messages.last['carried'], _stone(7, 'pinv-hotbar'));
  });

  test('held, close and button packets use their exact 26.2 field widths', () {
    final h = _Harness();
    h.packet('SET_CARRIED_ITEM', Writer()..i16(7));
    h.packet(
      'CONTAINER_BUTTON_CLICK',
      Writer()
        ..varInt(300)
        ..varInt(1005),
    );
    h.packet('CONTAINER_CLOSE', Writer()..varInt(300));
    expect(h.messages, [
      {'t': 'held', 'slot': 7},
      {'t': 'button', 'id': 300, 'b': 1005},
      {'t': 'wclose', 'id': 300},
    ]);
  });

  test('creative decodes plain, empty and length-delimited damage stacks', () {
    final h = _Harness();
    h.packet(
      'SET_CREATIVE_MODE_SLOT',
      Writer()
        ..i16(36)
        ..varInt(64)
        ..varInt(1)
        ..varInt(0)
        ..varInt(0),
    );
    h.packet(
      'SET_CREATIVE_MODE_SLOT',
      Writer()
        ..i16(-1)
        ..varInt(0),
    );
    // DAMAGE (3) has a two-byte payload: VarInt 300, not a fixed INT.
    h.packet(
      'SET_CREATIVE_MODE_SLOT',
      Writer()
        ..i16(37)
        ..varInt(1)
        ..varInt(900)
        ..varInt(1)
        ..varInt(0)
        ..varInt(3)
        ..varInt(2)
        ..varInt(300),
    );
    expect(h.messages, [
      {
        't': 'creative',
        'slot': 36,
        'item': {'n': 'stone', 'c': 64},
      },
      {'t': 'creative', 'slot': -1, 'item': null},
      {
        't': 'creative',
        'slot': 37,
        'item': {'n': 'diamond_sword', 'c': 1, 'd': 300},
      },
    ]);
    expect(h.logs, isEmpty);
  });

  test(
    'unsupported creative patches are discarded without breaking next packet',
    () {
      final h = _Harness();
      for (final body in [
        Writer()
          ..varInt(1)
          ..varInt(0)
          ..varInt(1234)
          ..varInt(3)
          ..raw([255, 0, 17]),
        Writer()
          ..varInt(0)
          ..varInt(1)
          ..varInt(3),
        Writer()
          ..varInt(1)
          ..varInt(0)
          ..varInt(3)
          ..varInt(99)
          ..u8(1),
      ]) {
        final r = Reader(
          (Writer()
                ..i16(36)
                ..varInt(1)
                ..varInt(1)
                ..raw(body.take()))
              .take(),
        );
        expect(h.bridge.onPacket('SET_CREATIVE_MODE_SLOT', r), isTrue);
        expect(r.remaining, 0);
      }
      expect(h.messages, isEmpty);
      expect(h.logs, hasLength(3));
      h.packet('SET_CARRIED_ITEM', Writer()..i16(2));
      expect(h.messages.single, {'t': 'held', 'slot': 2});
    },
  );

  test(
    'malformed, stale and out-of-range clicks never forward partial changes',
    () {
      final h = _Harness();
      h.inventory();
      for (final w in [
        _click(state: 12),
        _click(mode: 7),
        _click(slot: 46),
        _click(changed: {46: (null, 0)}),
        _click(carried: (900, 1)),
        _click()..u8(0),
        Writer()
          ..varInt(0)
          ..varInt(13)
          ..i16(0)
          ..u8(0)
          ..varInt(0)
          ..varInt(129),
        Writer()
          ..varInt(0)
          ..varInt(13)
          ..i16(0)
          ..u8(0)
          ..varInt(0)
          ..varInt(1)
          ..i16(1)
          ..u8(1),
      ]) {
        expect(h.packet('CONTAINER_CLICK', w), isTrue);
        expect(h.last('CONTAINER_SET_CONTENT').varInt(), 0);
      }
      expect(h.messages, isEmpty);
      expect(h.logs, hasLength(8));
    },
  );

  test(
    'component hash INT is parsed safely, projected components rejected',
    () {
      final h = _Harness();
      h.inventory();
      final w = Writer()
        ..varInt(0)
        ..varInt(13)
        ..i16(36)
        ..u8(0)
        ..varInt(0)
        ..varInt(0)
        ..boolValue(true)
        ..varInt(1)
        ..varInt(1)
        ..varInt(1)
        ..varInt(3)
        ..i32(-2147483648)
        ..varInt(0);
      final r = Reader(w.take());
      expect(h.bridge.onPacket('CONTAINER_CLICK', r), isTrue);
      expect(r.remaining, 0);
      expect(h.messages, isEmpty);
      expect(h.logs.single, contains('components differ'));
    },
  );

  test('closed container identities cannot leak into later clicks', () {
    final h = _Harness();
    h.inventory();
    h.bridge.onMessage({'t': 'open', 'id': 1, 'kind': 'generic_9x3'});
    h.inventory(id: 1, items: List<dynamic>.filled(63, null)..[0] = _stone());
    h.bridge.onMessage({'t': 'wclose', 'id': 1});
    h.packet('CONTAINER_CLICK', _click(carried: (1, 1)));
    expect(h.messages, isEmpty);
    expect(h.logs.single, contains('not in authoritative'));
  });

  test('unhandled traffic remains available to the gameplay bridge', () {
    final h = _Harness();
    final r = Reader([1, 2, 3]);
    expect(h.bridge.onPacket('MOVE_PLAYER_POS', r), isFalse);
    expect(r.offset, 0);
    expect(h.bridge.onMessage({'t': 'health'}), isFalse);
    expect(h.messages, isEmpty);
    expect(h.packets, isEmpty);
  });
}
