import 'wire.dart';

/// Inventory projection for Java 26.2 (776) and Dump/js/net.js.
///
/// Clientbound slots deliberately have an empty component patch. The original
/// upstream stack, including its opaque `x`, stays here for click predictions.
class InventoryBridge {
  final void Function(String, Writer) emit;
  final void Function(Map<String, dynamic>) upstream;
  final Map<String, dynamic> registries;
  final void Function(String) log;

  final _windows = <int, _Window>{0: _Window()};
  Map<String, dynamic>? _cursor;
  int? _open;

  InventoryBridge({
    required this.emit,
    required this.upstream,
    required this.registries,
    required this.log,
  });

  Map get _items => registries['items'] as Map;
  String _resource(String name) =>
      name.contains(':') ? name : 'minecraft:$name';
  int _itemId(Map<String, dynamic> stack) {
    final name = stack['n'] as String;
    final id = _items[_resource(name)] ?? _items[name];
    if (id is! int) throw FormatException('Unknown inventory item: $name');
    return id;
  }

  String _itemName(int id) {
    for (final entry in _items.entries) {
      if (entry.value == id) {
        final name = entry.key as String;
        return name.startsWith('minecraft:') ? name.substring(10) : name;
      }
    }
    throw FormatException('Unknown inventory item ID: $id');
  }

  Map<String, dynamic>? _stack(dynamic value) {
    if (value == null) return null;
    final stack = Map<String, dynamic>.from(value as Map);
    final count = stack['c'];
    if (count is! int || count < 0 || count > 99) {
      throw const FormatException('Invalid inventory count');
    }
    if (count == 0) return null;
    _itemId(stack);
    return stack;
  }

  void _writeStack(Writer w, Map<String, dynamic>? stack) {
    if (stack == null) {
      w.varInt(0);
    } else {
      w.varInt(stack['c'] as int);
      w.varInt(_itemId(stack));
      w.varInt(0); // DataComponentPatch: added count, removed count.
      w.varInt(0);
    }
  }

  _Window _window(int id) => _windows.putIfAbsent(id, _Window.new);

  // Vanilla player-window indices, including armour and offhand.
  int _playerSlot(int slot) => slot < 9
      ? slot + 36
      : slot < 36
      ? slot
      : slot < 40
      ? 44 - slot
      : 45;

  void _setSlot(int id, int slot, Map<String, dynamic>? stack) {
    final window = _window(id);
    window.slots[slot] = stack;
    if (id == 0) {
      final open = _windows[_open];
      if (open != null && open.playerStart != null) {
        final index = slot >= 9 && slot < 36
            ? open.playerStart! + slot - 9
            : slot >= 36 && slot < 45
            ? open.playerStart! + 27 + slot - 36
            : null;
        if (index != null) open.slots[index] = stack;
      }
    } else if (window.playerStart != null) {
      final index = slot - window.playerStart!;
      if (index >= 0 && index < 36) {
        _window(0).slots[index + 9] = stack;
      }
    }
  }

  void _content(int id) {
    final window = _window(id);
    final w = Writer()
      ..varInt(id)
      ..varInt(window.state)
      ..varInt(window.size);
    for (var i = 0; i < window.size; i++) {
      _writeStack(w, window.slots[i]);
    }
    _writeStack(w, _cursor);
    emit('CONTAINER_SET_CONTENT', w);
  }

  void _state(_Window window, Map<String, dynamic> message) {
    final state = message['stateId'] ?? message['state'];
    window.state = state is int ? state : (window.state + 1) & 32767;
  }

  bool onMessage(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'open':
        final id = m['id'] as int;
        final kind = m['kind'] as String;
        final menus = registries['menus'] as Map;
        final menu = menus[_resource(kind)] ?? menus[kind];
        if (menu is! int) {
          log('Inventory: unsupported menu $kind');
          return true;
        }
        _windows.removeWhere((id, _) => id != 0);
        _open = id;
        _windows[id] = _Window()..kind = kind.split(':').last;
        emit(
          'OPEN_SCREEN',
          Writer()
            ..varInt(id)
            ..varInt(menu)
            ..text((m['title'] ?? kind).toString()),
        );
        return true;
      case 'win':
        final id = m['id'] as int;
        final items = (m['items'] as List).map(_stack).toList();
        final carried = _stack(m['carried']);
        final window = _window(id);
        window.size = items.length;
        window.slots.clear();
        if (id != 0) {
          window.playerStart = window.kind == 'lectern'
              ? null
              : window.kind == 'crafter_3x3'
              ? 9
              : items.length >= 36
              ? items.length - 36
              : null;
        }
        for (var i = 0; i < items.length; i++) {
          _setSlot(id, i, items[i]);
        }
        _cursor = carried;
        _state(window, m);
        _content(id);
        return true;
      case 'wslot':
        final id = m['id'] as int;
        final slot = m['i'] as int;
        final stack = _stack(m['item']);
        _setSlot(id, slot, stack);
        final window = _window(id);
        _state(window, m);
        final w = Writer()
          ..varInt(id)
          ..varInt(window.state)
          ..i16(slot);
        _writeStack(w, stack);
        emit('CONTAINER_SET_SLOT', w);
        return true;
      case 'cursor':
        _cursor = _stack(m['item']);
        final w = Writer();
        _writeStack(w, _cursor);
        emit('SET_CURSOR_ITEM', w);
        return true;
      case 'pinv':
        final slot = m['i'] as int;
        final stack = _stack(m['item']);
        if (slot >= 0 && slot <= 40) _setSlot(0, _playerSlot(slot), stack);
        final w = Writer()..varInt(slot);
        _writeStack(w, stack);
        emit('SET_PLAYER_INVENTORY', w);
        return true;
      case 'prop':
        emit(
          'CONTAINER_SET_DATA',
          Writer()
            ..varInt(m['id'] as int)
            ..i16(m['k'] as int)
            ..i16(m['v'] as int),
        );
        return true;
      case 'held':
        emit('SET_HELD_SLOT', Writer()..varInt(m['slot'] as int));
        return true;
      case 'wclose':
        final id = m['id'] as int;
        emit('CONTAINER_CLOSE', Writer()..varInt(id));
        _close(id);
        return true;
      default:
        return false;
    }
  }

  void _close(int id) {
    if (id != 0) _windows.remove(id);
    if (_open == id) _open = null;
  }

  /// Parse only bounded 26.2 HashedStack fields; hashes are signed fixed INTs.
  _Hashed? _hashed(Reader r) {
    final present = r.u8();
    if (present == 0) return null;
    if (present != 1) throw const FormatException('Invalid hashed optional');
    final id = r.varInt();
    final count = r.varInt();
    if (id < 0 || count <= 0 || count > 99) {
      throw const FormatException('Invalid hashed stack');
    }
    final added = _length(r, 256);
    for (var i = 0; i < added; i++) {
      r.varInt();
      r.i32();
    }
    final removed = _length(r, 256);
    for (var i = 0; i < removed; i++) {
      r.varInt();
    }
    if (added != 0 || removed != 0) {
      throw const FormatException(
        'Click components differ from client projection',
      );
    }
    return _Hashed(id, count);
  }

  int _length(Reader r, int max) {
    final value = r.varInt();
    if (value < 0 || value > max) {
      throw const FormatException('Invalid inventory length');
    }
    return value;
  }

  void _end(Reader r) {
    if (r.remaining != 0) {
      throw const FormatException('Trailing inventory bytes');
    }
  }

  Map<String, dynamic>? _resolve(
    _Hashed? hashed,
    List<Map<String, dynamic>?> preferred,
  ) {
    if (hashed == null) return null;
    bool matches(Map<String, dynamic>? s) =>
        s != null && _itemId(s) == hashed.id;
    // The display patch is empty even for signed upstream items. Their source
    // slot/cursor supplies identity; counts are the client's predicted counts.
    for (final stack in preferred) {
      if (matches(stack)) return {...stack!, 'c': hashed.count};
    }
    final candidates = <Map<String, dynamic>>[
      if (matches(_cursor)) _cursor!,
      for (final window in _windows.values)
        for (final stack in window.slots.values)
          if (matches(stack)) stack!,
    ];
    if (candidates.isEmpty) {
      throw const FormatException(
        'Click item is not in authoritative inventory',
      );
    }
    final signature = candidates.first['x'];
    if (candidates.any((s) => s['x'] != signature)) {
      throw const FormatException('Ambiguous upstream click signature');
    }
    return {...candidates.first, 'c': hashed.count};
  }

  // Creative uses ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC: each *added*
  // component has a VarInt byte length. Never infer lengths from component IDs.
  Map<String, dynamic>? _creative(Reader r) {
    final count = r.varInt();
    if (count == 0) return null;
    if (count < 0 || count > 99) {
      throw const FormatException('Invalid creative count');
    }
    final item = <String, dynamic>{'n': _itemName(r.varInt()), 'c': count};
    final added = _length(r, 256);
    final removed = _length(r, 256);
    var unsupported = removed != 0;
    final seen = <int>{};
    for (var i = 0; i < added; i++) {
      final type = r.varInt();
      final value = Reader(r.raw(_length(r, r.remaining)));
      // DataComponents.java registers DAMAGE as ID 3, VAR_INT, in 26.2.
      if (type == 3 && seen.add(type)) {
        final damage = value.varInt();
        if (damage < 0) throw const FormatException('Negative creative damage');
        _end(value);
        item['d'] = damage;
      } else {
        unsupported = true;
      }
    }
    for (var i = 0; i < removed; i++) {
      r.varInt();
    }
    if (unsupported) {
      throw const FormatException('Unsupported creative components');
    }
    return item;
  }

  bool onPacket(String type, Reader r) {
    const handled = {
      'CONTAINER_CLICK',
      'CONTAINER_CLOSE',
      'CONTAINER_BUTTON_CLICK',
      'SET_CARRIED_ITEM',
      'SET_CREATIVE_MODE_SLOT',
    };
    if (!handled.contains(type)) return false;
    int? clickWindow;
    try {
      switch (type) {
        case 'SET_CARRIED_ITEM':
          final slot = r.i16();
          _end(r);
          if (slot < 0 || slot > 8) {
            throw const FormatException('Invalid held slot');
          }
          upstream({'t': 'held', 'slot': slot});
        case 'CONTAINER_CLOSE':
          final id = r.varInt();
          _end(r);
          upstream({'t': 'wclose', 'id': id});
          _close(id);
        case 'CONTAINER_BUTTON_CLICK':
          final id = r.varInt();
          final button = r.varInt();
          _end(r);
          upstream({'t': 'button', 'id': id, 'b': button});
        case 'SET_CREATIVE_MODE_SLOT':
          final slot = r.i16();
          final item = _creative(r);
          _end(r);
          if (slot != -1 && (slot < 1 || slot > 45)) {
            throw const FormatException('Invalid creative slot');
          }
          upstream({'t': 'creative', 'slot': slot, 'item': item});
        case 'CONTAINER_CLICK':
          final id = r.varInt();
          clickWindow = id;
          final state = r.varInt();
          final slot = r.i16();
          final button = r.u8().toSigned(8);
          final mode = r.varInt();
          final count = _length(r, 128);
          final changed = <int, _Hashed?>{};
          for (var i = 0; i < count; i++) {
            final index = r.i16();
            if (index < 0 || changed.containsKey(index)) {
              throw const FormatException('Invalid changed slot');
            }
            changed[index] = _hashed(r);
          }
          final carried = _hashed(r);
          _end(r);
          final window = _windows[id];
          if (window == null ||
              (id != 0 && id != _open) ||
              mode < 0 ||
              mode > 6 ||
              (slot < 0 && slot != -999) ||
              (slot >= window.size) ||
              changed.keys.any((i) => i >= window.size)) {
            throw const FormatException('Invalid container click');
          }
          if (state != window.state) {
            throw const FormatException('Stale container click');
          }
          final predictions = <List<dynamic>>[];
          final swapSlot = button == 40
              ? 45
              : button >= 0 && button < 9
              ? 36 + button
              : null;
          for (final entry in changed.entries) {
            final target = window.slots[entry.key];
            final source = window.slots[slot];
            final preferred = mode == 2 && swapSlot != null
                ? [
                    entry.key == slot ? _window(0).slots[swapSlot] : source,
                    target,
                  ]
                : mode == 0 || mode == 5
                ? [_cursor, target, source]
                : [target, source];
            predictions.add([entry.key, _resolve(entry.value, preferred)]);
          }
          final cursor = _resolve(carried, [_cursor, window.slots[slot]]);
          upstream({
            't': 'click',
            'id': id,
            'slot': slot,
            'button': button,
            'mode': mode,
            'changed': predictions,
            'carried': cursor,
          });
      }
    } on FormatException catch (error) {
      // r is one framed packet, so discarding it cannot desync the connection.
      r.raw(r.remaining);
      log('Inventory $type rejected: ${error.message}');
      if (clickWindow != null && _windows.containsKey(clickWindow)) {
        _content(clickWindow);
      }
    }
    return true;
  }
}

class _Window {
  final slots = <int, Map<String, dynamic>?>{};
  int state = 0;
  int size = 46;
  String? kind;
  int? playerStart;
}

class _Hashed {
  final int id;
  final int count;
  _Hashed(this.id, this.count);
}
