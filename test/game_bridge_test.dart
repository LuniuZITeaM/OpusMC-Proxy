import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_agent/protocol/game_bridge.dart';
import 'package:opus_mc_agent/protocol/ids.dart';
import 'package:opus_mc_agent/protocol/wire.dart';

class Harness {
  final packets = <(String, List<int>)>[];
  final messages = <Map<String, dynamic>>[];
  final logs = <String>[];
  late final game = GameBridge(
    emit: (type, writer) {
      expect(clientbound.containsKey(type), isTrue, reason: type);
      packets.add((type, writer.take()));
    },
    upstream: messages.add,
    registries: {
      'dimensions': {
        'minecraft:overworld': 0,
        'minecraft:overworld_caves': 1,
        'minecraft:the_end': 2,
        'minecraft:the_nether': 3,
      },
      'biomes': {'minecraft:plains': 5, 'minecraft:desert': 9},
      'entities': {'minecraft:pig': 7, 'minecraft:player': 12},
      'items': {'minecraft:stone': 1},
      'menus': {'minecraft:generic_9x3': 2},
      'clocks': {'minecraft:overworld': 4},
    },
    renderDistance: 8,
    log: logs.add,
  );

  Reader packet(String type) =>
      Reader(packets.lastWhere((p) => p.$1 == type).$2);
  void receive(String type, Writer writer) {
    expect(serverbound.containsKey(type), isTrue, reason: type);
    final r = Reader(writer.take());
    game.onPacket(type, r);
    expect(r.remaining, 0, reason: 'Unread $type payload');
  }

  void login() => game.onMessage({
    't': 'login',
    'eid': 42,
    'dim': 'overworld',
    'minY': -64,
    'height': 384,
    'mode': 'creative',
  });
  void position({int id = 5}) => game.onMessage({
    't': 'pos',
    'id': id,
    'x': -1.5,
    'y': 70.0,
    'z': 32.0,
    'yaw': 270.0,
    'pitch': -30.0,
  });
}

String text(Reader r) {
  expect(r.u8(), 8); // anonymous network NBT TAG_String
  return utf8.decode(r.raw(r.i16() & 65535));
}

void spawnInfo(
  Reader r, {
  required int dimension,
  required String name,
  int mode = 1,
}) {
  expect(r.varInt(), dimension); // registry ID, never holder ID + 1
  expect(r.string(), name);
  expect(r.i64(), 0);
  expect(r.u8(), mode);
  expect(r.u8(), 255);
  expect(r.boolValue(), false);
  expect(r.boolValue(), false);
  expect(r.boolValue(), false);
  expect(r.varInt(), 0);
  expect(r.varInt(), 63);
}

void main() {
  test(
    'login contains the complete 26.2 common spawn and trailing booleans',
    () {
      final h = Harness();
      expect(h.game.sectionCount, 24);
      h.login();
      final r = h.packet('LOGIN');
      expect(r.i32(), 42);
      expect(r.boolValue(), false);
      final dimensions = [for (var n = r.varInt(); n > 0; n--) r.string()];
      expect(dimensions, contains('minecraft:the_nether'));
      expect(r.varInt(), 20);
      expect(r.varInt(), 8);
      expect(r.varInt(), 8);
      expect(r.boolValue(), false);
      expect(r.boolValue(), true);
      expect(r.boolValue(), false);
      spawnInfo(r, dimension: 0, name: 'minecraft:overworld');
      expect(r.boolValue(), false); // onlineMode: new in 26.2
      expect(r.boolValue(), false); // enforcesSecureChat
      expect(r.remaining, 0);
      expect(h.messages, [
        {'t': 'settings', 'rd': 8},
      ]);
      expect(h.packet('GAME_EVENT').u8(), 13);
    },
  );

  test('ticks start only after upstream position; respawn resets the gate', () {
    final h = Harness();
    h.game.tick();
    expect(h.messages, isEmpty);
    h.login();
    h.game.tick();
    expect(h.messages.where((m) => m['t'] == 'tick'), isEmpty);
    h.position();
    h.game.tick();
    expect(h.messages.last['pos'], [
      -1.5,
      70.0,
      32.0,
      270.0,
      -30.0,
      false,
      false,
    ]);
    h.game.onMessage({
      't': 'respawn',
      'dim': 'nether',
      'height': 256,
      'minY': 0,
      'mode': 'creative',
    });
    final r = h.packet('RESPAWN');
    spawnInfo(r, dimension: 3, name: 'minecraft:the_nether');
    expect(r.u8(), 3);
    expect(r.remaining, 0);
    expect(h.game.sectionCount, 16);
    final count = h.messages.length;
    h.game.tick();
    expect(h.messages.length, count);
  });

  test(
    'teleport layout, relative state, cache floor and matching acknowledgments',
    () {
      final h = Harness()
        ..login()
        ..position();
      final center = h.packet('SET_CHUNK_CACHE_CENTER');
      expect([center.varInt(), center.varInt()], [-1, 2]);
      expect(center.remaining, 0);
      h.game.onMessage({
        't': 'pos',
        'id': 9,
        'x': 2.0,
        'y': 1.0,
        'z': -2.0,
        'yaw': 15.0,
        'pitch': 5.0,
        'rel': {'x': true, 'y': true, 'z': true, 'yaw': true, 'pitch': true},
      });
      final r = h.packet('PLAYER_POSITION');
      expect(r.varInt(), 9);
      expect([r.f64(), r.f64(), r.f64()], [2.0, 1.0, -2.0]);
      expect([r.f64(), r.f64(), r.f64()], [0, 0, 0]);
      expect([r.f32(), r.f32()], [15, 5]);
      expect(r.i32(), 31);
      expect(r.remaining, 0);
      h.receive('ACCEPT_TELEPORTATION', Writer()..varInt(123));
      expect(h.messages.where((m) => m['t'] == 'tpok'), isEmpty);
      h.receive('ACCEPT_TELEPORTATION', Writer()..varInt(5));
      h.receive('ACCEPT_TELEPORTATION', Writer()..varInt(9));
      h.receive('ACCEPT_TELEPORTATION', Writer()..varInt(9));
      expect(h.messages.where((m) => m['t'] == 'tpok').map((m) => m['id']), [
        5,
        9,
      ]);
      h.game.tick();
      expect(h.messages.last['pos'], [
        0.5,
        71.0,
        30.0,
        285.0,
        -25.0,
        false,
        false,
      ]);
    },
  );

  test(
    'all movement variants preserve missing fields and raw degree angles',
    () {
      final h = Harness()
        ..login()
        ..position();
      h.receive('ACCEPT_TELEPORTATION', Writer()..varInt(5));
      h.receive('PLAYER_INPUT', Writer()..u8(1 | 4 | 16 | 32 | 64));
      h.receive(
        'MOVE_PLAYER_POS_ROT',
        Writer()
          ..f64(10)
          ..f64(80)
          ..f64(-20)
          ..f32(-450)
          ..f32(27)
          ..u8(3),
      );
      h.game.tick();
      expect(h.messages.last['pos'], [
        10.0,
        80.0,
        -20.0,
        -450.0,
        27.0,
        true,
        true,
      ]);
      expect(h.messages.last['keys'], {
        'f': true,
        'b': false,
        'l': true,
        'r': false,
        'j': true,
        's': true,
        'sp': true,
      });
      h.receive(
        'MOVE_PLAYER_POS',
        Writer()
          ..f64(11)
          ..f64(81)
          ..f64(-21)
          ..u8(0),
      );
      h.receive(
        'MOVE_PLAYER_ROT',
        Writer()
          ..f32(540)
          ..f32(-45)
          ..u8(1),
      );
      h.receive('MOVE_PLAYER_STATUS_ONLY', Writer()..u8(2));
      h.game.tick();
      expect(h.messages.last['pos'], [
        11.0,
        81.0,
        -21.0,
        540.0,
        -45.0,
        false,
        true,
      ]);
    },
  );

  test(
    'movement cannot create initial state or overwrite an unconfirmed teleport',
    () {
      final h = Harness()..login();
      Writer move() => Writer()
        ..f64(999)
        ..f64(999)
        ..f64(999)
        ..u8(1);
      h.receive('MOVE_PLAYER_POS', move());
      h.game.tick();
      expect(h.messages.where((m) => m['t'] == 'tick'), isEmpty);
      h.position();
      h.receive('MOVE_PLAYER_POS', move());
      h.game.tick();
      expect((h.messages.last['pos'] as List).first, -1.5);
      expect(
        () => h.receive(
          'MOVE_PLAYER_POS',
          Writer()
            ..f64(double.nan)
            ..f64(0)
            ..f64(0)
            ..u8(0),
        ),
        throwsFormatException,
      );
    },
  );

  test('biomes map resource names and expose an immutable ID list', () {
    final h = Harness();
    h.game.onMessage({
      't': 'biomes',
      'list': ['desert', 'minecraft:plains', 'missing'],
    });
    expect(h.game.biomeIds, [9, 5, 5]);
    expect(() => h.game.biomeIds.add(1), throwsUnsupportedError);
    expect(h.logs.single, contains('Unknown biome'));
  });

  test('block tuples retain negative Y and unload uses Z then X', () {
    final h = Harness();
    h.game.onMessage({
      't': 'blocks',
      'list': [-2, -64, 17, 30000, 0, 319, -1, 7],
    });
    final updates = h.packets.where((p) => p.$1 == 'BLOCK_UPDATE').toList();
    final r = Reader(updates.first.$2);
    expect(r.position(), {'x': -2, 'y': -64, 'z': 17});
    expect(r.varInt(), 30000);
    expect(r.remaining, 0);
    h.game.onMessage({'t': 'unload', 'cx': -3, 'cz': 12});
    final unload = h.packet('FORGET_LEVEL_CHUNK');
    expect([unload.i32(), unload.i32()], [12, -3]);
    expect(
      () => h.game.onMessage({
        't': 'blocks',
        'list': [1],
      }),
      throwsFormatException,
    );
  });

  test('health, experience, abilities and anonymous-NBT chat layouts', () {
    final h = Harness();
    h.game.onMessage({'t': 'health', 'hp': 9.5, 'food': 13, 'sat': 2.5});
    var r = h.packet('SET_HEALTH');
    expect([r.f32(), r.varInt(), r.f32()], [9.5, 13, 2.5]);
    expect(r.remaining, 0);
    h.game.onMessage({'t': 'xp', 'bar': 0.5, 'level': 6, 'total': 111});
    r = h.packet('SET_EXPERIENCE');
    expect([r.f32(), r.varInt(), r.varInt()], [0.5, 6, 111]);
    h.game.onMessage({'t': 'abilities', 'flags': 15});
    r = h.packet('PLAYER_ABILITIES');
    expect(r.u8(), 15);
    expect(r.f32(), closeTo(0.05, 0.00001));
    expect(r.f32(), closeTo(0.1, 0.00001));
    expect(r.remaining, 0);
    h.game.onMessage({'t': 'chat', 'text': 'hello 世界', 'bar': true});
    r = h.packet('SYSTEM_CHAT');
    expect(text(r), 'hello 世界');
    expect(r.boolValue(), true);
    expect(r.remaining, 0);
  });

  test('rain and mode use the exact game event numbers', () {
    final h = Harness();
    h.game.onMessage({'t': 'rain', 'on': true, 'level': 0.5, 'thunder': 0.25});
    h.game.onMessage({'t': 'rain', 'on': false});
    h.game.onMessage({'t': 'mode', 'mode': 'spectator'});
    final values = h.packets.map((p) {
      final r = Reader(p.$2);
      return [r.u8(), r.f32()];
    }).toList();
    expect(values, [
      [1, 0],
      [7, 0.5],
      [8, 0.25],
      [2, 0],
      [3, 3],
    ]);
  });

  test(
    '26.2 time uses clock registry, VarLong ticks, partial tick and rate',
    () {
      final h = Harness();
      h.game.onMessage({'t': 'time', 'age': 100000, 'day': 6000.5, 'rate': 0});
      final r = h.packet('SET_TIME');
      expect(r.i64(), 100000);
      expect(r.varInt(), 1);
      expect(r.varInt(), 4);
      expect(r.varInt(), 6000); // this small VarLong has the same encoding
      expect(r.f32(), 0.5);
      expect(r.f32(), 0);
      expect(r.remaining, 0);
    },
  );

  test(
    'dig, place, use and drops propagate actions and acknowledge prediction',
    () {
      final h = Harness();
      h.receive(
        'PLAYER_ACTION',
        Writer()
          ..varInt(0)
          ..position(-1, -60, 3)
          ..u8(5)
          ..varInt(37),
      );
      expect(h.messages.last, {
        't': 'dig',
        'status': 0,
        'x': -1,
        'y': -60,
        'z': 3,
        'face': 5,
      });
      expect(h.packet('BLOCK_CHANGED_ACK').varInt(), 37);
      h.receive(
        'USE_ITEM_ON',
        Writer()
          ..varInt(1)
          ..position(2, 80, -5)
          ..varInt(4)
          ..f32(0.25)
          ..f32(0.5)
          ..f32(0.75)
          ..boolValue(true)
          ..boolValue(false)
          ..varInt(38),
      );
      expect(h.messages.last, {
        't': 'place',
        'x': 2,
        'y': 80,
        'z': -5,
        'face': 4,
        'cx': 0.25,
        'cy': 0.5,
        'cz': 0.75,
        'hand': 'off',
        'inside': true,
        'worldBorder': false,
      });
      expect(h.packet('BLOCK_CHANGED_ACK').varInt(), 38);
      h.receive(
        'USE_ITEM',
        Writer()
          ..varInt(0)
          ..varInt(39)
          ..f32(270)
          ..f32(-20),
      );
      expect(h.messages.last, {
        't': 'use',
        'hand': 'main',
        'yaw': 270.0,
        'pitch': -20.0,
      });
      expect(h.packet('BLOCK_CHANGED_ACK').varInt(), 39);
      for (final action in [3, 4, 5]) {
        h.receive(
          'PLAYER_ACTION',
          Writer()
            ..varInt(action)
            ..position(0, 0, 0)
            ..u8(0)
            ..varInt(0),
        );
      }
      expect(h.messages.sublist(3), [
        {'t': 'drop', 'all': true},
        {'t': 'drop', 'all': false},
        {'t': 'release'},
      ]);
    },
  );

  test('attack is a dedicated packet; interact uses LP vector and hand', () {
    final h = Harness();
    h.receive('ATTACK', Writer()..varInt(42));
    expect(h.messages.last, {'t': 'attack', 'id': 42});
    h.receive(
      'INTERACT',
      Writer()
        ..varInt(43)
        ..varInt(1)
        ..u8(0)
        ..boolValue(true),
    );
    expect(h.messages.last, {
      't': 'interact',
      'id': 43,
      'hand': 'off',
      'x': 0.0,
      'y': 0.0,
      'z': 0.0,
      'sneak': true,
    });
    h.receive('SWING', Writer()..varInt(1));
    expect(h.messages.last, {'t': 'swing', 'hand': 'off'});
    h.receive('CLIENT_COMMAND', Writer()..varInt(0));
    expect(h.messages.last, {'t': 'respawn'});
  });

  test('chat consumes signature, fixed bitset and 26.2 checksum', () {
    final h = Harness();
    h.receive(
      'CHAT',
      Writer()
        ..string('hello')
        ..i64(1)
        ..i64(2)
        ..boolValue(true)
        ..raw(List.filled(256, 123))
        ..varInt(3)
        ..raw([1, 2, 3])
        ..u8(7),
    );
    expect(h.messages.last, {'t': 'chat', 'text': 'hello'});
    h.receive('CHAT_COMMAND', Writer()..string('time set day'));
    expect(h.messages.last, {'t': 'chat', 'text': '/time set day'});
    h.receive(
      'CHAT_COMMAND_SIGNED',
      Writer()
        ..string('say hi')
        ..i64(1)
        ..i64(2)
        ..varInt(1)
        ..string('message')
        ..raw(List.filled(256, 0))
        ..varInt(0)
        ..raw([0, 0, 0])
        ..u8(0),
    );
    expect(h.messages.last, {'t': 'chat', 'text': '/say hi'});
  });

  test('entity spawn uses zero LP movement before packed angles and data', () {
    final h = Harness();
    h.game.onMessage({
      't': 'spawn',
      'id': 71,
      'type': 'pig',
      'uuid': '00112233-4455-6677-8899-aabbccddeeff',
      'x': 1,
      'y': 65,
      'z': -2,
      'yaw': 90,
      'pitch': -45,
      'data': 6,
    });
    final r = h.packet('ADD_ENTITY');
    expect(r.varInt(), 71);
    expect(r.raw(16), [
      0,
      17,
      34,
      51,
      68,
      85,
      102,
      119,
      136,
      153,
      170,
      187,
      204,
      221,
      238,
      255,
    ]);
    expect(r.varInt(), 7);
    expect([r.f64(), r.f64(), r.f64()], [1, 65, -2]);
    expect(r.u8(), 0); // zero LP vector, not three legacy velocity shorts
    expect([r.u8(), r.u8(), r.u8()], [224, 64, 64]);
    expect(r.varInt(), 6);
    expect(r.remaining, 0);
    h.game.onMessage({'t': 'move', 'id': 71, 'x': 2, 'y': 66, 'z': -3});
    final move = h.packet('ENTITY_POSITION_SYNC');
    expect(move.varInt(), 71);
    expect([move.f64(), move.f64(), move.f64()], [2, 66, -3]);
    expect([move.f64(), move.f64(), move.f64()], [0, 0, 0]);
    expect([move.f32(), move.f32()], [90, -45]);
    expect(move.boolValue(), false);
    expect(move.remaining, 0);
  });

  test(
    'LP compressed nonzero velocity matches independent vanilla bit packing',
    () {
      final h = Harness();
      h.game.onMessage({
        't': 'vel',
        'id': 2,
        'v': [4.0, -2.0, 0.0],
      });
      final r = h.packet('SET_ENTITY_MOTION');
      expect(r.varInt(), 2);
      // scale 4, x=32766, y=8192, z=16383; marker=4, continuation=1.
      final bits = 4 | (32766 << 3) | (8192 << 18) | (16383 << 33);
      expect(r.u8(), bits & 255);
      expect(r.u8(), (bits >> 8) & 255);
      expect(r.i32() & 0xffffffff, (bits >> 16) & 0xffffffff);
      expect(r.varInt(), 1);
      expect(r.remaining, 0);
    },
  );

  test(
    'players and base metadata have checked fixed-bitset and serializer IDs',
    () {
      final h = Harness();
      const uuid = '00112233-4455-6677-8899-aabbccddeeff';
      h.game.onMessage({
        't': 'players',
        'list': [
          {'uuid': uuid, 'name': 'Alex'},
        ],
      });
      var r = h.packet('PLAYER_INFO_UPDATE');
      expect(r.u8(), 9);
      expect(r.varInt(), 1);
      r.raw(16);
      expect(r.string(), 'Alex');
      expect(r.varInt(), 0);
      expect(r.boolValue(), true);
      expect(r.remaining, 0);
      h.game.onMessage({
        't': 'meta',
        'id': 71,
        'm': {'shared_flags': 34, 'custom_name': 'Pig', 'pose': 'crouching'},
      });
      r = h.packet('SET_ENTITY_DATA');
      expect(r.varInt(), 71);
      expect([r.u8(), r.varInt(), r.u8()], [0, 0, 34]);
      expect([r.u8(), r.varInt()], [2, 6]);
      expect(r.boolValue(), true);
      expect(text(r), 'Pig');
      expect([r.u8(), r.varInt(), r.varInt()], [6, 20, 5]);
      expect(r.u8(), 255);
      expect(r.remaining, 0);
      h.game.onMessage({'t': 'players', 'list': []});
      r = h.packet('PLAYER_INFO_REMOVE');
      expect(r.varInt(), 1);
      r.raw(16);
      expect(r.remaining, 0);
    },
  );

  test('inventory delegation owns held and container packets', () {
    final h = Harness();
    h.game.onMessage({'t': 'held', 'slot': 5});
    final r = h.packet('SET_HELD_SLOT');
    expect(r.varInt(), 5);
    expect(r.remaining, 0);
    h.receive('SET_CARRIED_ITEM', Writer()..i16(6));
    expect(h.messages.last, {'t': 'held', 'slot': 6});
    expect(h.logs, isEmpty);
  });
}
