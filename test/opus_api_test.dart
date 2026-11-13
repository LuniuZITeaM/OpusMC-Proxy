import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_agent/services/opus_api.dart';

void main() {
  test('hosted room name follows account name with guest fallback', () {
    final api = OpusApi('http://127.0.0.1:9');
    try {
      expect(api.playerName('JavaPlayer'), 'JavaPlayer');
      api.account = {'name': '网页玩家'};
      expect(api.playerName('JavaPlayer'), '网页玩家');
      api.account = {'name': ''};
      expect(api.playerName('JavaPlayer'), 'JavaPlayer');
    } finally {
      api.dispose();
    }
  });
  test(
    'identity login, public/own rooms and logout match account.js contracts',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Map<String, dynamic>>[];
      final subscription = server.listen((r) async {
        final text = await utf8.decoder.bind(r).join();
        final body = text.isEmpty ? null : jsonDecode(text);
        requests.add({
          'path': r.uri.path,
          'method': r.method,
          'body': body,
          'key': r.uri.queryParameters['key'],
          'origin': r.headers.value('origin'),
          'referer': r.headers.value('referer'),
        });
        // Production rejects missing game origins before checking credentials.
        if (r.headers.value('origin') != 'https://www.bilibilitoy.com' ||
            r.headers.value('referer') != 'https://www.bilibilitoy.com/') {
          r.response.statusCode = 403;
          r.response.write(jsonEncode({'error': '请在 B站 Toy 页面打开游戏'}));
          await r.response.close();
          return;
        }
        final response = switch (r.uri.path) {
          '/api/account/code' => {
            'token': 'fixture-secret',
            'account': {'name': 'Fixture', 'roomKey': 'fixture-key'},
          },
          '/api/public' => {
            'rooms': [
              {'code': 'TEST', 'name': 'Public'},
            ],
          },
          '/api/rooms' => [
            {'code': 'MINE', 'name': 'Owned'},
          ],
          _ => {'ok': true},
        };
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(response));
        await r.response.close();
      });
      final api = OpusApi('http://127.0.0.1:${server.port}');
      try {
        await api.login('ABCD-EFGH-IJKL-MNOP');
        expect(api.token, 'fixture-secret');
        expect(api.roomKey, 'fixture-key');
        expect((await api.publicRooms()).single['code'], 'TEST');
        expect((await api.ownRooms()).single['code'], 'MINE');
        await api.logout();
        expect(api.token, isEmpty);
        expect(api.account, isNull);
        expect(requests[0]['method'], 'POST');
        expect(requests[0]['body']['code'], 'ABCD-EFGH-IJKL-MNOP');
        expect(requests[1]['method'], 'GET');
        expect(requests[1]['body'], isNull);
        expect(requests[2]['key'], 'fixture-key');
        expect(requests[3]['body']['_t'], 'fixture-secret');
        for (final request in requests) {
          expect(request['origin'], 'https://www.bilibilitoy.com');
          expect(request['referer'], 'https://www.bilibilitoy.com/');
        }
      } finally {
        api.dispose();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
  test('public room responses larger than 2 MB remain readable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rooms = List.generate(
      22000,
      (i) => {
        'code': 'ROOM$i',
        'name': 'Room ${'x' * 120}',
        'owner': 'Fixture',
        'players': 0,
        'max': 4,
        'state': 'running',
      },
    );
    final body = jsonEncode({'rooms': rooms});
    expect(utf8.encode(body).length, greaterThan(2 * 1024 * 1024));
    final subscription = server.listen((r) async {
      r.response.headers.contentType = ContentType.json;
      r.response.write(body);
      await r.response.close();
    });
    final api = OpusApi('http://127.0.0.1:${server.port}');
    try {
      final result = await api.publicRooms();
      expect(result.length, rooms.length);
      expect(result.last['code'], 'ROOM21999');
    } finally {
      api.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
  test('401 invalidates a session and exposes the actionable error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((r) async {
      r.response.statusCode = 401;
      r.response.write('{"error":"expired"}');
      await r.response.close();
    });
    final api = OpusApi('http://127.0.0.1:${server.port}')
      ..token = 'expired'
      ..account = {'name': 'Fixture'};
    try {
      await expectLater(
        api.publicRooms(),
        throwsA(isA<OpusApiException>().having((e) => e.status, 'status', 401)),
      );
      expect(api.token, isEmpty);
      expect(api.account, isNull);
    } finally {
      api.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
