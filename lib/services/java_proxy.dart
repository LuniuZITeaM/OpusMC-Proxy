import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../protocol/wire.dart';
import '../protocol/ids.dart';
import '../protocol/chunks.dart';
import '../protocol/game_bridge.dart';
import '../protocol/state_registry.dart';
import 'opus_api.dart';

class JavaProxy {
  final OpusApi api;
  final void Function(String) log;
  ServerSocket? _server;
  final Set<_Session> _sessions = {};
  Map<String, dynamic> _registries = {};
  String _room = '';
  int _rd = 6;
  bool _starting = false;
  bool get running => _server != null;
  int get port => _server?.port ?? 0;
  JavaProxy({required this.api, required this.log});

  Future<void> start({
    required String host,
    required int port,
    required String room,
    required int renderDistance,
  }) async {
    if (running || _starting) throw StateError('代理已经启动');
    if (api.token.isEmpty) throw StateError('请先使用识别码登录');
    if (!RegExp(r'^[A-Z0-9]{4,8}$').hasMatch(room)) {
      throw const FormatException('请输入 4–8 位房间邀请码');
    }
    if (port < 0 || port > 65535) throw const FormatException('端口无效');
    _starting = true;
    try {
      _registries = jsonDecode(
        await rootBundle.loadString('assets/registries.json'),
      ) as Map<String, dynamic>;
      if (_registries['protocol'] != 776 ||
          (_registries['packets'] as List).isEmpty) {
        throw StateError('缺少有效的 26.2 注册表数据');
      }
      _room = room;
      _rd = renderDistance.clamp(2, 16);
      _server = await ServerSocket.bind(host, port);
      _server!.listen(
        (socket) {
          if (_sessions.length >= 16) {
            socket.destroy();
            return;
          }
          final s = _Session(this, socket);
          _sessions.add(s);
          s.listen();
        },
        onError: (Object e) {
          log('监听错误：$e');
          unawaited(stop());
        },
      );
      log('已监听 $host:${_server!.port} → 房间 $_room（Java 26.2 / 776）');
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close();
    await Future.wait(_sessions.toList().map((e) => e.close('本地代理已停止')));
    _sessions.clear();
  }
}

enum _Phase { handshake, status, login, loginAck, configuration, play }

class _Session {
  final JavaProxy owner;
  final Socket socket;
  final PacketFramer framer = PacketFramer();
  _Phase phase = _Phase.handshake;
  WebSocket? ws;
  StreamSubscription<dynamic>? wsSub;
  Timer? timer;
  Timer? deadline;
  bool closed = false;
  Future<void> pending = Future.value();
  String name = '';
  late GameBridge game;
  int pendingBytes = 0;
  bool statesVerified = false;
  int? keepAlive;
  DateTime keepSent = DateTime.now();
  _Session(this.owner, this.socket);
  void listen() {
    socket.setOption(SocketOption.tcpNoDelay, true);
    deadline = Timer(
      const Duration(seconds: 30),
      () => unawaited(close('握手超时')),
    );
    socket.listen(
      (bytes) {
        try {
          for (final packet in framer.add(bytes)) {
            pendingBytes += packet.length;
            if (pendingBytes > PacketFramer.maxLength) {
              throw const FormatException('待处理数据过多');
            }
            pending = pending
                .then((_) async {
                  try {
                    if (!closed) await onPacket(Reader(packet));
                  } finally {
                    pendingBytes -= packet.length;
                  }
                })
                .catchError((Object e) {
                  owner.log('客户端协议错误：$e');
                  unawaited(close('协议错误：$e'));
                });
          }
        } catch (e) {
          unawaited(close('无效数据包'));
        }
      },
      onDone: () => unawaited(close()),
      onError: (Object e) => unawaited(close('客户端连接中断')),
      cancelOnError: true,
    );
  }

  void send(int id, [Writer? payload]) {
    if (!closed) socket.add(framePacket(id, payload?.take() ?? []));
  }

  void emit(String type, Writer w) {
    final id = clientbound[type];
    if (id == null) throw StateError('未知 26.2 数据包 $type');
    send(id, w);
  }

  void up(Map<String, dynamic> m) {
    if (!closed && ws?.readyState == WebSocket.open) ws!.add(jsonEncode(m));
  }

  Future<void> onPacket(Reader r) async {
    final id = r.varInt();
    switch (phase) {
      case _Phase.handshake:
        if (id != 0) throw const FormatException('Expected handshake');
        final protocol = r.varInt();
        r.string(255);
        r.i16();
        final next = r.varInt();
        if (next == 1) {
          phase = _Phase.status;
          return;
        }
        phase = _Phase.login;
        if (next != 2 || protocol != 776) {
          await close('请使用 Minecraft Java 26.2（协议 776）；跨版本请自行配置 ViaVersion。');
        }
        return;
      case _Phase.status:
        if (id == 0) {
          final playing = owner._sessions
              .where((s) => s.phase == _Phase.play)
              .length;
          send(
            0,
            Writer()..string(
              jsonEncode({
                'version': {'name': '26.2', 'protocol': 776},
                'players': {'max': 1, 'online': playing},
                'description': {
                  'text':
                      'OpusMCAgent · 房间 ${owner._room}\nMinecraft Java 26.2',
                },
                'enforcesSecureChat': false,
              }),
            ),
          );
        } else if (id == 1) {
          send(1, Writer()..i64(r.i64()));
          await socket.flush();
          await close();
        }
        return;
      case _Phase.login:
        if (id != 0) throw const FormatException('Expected login start');
        name = r.string(16);
        r.raw(16);
        if (!RegExp(r'^[A-Za-z0-9_]{1,16}$').hasMatch(name)) {
          throw const FormatException('玩家名无效');
        }
        if (owner._sessions.any(
          (s) => s != this && s.phase.index >= _Phase.loginAck.index,
        )) {
          await close('当前账号已有一个 Java 玩家连接；请断开后重试。');
          return;
        }
        phase = _Phase.loginAck;
        final uuid = md5
            .convert(utf8.encode('OfflinePlayer:$name'))
            .bytes
            .toList();
        uuid[6] = (uuid[6] & 15) | 48;
        uuid[8] = (uuid[8] & 63) | 128;
        final session = List<int>.generate(
          16,
          (_) => Random.secure().nextInt(256),
        );
        send(
          2,
          Writer()
            ..raw(uuid)
            ..string(name)
            ..varInt(0)
            ..raw(session),
        );
        return;
      case _Phase.loginAck:
        if (id != 3) {
          throw const FormatException('Expected login acknowledgement');
        }
        phase = _Phase.configuration;
        // Full NBT registry entries are sent, so the client need not supply known packs.
        send(
          configClientbound['UPDATE_ENABLED_FEATURES']!,
          Writer()
            ..varInt(1)
            ..string('minecraft:vanilla'),
        );
        for (final data in owner._registries['packets'] as List) {
          send(
            configClientbound['REGISTRY_DATA']!,
            Writer()..raw(base64Decode(data as String)),
          );
        }
        send(
          configClientbound['UPDATE_TAGS']!,
          Writer()..raw(base64Decode(owner._registries['tags'] as String)),
        );
        send(configClientbound['FINISH_CONFIGURATION']!);
        return;
      case _Phase.configuration:
        if (id != configServerbound['FINISH_CONFIGURATION']) return;
        phase = _Phase.play;
        deadline?.cancel();
        deadline = Timer(
          const Duration(seconds: 90),
          () => unawaited(close('房间连接超时')),
        );
        game = GameBridge(
          emit: emit,
          upstream: up,
          registries: owner._registries,
          renderDistance: owner._rd,
          log: owner.log,
        );
        final base = owner.api.base;
        final uri = base.replace(
          scheme: base.scheme == 'https' ? 'wss' : 'ws',
          path: '/ws',
          query: null,
          fragment: null,
        );
        owner.log('$name 正在连接房间 ${owner._room}');
        final connection = await WebSocket.connect(uri.toString())
            .timeout(const Duration(seconds: 20));
        if (closed) {
          await connection.close();
          return;
        }
        ws = connection;
        wsSub = connection.listen(
          onUpstream,
          onDone: () => unawaited(close('OpusMC 连接已关闭')),
          onError: (Object e) => unawaited(close('OpusMC 连接错误')),
          cancelOnError: true,
        );
        up({
          't': 'hello',
          'name': name,
          'version': 1,
          'proto': 1,
          'room': owner._room,
          'key': owner.api.roomKey,
          'token': owner.api.token,
          'rd': owner._rd,
        });
        timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
          if (closed) return;
          game.tick();
          final now = DateTime.now();
          if (now.difference(keepSent).inSeconds >= 15) {
            if (keepAlive != null) {
              unawaited(close('客户端心跳超时'));
              return;
            }
            keepAlive = now.millisecondsSinceEpoch;
            keepSent = now;
            emit('KEEP_ALIVE', Writer()..i64(keepAlive!));
          }
        });
        return;
      case _Phase.play:
        final type = serverbound.entries
            .where((e) => e.value == id)
            .firstOrNull
            ?.key;
        if (type == 'KEEP_ALIVE') {
          if (r.i64() != keepAlive) {
            throw const FormatException('Keepalive mismatch');
          }
          keepAlive = null;
          return;
        }
        if (type != null) game.onPacket(type, r);
        return;
    }
  }

  void onUpstream(dynamic data) {
    if (closed) return;
    try {
      if (data is String) {
        final m = jsonDecode(data) as Map<String, dynamic>;
        if (m['t'] == 'states') {
          verifyStateRegistry(
            m['list'] as List,
            owner._registries['states'] as List,
          );
          statesVerified = true;
        }
        if (m['t'] == 'error' || m['t'] == 'kick') {
          unawaited(
            close(
              '${m['text'] ?? m['message'] ?? m['reason'] ?? m['msg'] ?? '上游拒绝连接'}',
            ),
          );
          return;
        }
        if (m['t'] == 'notice' || m['t'] == 'queue' || m['t'] == 'room') {
          owner.log('${m['t']}: ${m['text'] ?? m['name'] ?? m['pos'] ?? ''}');
        }
        if (m['t'] == 'login') {
          deadline?.cancel();
          owner.log('$name 已进入房间');
        }
        game.onMessage(m);
      } else if (data is List<int>) {
        if (!statesVerified) throw const FormatException('上游尚未提供方块注册表');
        final chunk = BridgeChunk.decode(data);
        if (chunk.type == 1) {
          emit('CHUNK_BATCH_START', Writer());
          emit(
            'LEVEL_CHUNK_WITH_LIGHT',
            Writer()..raw(
              chunk.chunkPacket(
                sectionCount: game.sectionCount,
                biomeIds: game.biomeIds,
              ),
            ),
          );
          emit('CHUNK_BATCH_FINISHED', Writer()..varInt(1));
        } else {
          emit(
            'LIGHT_UPDATE',
            Writer()..raw(chunk.lightPacket(sectionCount: game.sectionCount)),
          );
        }
      }
    } catch (e) {
      owner.log('上游数据无法转换：$e');
      unawaited(close('房间协议无法转换：$e'));
    }
  }

  Future<void> close([String? reason]) async {
    if (closed) return;
    if (reason != null) {
      owner.log(reason);
      if (phase == _Phase.login || phase == _Phase.loginAck) {
        send(0, Writer()..string(jsonEncode({'text': reason})));
      }
      if (phase == _Phase.configuration) {
        send(configClientbound['DISCONNECT']!, Writer()..text(reason));
      }
      if (phase == _Phase.play) emit('DISCONNECT', Writer()..text(reason));
    }
    closed = true;
    timer?.cancel();
    deadline?.cancel();
    owner._sessions.remove(this);
    await wsSub?.cancel();
    try {
      await ws?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await socket.flush().timeout(const Duration(seconds: 1));
    } catch (_) {}
    socket.destroy();
  }
}
