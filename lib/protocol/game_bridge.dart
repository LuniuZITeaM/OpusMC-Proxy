import 'dart:math' as math;

import 'inventory_bridge.dart';
import 'wire.dart';

/// Translates OpusMC's semantic messages to the vanilla 26.2 play protocol.
/// Packet names are GamePacketTypes names with the direction prefix stripped.
/// Coordinates are world coordinates and all rotations remain in degrees.
/// Framing, configuration, keepalives, scheduling and chunks belong to the parent.
class GameBridge {
  GameBridge({
    required this.emit,
    required this.upstream,
    required this.registries,
    required this.renderDistance,
    required this.log,
  }) : _inventory = InventoryBridge(
         emit: emit,
         upstream: upstream,
         registries: registries,
         log: log,
       );

  final void Function(String, Writer) emit;
  final void Function(Map<String, dynamic>) upstream;
  final Map<String, dynamic> registries;
  final int renderDistance;
  final void Function(String) log;
  final InventoryBridge _inventory;

  int _sectionCount = 24;
  int get sectionCount => _sectionCount;
  List<int> _biomeIds = [];
  List<int> get biomeIds => List<int>.unmodifiable(_biomeIds);
  bool _loggedIn = false, _positioned = false;
  double _x = 0, _y = 0, _z = 0, _yaw = 0, _pitch = 0;
  bool _onGround = false, _horizontalCollision = false;
  int _input = 0;
  int? _cacheX, _cacheZ;
  String _dimension = 'minecraft:overworld';
  final Set<int> _teleports = {};
  final Map<int, _Entity> _entities = {};
  final Set<String> _reported = {};
  final Map<String, String> _players = {};

  void _send(String type, void Function(Writer) write) {
    final w = Writer();
    write(w);
    emit(type, w);
  }

  void _report(String message) {
    if (_reported.add(message)) log(message);
  }

  static num _num(Map m, String key, [num fallback = 0]) =>
      m[key] is num ? m[key] as num : fallback;
  static int _int(Map m, String key, [int fallback = 0]) =>
      _num(m, key, fallback).toInt();
  static String _resource(dynamic name) {
    final s = name.toString();
    return s.contains(':') ? s : 'minecraft:$s';
  }

  int? _id(String registry, dynamic name) {
    if (name is int) return name;
    final entries = registries[registry];
    if (entries is! Map || name == null) return null;
    final value = entries[_resource(name)] ?? entries[name];
    return value is int ? value : null;
  }

  static int _mode(dynamic value) {
    if (value is num) return value.toInt().clamp(0, 3);
    return const {
          'survival': 0,
          'creative': 1,
          'adventure': 2,
          'spectator': 3,
        }[value] ??
        0;
  }

  /// Inventory gets first refusal. Unsupported semantic messages are logged once.
  void onMessage(Map<String, dynamic> m) {
    if (_inventory.onMessage(m)) return;
    switch (m['t']) {
      case 'login':
        _login(m);
      case 'respawn':
        _respawn(m);
      case 'biomes':
        final list = m['list'] as List? ?? [];
        _biomeIds = [
          for (final n in list) _id('biomes', n) ?? _missingBiome(n),
        ];
      case 'pos':
        _position(m);
      case 'block':
        _block(m);
      case 'blocks':
        _blocks(m);
      case 'unload':
        // ChunkPos is a long: high 32 bits Z, low 32 bits X.
        _send(
          'FORGET_LEVEL_CHUNK',
          (w) => w
            ..i32(_int(m, 'cz'))
            ..i32(_int(m, 'cx')),
        );
      case 'health':
        _send(
          'SET_HEALTH',
          (w) => w
            ..f32(_num(m, 'hp', 20))
            ..varInt(_int(m, 'food', 20))
            ..f32(_num(m, 'sat', 5)),
        );
      case 'xp':
        _send(
          'SET_EXPERIENCE',
          (w) => w
            ..f32(_num(m, 'bar'))
            ..varInt(_int(m, 'level'))
            ..varInt(_int(m, 'total')),
        );
      case 'abilities':
        _send(
          'PLAYER_ABILITIES',
          (w) => w
            ..u8(_int(m, 'flags'))
            ..f32(_num(m, 'flySpeed', 0.05))
            ..f32(_num(m, 'walkSpeed', 0.1)),
        );
      case 'mode':
        _event(3, _mode(m['mode']));
      case 'chat':
        _send(
          'SYSTEM_CHAT',
          (w) => w
            ..text('${m['text'] ?? ''}')
            ..boolValue(m['bar'] == true),
        );
      case 'rain':
        if (m.containsKey('on')) _event(m['on'] == true ? 1 : 2, 0);
        if (m.containsKey('level')) _event(7, _num(m, 'level'));
        if (m.containsKey('thunder')) _event(8, _num(m, 'thunder'));
      case 'time':
        _time(m);
      case 'spawn':
        _spawn(m);
      case 'players':
        _playersMessage(m);
      case 'meta':
        _meta(m);
      case 'wev':
        _send(
          'LEVEL_EVENT',
          (w) => w
            ..i32(_int(m, 'e'))
            ..position(_int(m, 'x'), _int(m, 'y'), _int(m, 'z'))
            ..i32(_int(m, 'd'))
            ..boolValue(m['global'] == true),
        );
      case 'move':
        _move(m);
      case 'head':
        _send(
          'ROTATE_HEAD',
          (w) => w
            ..varInt(_int(m, 'id'))
            ..u8(_angle(_num(m, 'yaw'))),
        );
      case 'remove':
        final ids = (m['ids'] as List? ?? []).cast<int>();
        for (final id in ids) {
          _entities.remove(id);
        }
        _send('REMOVE_ENTITIES', (w) {
          w.varInt(ids.length);
          for (final id in ids) {
            w.varInt(id);
          }
        });
      case 'pass':
        final ids = (m['list'] as List? ?? []).cast<int>();
        _send('SET_PASSENGERS', (w) {
          w
            ..varInt(_int(m, 'id'))
            ..varInt(ids.length);
          for (final id in ids) {
            w.varInt(id);
          }
        });
      case 'vel':
        final v = m['v'] as List;
        _send('SET_ENTITY_MOTION', (w) {
          w.varInt(_int(m, 'id'));
          _lpVec(w, v.cast<num>());
        });
      case 'vmove':
        _send(
          'MOVE_VEHICLE',
          (w) => w
            ..f64(_num(m, 'x'))
            ..f64(_num(m, 'y'))
            ..f64(_num(m, 'z'))
            ..f32(_num(m, 'yaw'))
            ..f32(_num(m, 'pitch')),
        );
      case 'anim':
        _send(
          'ANIMATE',
          (w) => w
            ..varInt(_int(m, 'id'))
            ..u8(_int(m, 'a')),
        );
      case 'hurt':
        _send(
          'HURT_ANIMATION',
          (w) => w
            ..varInt(_int(m, 'id'))
            ..f32(_num(m, 'yaw')),
        );
      case 'status':
        _send(
          'ENTITY_EVENT',
          (w) => w
            ..i32(_int(m, 'id'))
            ..u8(_int(m, 's')),
        );
      case 'collect':
        _send(
          'TAKE_ITEM_ENTITY',
          (w) => w
            ..varInt(_int(m, 'id'))
            ..varInt(_int(m, 'by'))
            ..varInt(_int(m, 'count', 1)),
        );
      case 'death':
        _send(
          'PLAYER_COMBAT_KILL',
          (w) => w
            ..varInt(_int(m, 'id', _playerId))
            ..text('${m['msg'] ?? 'You died'}'),
        );
      case 'notice':
        _send(
          'SYSTEM_CHAT',
          (w) => w
            ..text('${m['text'] ?? ''}')
            ..boolValue(false),
        );
      case 'kick':
        _positioned = false;
        _send('DISCONNECT', (w) => w..text('${m['reason'] ?? 'Disconnected'}'));
      case 'states': // Parent maps state IDs and owns chunk translation.
        break;
      default:
        _report('Unsupported gameplay message: ${m['t']}');
    }
  }

  int _playerId = 0;

  int _missingBiome(dynamic name) {
    _report('Unknown biome $name; using plains');
    return _id('biomes', 'minecraft:plains') ?? 0;
  }

  void _resetWorld(Map<String, dynamic> m) {
    _positioned = false;
    _input = 0;
    _teleports.clear();
    _entities.clear();
    _cacheX = _cacheZ = null;
    _x = _y = _z = _yaw = _pitch = 0;
    _onGround = _horizontalCollision = false;
    final dim = m['dimension'] ?? m['dim'] ?? 'overworld';
    _dimension = _resource(
      dim == 'nether'
          ? 'the_nether'
          : dim == 'end'
          ? 'the_end'
          : dim,
    );
    final defaultHeight = _dimension == 'minecraft:overworld' ? 384 : 256;
    final height = _int(m, 'height', defaultHeight);
    if (height <= 0 || height % 16 != 0) {
      throw FormatException('Invalid dimension height: $height');
    }
    _sectionCount = height ~/ 16;
  }

  void _commonSpawn(Writer w, Map<String, dynamic> m) {
    final type = m['dimensionType'] ?? _dimension;
    final id = _id('dimensions', type);
    if (id == null) throw FormatException('Unknown dimension type: $type');
    // CommonPlayerSpawnInfo: holder ID (no +1), resource key, seed, modes,
    // debug, flat, optional GlobalPos, portal cooldown, sea level.
    w
      ..varInt(id)
      ..string(_dimension)
      ..i64(_int(m, 'seed'))
      ..u8(_mode(m['mode']))
      ..u8(_int(m, 'previousMode', -1))
      ..boolValue(m['debug'] == true)
      ..boolValue(m['flat'] == true);
    final death = m['lastDeathLocation'];
    w.boolValue(death is Map);
    if (death is Map) {
      w
        ..string(_resource(death['dimension'] ?? _dimension))
        ..position(_int(death, 'x'), _int(death, 'y'), _int(death, 'z'));
    }
    w
      ..varInt(_int(m, 'portalCooldown'))
      ..varInt(_int(m, 'seaLevel', 63));
  }

  void _login(Map<String, dynamic> m) {
    _resetWorld(m);
    _playerId = _int(m, 'eid');
    final dimensions = <String>{_dimension};
    final entries = registries['dimensions'];
    if (entries is Map) dimensions.addAll(entries.keys.map(_resource));
    _send('LOGIN', (w) {
      w
        ..i32(_playerId)
        ..boolValue(m['hardcore'] == true)
        ..varInt(dimensions.length);
      for (final d in dimensions) {
        w.string(d);
      }
      w
        ..varInt(_int(m, 'maxPlayers', 20))
        ..varInt(renderDistance)
        ..varInt(renderDistance)
        ..boolValue(false)
        ..boolValue(true)
        ..boolValue(false);
      _commonSpawn(w, m);
      w
        ..boolValue(false)
        ..boolValue(false); // onlineMode, enforcesSecureChat
    });
    _loggedIn = true;
    _event(13, 0); // LEVEL_CHUNKS_LOAD_START
    upstream({'t': 'settings', 'rd': renderDistance});
  }

  void _respawn(Map<String, dynamic> m) {
    _resetWorld(m);
    _send('RESPAWN', (w) {
      _commonSpawn(w, m);
      w.u8(_int(m, 'keep', 3));
    });
    _event(13, 0);
  }

  void _position(Map<String, dynamic> m) {
    final rel = m['rel'] is Map ? m['rel'] as Map : const {};
    const keys = ['x', 'y', 'z', 'yaw', 'pitch'];
    var flags = 0;
    for (var i = 0; i < keys.length; i++) {
      if (rel[keys[i]] == true) flags |= 1 << i;
    }
    double absolute(String k, double previous) =>
        _num(m, k).toDouble() + (rel[k] == true ? previous : 0);
    _x = absolute('x', _x);
    _y = absolute('y', _y);
    _z = absolute('z', _z);
    _yaw = absolute('yaw', _yaw);
    _pitch = absolute('pitch', _pitch).clamp(-90.0, 90.0);
    final id = _int(m, 'id');
    _teleports.add(id);
    _send(
      'PLAYER_POSITION',
      (w) => w
        ..varInt(id)
        ..f64(_num(m, 'x'))
        ..f64(_num(m, 'y'))
        ..f64(_num(m, 'z'))
        ..f64(0)
        ..f64(0)
        ..f64(0)
        ..f32(_num(m, 'yaw'))
        ..f32(_num(m, 'pitch'))
        ..i32(flags),
    );
    _positioned = true;
    _cacheCenter();
  }

  void _cacheCenter() {
    final cx = _x.floor() >> 4, cz = _z.floor() >> 4;
    if (cx == _cacheX && cz == _cacheZ) return;
    _cacheX = cx;
    _cacheZ = cz;
    _send(
      'SET_CHUNK_CACHE_CENTER',
      (w) => w
        ..varInt(cx)
        ..varInt(cz),
    );
  }

  void _event(int event, num value) => _send(
    'GAME_EVENT',
    (w) => w
      ..u8(event)
      ..f32(value),
  );

  void _block(Map m) => _send(
    'BLOCK_UPDATE',
    (w) => w
      ..position(_int(m, 'x'), _int(m, 'y'), _int(m, 'z'))
      ..varInt(_int(m, 's')),
  );

  void _blocks(Map m) {
    final list = m['list'] as List? ?? [];
    if (list.length % 4 != 0) {
      throw const FormatException('Invalid blocks list');
    }
    // Each tuple is already a full state update. Individual packets avoid
    // assuming a single section for an arbitrarily grouped proxy update.
    for (var i = 0; i < list.length; i += 4) {
      _block({
        'x': list[i],
        'y': list[i + 1],
        'z': list[i + 2],
        's': list[i + 3],
      });
    }
  }

  void _time(Map m) {
    // 26.2 removed the legacy dayTime long + ticking boolean.
    // WorldClock uses a registry ID; never confuse it with a holder +1.
    final clock =
        _id('clocks', 'minecraft:overworld') ??
        _id('world_clock', 'minecraft:overworld');
    _send('SET_TIME', (w) {
      w.i64(_int(m, 'age', _int(m, 'day')));
      w.varInt(clock == null ? 0 : 1);
      if (clock != null) {
        final day = _num(m, 'day');
        w.varInt(clock);
        _varLong(w, day.floor());
        w
          ..f32(day - day.floor())
          ..f32(_num(m, 'rate', 1));
      }
    });
    if (clock == null) {
      _report(
        'Time of day needs registries[clocks][minecraft:overworld]; sent game time only',
      );
    }
  }

  static int _angle(num degrees) => (degrees * 256 / 360).floor() & 255;

  void _spawn(Map m) {
    final id = _int(m, 'id');
    final type = _id('entities', m['type'] ?? m['kind']);
    if (type == null) {
      _report('Unknown entity type: ${m['type'] ?? m['kind']}');
      return;
    }
    final entity = _Entity.fromMessage(m);
    if (m['type'] == 'player') {
      final uuid = m['uuid']?.toString() ?? _entityUuid(id);
      if (!_players.containsKey(uuid)) {
        final name = '${m['name'] ?? 'Player$id'}';
        _playerInfo({uuid: name});
        _players[uuid] = name;
      }
    }
    _send('ADD_ENTITY', (w) {
      w
        ..varInt(id)
        ..uuid(m['uuid']?.toString() ?? _entityUuid(id))
        ..varInt(type)
        ..f64(entity.x)
        ..f64(entity.y)
        ..f64(entity.z);
      _lpVec(w, m['v'] is List ? (m['v'] as List).cast<num>() : [0, 0, 0]);
      w
        ..u8(_angle(entity.pitch))
        ..u8(_angle(entity.yaw))
        ..u8(_angle(_num(m, 'head', entity.yaw)))
        ..varInt(_int(m, 'data'));
    });
    _entities[id] = entity;
  }

  void _playersMessage(Map m) {
    final next = <String, String>{
      for (final p in m['list'] as List? ?? [])
        p['uuid'].toString(): p['name'].toString(),
    };
    final removed = _players.keys.where((u) => !next.containsKey(u)).toList();
    if (removed.isNotEmpty) {
      _send('PLAYER_INFO_REMOVE', (w) {
        w.varInt(removed.length);
        for (final uuid in removed) {
          w.uuid(uuid);
        }
      });
    }
    if (next.isNotEmpty) _playerInfo(next);
    _players
      ..clear()
      ..addAll(next);
  }

  void _playerInfo(Map<String, String> players) {
    _send('PLAYER_INFO_UPDATE', (w) {
      // Eight action enum values => fixed one-byte bitset; ADD_PLAYER and
      // UPDATE_LISTED. Profile properties are absent from the proxy schema.
      w
        ..u8(0x09)
        ..varInt(players.length);
      for (final entry in players.entries) {
        w
          ..uuid(entry.key)
          ..string(entry.value)
          ..varInt(0)
          ..boolValue(true);
      }
    });
  }

  void _meta(Map m) {
    final values = m['m'];
    if (values is! Map) return;
    final w = Writer()..varInt(_int(m, 'id'));
    var count = 0;
    if (values.containsKey('shared_flags')) {
      w
        ..u8(0)
        ..varInt(0)
        ..u8(_int(values, 'shared_flags'));
      count++;
    }
    if (values.containsKey('custom_name')) {
      final name = values['custom_name'];
      w
        ..u8(2)
        ..varInt(6)
        ..boolValue(name != null && name != '');
      if (name != null && name != '') w.text(name.toString());
      count++;
    }
    const poses = [
      'standing',
      'fall_flying',
      'sleeping',
      'swimming',
      'spin_attack',
      'crouching',
      'long_jumping',
      'dying',
      'croaking',
      'using_tongue',
      'sitting',
      'roaring',
      'sniffing',
      'emerging',
      'digging',
      'sliding',
      'shooting',
      'inhaling',
    ];
    if (values.containsKey('pose')) {
      final pose = values['pose'];
      final id = pose is int ? pose : poses.indexOf(pose.toString());
      if (id >= 0 && id < poses.length) {
        w
          ..u8(6)
          ..varInt(20)
          ..varInt(id);
        count++;
      }
    }
    if (count > 0) {
      w.u8(255);
      emit('SET_ENTITY_DATA', w);
    }
  }

  static String _entityUuid(int id) =>
      '00000000-0000-4000-8000-${(id & 0xffffffff).toRadixString(16).padLeft(12, '0')}';

  void _move(Map m) {
    final id = _int(m, 'id');
    final previous = _entities[id];
    if (previous == null) return;
    final e = _Entity.fromMessage(m, previous);
    // Semantic movement is absolute. ENTITY_POSITION_SYNC preserves doubles
    // and avoids inventing a quantized relative-position baseline.
    _send(
      'ENTITY_POSITION_SYNC',
      (w) => w
        ..varInt(id)
        ..f64(e.x)
        ..f64(e.y)
        ..f64(e.z)
        ..f64(0)
        ..f64(0)
        ..f64(0)
        ..f32(e.yaw)
        ..f32(e.pitch)
        ..boolValue(m['onGround'] == true),
    );
    _entities[id] = e;
  }

  /// Parent calls this every 50 ms. Never fabricate initial position (0,0,0).
  void tick() {
    if (!_loggedIn || !_positioned) return;
    upstream({
      't': 'tick',
      'pos': [_x, _y, _z, _yaw, _pitch, _onGround, _horizontalCollision],
      'keys': {
        'f': _input & 1 != 0,
        'b': _input & 2 != 0,
        'l': _input & 4 != 0,
        'r': _input & 8 != 0,
        'j': _input & 16 != 0,
        's': _input & 32 != 0,
        'sp': _input & 64 != 0,
      },
    });
  }

  /// Reads only packets whose 26.2 layouts have been checked in vanilla source.
  /// InventoryBridge owns hashed-stack and component decoding.
  void onPacket(String type, Reader r) {
    if (_inventory.onPacket(type, r)) return;
    switch (type) {
      case 'ACCEPT_TELEPORTATION':
        final id = r.varInt();
        if (_teleports.remove(id)) upstream({'t': 'tpok', 'id': id});
      case 'MOVE_PLAYER_POS':
      case 'MOVE_PLAYER_POS_ROT':
      case 'MOVE_PLAYER_ROT':
      case 'MOVE_PLAYER_STATUS_ONLY':
        final hasPos =
            type == 'MOVE_PLAYER_POS' || type == 'MOVE_PLAYER_POS_ROT';
        final hasRot =
            type == 'MOVE_PLAYER_ROT' || type == 'MOVE_PLAYER_POS_ROT';
        final x = hasPos ? r.f64() : _x;
        final y = hasPos ? r.f64() : _y;
        final z = hasPos ? r.f64() : _z;
        final yaw = hasRot ? r.f32() : _yaw;
        final pitch = hasRot ? r.f32() : _pitch;
        final flags = r.u8();
        if (![x, y, z, yaw, pitch].every((n) => n.isFinite)) {
          throw const FormatException('Non-finite player position');
        }
        if (!_positioned || _teleports.isNotEmpty) return;
        _x = x;
        _y = y;
        _z = z;
        _yaw = yaw;
        _pitch = pitch;
        _onGround = flags & 1 != 0;
        _horizontalCollision = flags & 2 != 0;
        _cacheCenter();
      case 'PLAYER_INPUT':
        _input = r.u8() & 127;
      case 'PLAYER_ACTION':
        _action(r);
      case 'USE_ITEM_ON':
        final hand = r.varInt();
        final pos = r.position();
        final face = r.varInt();
        final cx = r.f32(), cy = r.f32(), cz = r.f32();
        final inside = r.boolValue(), border = r.boolValue();
        final sequence = r.varInt();
        upstream({
          't': 'place',
          ...pos,
          'face': face,
          'cx': cx,
          'cy': cy,
          'cz': cz,
          'hand': hand == 1 ? 'off' : 'main',
          'inside': inside,
          'worldBorder': border,
        });
        _ack(sequence);
      case 'USE_ITEM':
        final hand = r.varInt(), sequence = r.varInt();
        final yaw = r.f32(), pitch = r.f32();
        upstream({
          't': 'use',
          'hand': hand == 1 ? 'off' : 'main',
          'yaw': yaw,
          'pitch': pitch,
        });
        _ack(sequence);
      case 'ATTACK':
        upstream({'t': 'attack', 'id': r.varInt()});
      case 'INTERACT':
        final id = r.varInt(), hand = r.varInt();
        final v = _readLpVec(r);
        final sneak = r.boolValue();
        upstream({
          't': 'interact',
          'id': id,
          'hand': hand == 1 ? 'off' : 'main',
          'x': v[0],
          'y': v[1],
          'z': v[2],
          'sneak': sneak,
        });
      case 'SWING':
        upstream({'t': 'swing', 'hand': r.varInt() == 1 ? 'off' : 'main'});
      case 'CHAT':
        final text = r.string(256);
        r.i64();
        r.i64(); // timestamp and salt
        if (r.boolValue()) r.raw(256); // optional MessageSignature
        _lastSeen(r);
        upstream({'t': 'chat', 'text': text});
      case 'CHAT_COMMAND':
        upstream({'t': 'chat', 'text': '/${r.string()}'});
      case 'CHAT_COMMAND_SIGNED':
        final command = r.string();
        r.i64();
        r.i64();
        final count = r.varInt();
        if (count < 0 || count > 8) {
          throw const FormatException('Too many argument signatures');
        }
        for (var i = 0; i < count; i++) {
          r.string(16);
          r.raw(256);
        }
        _lastSeen(r);
        upstream({'t': 'chat', 'text': '/$command'});
      case 'CLIENT_COMMAND':
        if (r.varInt() == 0) upstream({'t': 'respawn'});
      case 'PLAYER_COMMAND':
        r.varInt();
        final action = r.varInt();
        r.varInt();
        if (action == 1) _input |= 64;
        if (action == 2) _input &= ~64;
      case 'PLAYER_ABILITIES':
        upstream({'t': 'abilities', 'flying': r.u8() & 2 != 0});
      case 'MOVE_VEHICLE':
        upstream({
          't': 'tick',
          'look': [_yaw, _pitch],
          'vmove': [r.f64(), r.f64(), r.f64(), r.f32(), r.f32(), r.boolValue()],
        });
      case 'PADDLE_BOAT':
        upstream({
          't': 'tick',
          'paddles': [r.boolValue(), r.boolValue()],
        });
      case 'CLIENT_TICK_END':
      case 'PLAYER_LOADED':
      case 'CHAT_ACK':
        break; // Parent schedules ticks; signatures terminate at this bridge.
      default:
        _report('Unsupported gameplay packet: $type');
    }
  }

  void _action(Reader r) {
    final action = r.varInt();
    final pos = r.position();
    final face = r.u8(), sequence = r.varInt();
    switch (action) {
      case 0:
      case 1:
      case 2:
        upstream({'t': 'dig', 'status': action, ...pos, 'face': face});
      case 3:
      case 4:
        upstream({'t': 'drop', 'all': action == 3});
      case 5:
        upstream({'t': 'release'});
      case 6:
        upstream({'t': 'swap'});
      case 7:
        _report('Unsupported player action: STAB');
      default:
        throw FormatException('Unknown player action: $action');
    }
    _ack(sequence);
  }

  void _ack(int sequence) {
    if (sequence >= 0) _send('BLOCK_CHANGED_ACK', (w) => w.varInt(sequence));
  }

  static void _lastSeen(Reader r) {
    r.varInt();
    r.raw(3);
    r.u8(); // 20-bit bitset, then 26.2 checksum
  }

  static void _varLong(Writer w, int value) {
    do {
      final b = value & 127;
      value = value >>> 7;
      w.u8(b | (value == 0 ? 0 : 128));
    } while (value != 0);
  }

  // Exact LpVec3 layout: two little-endian low bytes, big-endian high int,
  // optional scale continuation varint. Zero is represented by one byte.
  static void _lpVec(Writer w, List<num> vector) {
    if (vector.length != 3) throw const FormatException('Invalid vector');
    final v = vector
        .map(
          (n) =>
              n.isNaN ? 0.0 : n.toDouble().clamp(-17179869183.0, 17179869183.0),
        )
        .toList();
    final length = v.fold<double>(0, (a, b) => math.max(a, b.abs()));
    if (length < 3.051944088384301E-5) {
      w.u8(0);
      return;
    }
    final scale = length.ceil();
    final partial = scale > 3;
    int pack(double n) => ((n / scale * 0.5 + 0.5) * 32766).round();
    final bits =
        (scale & 3) |
        (partial ? 4 : 0) |
        (pack(v[0]) << 3) |
        (pack(v[1]) << 18) |
        (pack(v[2]) << 33);
    w
      ..u8(bits)
      ..u8(bits >> 8)
      ..i32((bits >> 16).toSigned(32));
    if (partial) w.varInt(scale >> 2);
  }

  static List<double> _readLpVec(Reader r) {
    final low = r.u8();
    if (low == 0) return [0, 0, 0];
    final middle = r.u8(), high = r.i32() & 0xffffffff;
    final bits = high << 16 | middle << 8 | low;
    var scale = low & 3;
    if (low & 4 != 0) scale |= (r.varInt() & 0xffffffff) << 2;
    double unpack(int shift) =>
        (math.min((bits >> shift) & 32767, 32766) * 2 / 32766 - 1) * scale;
    return [unpack(3), unpack(18), unpack(33)];
  }
}

class _Entity {
  const _Entity(this.x, this.y, this.z, this.yaw, this.pitch);
  factory _Entity.fromMessage(Map m, [_Entity? p]) => _Entity(
    GameBridge._num(m, 'x', p?.x ?? 0).toDouble(),
    GameBridge._num(m, 'y', p?.y ?? 0).toDouble(),
    GameBridge._num(m, 'z', p?.z ?? 0).toDouble(),
    GameBridge._num(m, 'yaw', p?.yaw ?? 0).toDouble(),
    GameBridge._num(m, 'pitch', p?.pitch ?? 0).toDouble(),
  );
  final double x, y, z, yaw, pitch;
}
