import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_agent/protocol/ids.dart';
import 'package:opus_mc_agent/protocol/wire.dart';
import 'package:opus_mc_agent/services/java_proxy.dart';
import 'package:opus_mc_agent/services/opus_api.dart';

class Peer {
  final Socket socket;
  late final StreamIterator<Uint8List> packets;
  Peer(this.socket) {
    final f = PacketFramer();
    packets = StreamIterator(socket.expand(f.add));
  }
  void send(int id, Writer w) => socket.add(framePacket(id, w.take()));
  Future<Reader> next() async {
    if (!await packets.moveNext().timeout(const Duration(seconds: 8))) {
      throw StateError('Peer closed');
    }
    return Reader(packets.current);
  }

  Future<void> close() async {
    socket.destroy();
    await packets.cancel();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('server list ping works without opening an upstream session', () async {
    final api = OpusApi('http://127.0.0.1:9')..token = 'fixture';
    final proxy = JavaProxy(api: api, log: (_) {});
    await proxy.start(
      host: '127.0.0.1',
      port: 0,
      room: 'TEST',
      renderDistance: 4,
    );
    final peer = Peer(await Socket.connect('127.0.0.1', proxy.port));
    try {
      peer.send(
        0,
        Writer()
          ..varInt(776)
          ..string('localhost')
          ..i16(proxy.port)
          ..varInt(1),
      );
      peer.send(0, Writer());
      final status = await peer.next();
      expect(status.varInt(), 0);
      final data = jsonDecode(status.string()) as Map;
      expect(data['version']['protocol'], 776);
      expect(data['description']['text'], contains('TEST'));
      peer.send(1, Writer()..i64(123456));
      final pong = await peer.next();
      expect(pong.varInt(), 1);
      expect(pong.i64(), 123456);
    } finally {
      await peer.close();
      await proxy.stop();
      api.dispose();
    }
  });
  test(
    'login/configuration and bidirectional room chat use real packet framing',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = StreamController<Map<String, dynamic>>.broadcast();
      final websocket = Completer<WebSocket>();
      final requests = server.listen((request) async {
        if (request.uri.path != '/fixture/ws') {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        if (request.headers.value('origin') != 'https://www.bilibilitoy.com' ||
            request.headers.value('referer') !=
                'https://www.bilibilitoy.com/') {
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        final ws = await WebSocketTransformer.upgrade(request);
        websocket.complete(ws);
        ws.listen((event) {
          received.add(jsonDecode(event as String) as Map<String, dynamic>);
        });
      });
      final api = OpusApi('http://127.0.0.1:${server.port}/fixture')
        ..token = 'fixture-token'
        ..account = {'name': '测试账号', 'roomKey': 'fixture-room-key'};
      final logs = <String>[];
      final proxy = JavaProxy(api: api, log: logs.add);
      await proxy.start(
        host: '127.0.0.1',
        port: 0,
        room: 'TEST',
        renderDistance: 4,
      );
      final peer = Peer(await Socket.connect('127.0.0.1', proxy.port));
      try {
        peer.send(
          0,
          Writer()
            ..varInt(776)
            ..string('localhost')
            ..i16(proxy.port)
            ..varInt(2),
        );
        peer.send(
          0,
          Writer()
            ..string('Fixture')
            ..raw(List.filled(16, 0)),
        );
        final success = await peer.next();
        expect(success.varInt(), 2);
        success.raw(16);
        expect(success.string(), 'Fixture');
        expect(success.varInt(), 0);
        success.raw(16);
        expect(success.remaining, 0);
        peer.send(3, Writer());
        var count = 0;
        while (true) {
          final packet = await peer.next();
          final id = packet.varInt();
          if (id == configClientbound['REGISTRY_DATA']) {
            count++;
            expect(packet.string(), startsWith('minecraft:'));
          }
          if (id == configClientbound['FINISH_CONFIGURATION']) break;
        }
        expect(count, greaterThan(10));
        final hello = received.stream.firstWhere((m) => m['t'] == 'hello');
        peer.send(configServerbound['FINISH_CONFIGURATION']!, Writer());
        final h = await hello.timeout(const Duration(seconds: 8));
        expect(h['token'], 'fixture-token');
        expect(h['room'], 'TEST');
        expect(h['rd'], 4);
        expect(h['name'], '测试账号');
        expect(h['key'], 'fixture-room-key');
        final ws = await websocket.future;
        ws.add(jsonEncode({'t': 'queue', 'pos': 3, 'of': 11}));
        ws.add(jsonEncode({'t': 'notice', 'text': '正在启动房间'}));
        // Different length AND ID order must not prevent entering the room.
        ws.add(
          jsonEncode({
            't': 'states',
            'list': ['stone', 'air'],
          }),
        );
        ws.add(
          jsonEncode({
            't': 'biomes',
            'list': ['minecraft:plains'],
          }),
        );
        ws.add(
          jsonEncode({
            't': 'login',
            'eid': 42,
            'dim': 'overworld',
            'minY': -64,
            'height': 384,
            'mode': 'creative',
          }),
        );
        ws.add(
          jsonEncode({
            't': 'pos',
            'id': 7,
            'x': 8.0,
            'y': 70.0,
            'z': 8.0,
            'yaw': 0.0,
            'pitch': 0.0,
          }),
        );
        var found = false;
        for (var i = 0; i < 15; i++) {
          final packet = await peer.next();
          if (packet.varInt() == clientbound['LOGIN']) {
            found = true;
            expect(packet.i32(), 42);
            break;
          }
        }
        expect(found, isTrue);
        expect(logs, contains(contains('第 3 位 / 共 11 个房间')));
        expect(logs, contains('notice: 正在启动房间'));
        expect(
          logs.any(
            (line) => line.contains('Unsupported gameplay message: queue'),
          ),
          isFalse,
        );
        // An actual binary bridge chunk crosses the WebSocket-to-Java boundary.
        final chunk = BytesBuilder()..add([1, 0, 0, 0, 0, 0, 0, 0, 0, 24]);
        for (var i = 0; i < 24; i++) {
          chunk.add([1, 0, 0, 0, 0]);
        }
        chunk.add(List.filled(256, 0));
        // Official clients ignore opaque data beyond the known chunk prefix.
        chunk.add([0xde, 0xad, 0xbe, 0xef]);
        ws.add(chunk.takeBytes());
        var gotChunk = false;
        for (var i = 0; i < 15; i++) {
          final packet = await peer.next();
          if (packet.varInt() == clientbound['LEVEL_CHUNK_WITH_LIGHT']) {
            expect(packet.i32(), 0);
            expect(packet.i32(), 0);
            expect(packet.varInt(), 1); // Heightmaps.
            expect(packet.varInt(), 1); // WORLD_SURFACE.
            packet.raw(packet.varInt() * 8);
            final sections = Reader(packet.raw(packet.varInt()));
            expect(sections.i16(), 4096); // ID 0 is upstream stone, not air.
            expect(sections.i16(), 0);
            expect(sections.u8(), 0); // Single-valued block palette.
            expect(sections.varInt(), 1); // Java stone.
            gotChunk = true;
            break;
          }
        }
        expect(gotChunk, isTrue);
        expect(logs, contains(contains('4 字节尾部附加数据')));
        final lightUpdate = BytesBuilder()..add([2, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
        lightUpdate.add([1, 0, 0, 0, 1]); // One palette entry + sky light.
        lightUpdate.add(List.filled(2048, 0xff));
        lightUpdate.add([0x12, 0x34]);
        ws.add(lightUpdate.takeBytes());
        var gotLight = false;
        for (var i = 0; i < 15; i++) {
          final packet = await peer.next();
          if (packet.varInt() == clientbound['LIGHT_UPDATE']) {
            expect(packet.varInt(), 0);
            expect(packet.varInt(), 0);
            gotLight = true;
            break;
          }
        }
        expect(gotLight, isTrue);
        expect(logs, contains(contains('2 字节尾部附加数据')));
        ws.add(jsonEncode({'t': 'block', 'x': 0, 'y': 70, 'z': 0, 's': 0}));
        var gotBlock = false;
        for (var i = 0; i < 15; i++) {
          final packet = await peer.next();
          if (packet.varInt() == clientbound['BLOCK_UPDATE']) {
            packet.position();
            expect(packet.varInt(), 1);
            gotBlock = true;
            break;
          }
        }
        expect(gotBlock, isTrue);
        final chat = received.stream.firstWhere((m) => m['t'] == 'chat');
        peer.send(
          serverbound['CHAT_COMMAND']!,
          Writer()..string('say fixture'),
        );
        expect(
          (await chat.timeout(const Duration(seconds: 8)))['text'],
          '/say fixture',
        );
      } finally {
        await peer.close();
        await proxy.stop();
        api.dispose();
        if (websocket.isCompleted) await (await websocket.future).close();
        await requests.cancel();
        await server.close(force: true);
        await received.close();
      }
    },
  );
}
