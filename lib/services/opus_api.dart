import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Credentials are retained in memory only, for the lifetime of this client.
class OpusApi {
  OpusApi(String baseUrl) : base = _parseBase(baseUrl);

  /// Match the cross-origin requests made by the official embedded game.
  /// The service validates Origin before handling even public/account APIs.
  static const upstreamHeaders = <String, String>{
    'Origin': 'https://www.bilibilitoy.com',
    'Referer': 'https://www.bilibilitoy.com/',
  };
  // The public room list already exceeds 5 MB; keep a bounded allowance.
  static const maxResponseBytes = 16 * 1024 * 1024;

  final Uri base;
  String token = '';
  Map<String, dynamic>? account;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  final String _guestKey = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  bool _disposed = false;

  String get roomKey {
    final key = account?['roomKey'];
    return key is String && key.isNotEmpty ? key : _guestKey;
  }

  static Uri _parseBase(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入有效的 HTTP / HTTPS 上游服务地址');
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  Future<void> login(String code) async {
    if (code.trim().isEmpty) throw const FormatException('请输入身份识别码');
    final result = await _request(
      '/api/account/code',
      body: {
        'code': code.trim(),
        'device': '${Platform.operatingSystem} · OpusMC Agent',
      },
    );
    if (result is! Map ||
        result['token'] is! String ||
        (result['token'] as String).isEmpty ||
        result['account'] is! Map) {
      throw const FormatException('登录响应缺少令牌或账户信息');
    }
    token = result['token'] as String;
    account = Map<String, dynamic>.from(result['account'] as Map);
  }

  Future<List<Map<String, dynamic>>> publicRooms() async {
    final result = await _request('/api/public');
    return _rooms(result is Map ? result['rooms'] : result);
  }

  Future<List<Map<String, dynamic>>> ownRooms() async {
    if (token.isEmpty || account == null) {
      throw const OpusApiException('请先登录，再查看自己的房间', status: 401);
    }
    final result = await _request('/api/rooms', query: {'key': roomKey});
    return _rooms(result is Map ? result['rooms'] : result);
  }

  static List<Map<String, dynamic>> _rooms(dynamic value) {
    if (value is! List || value.any((room) => room is! Map)) {
      throw const FormatException('房间列表响应格式不正确');
    }
    return value.map((room) => Map<String, dynamic>.from(room as Map)).toList();
  }

  Future<void> logout() async {
    final previousToken = token;
    token = '';
    account = null;
    if (previousToken.isEmpty) return;
    try {
      await _request('/api/account/logout', body: {'_t': previousToken});
    } on Exception {
      // Local logout also works offline, matching account.js.
    }
  }

  Future<dynamic> _request(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    if (_disposed) throw StateError('API 已关闭');
    final uri = base.replace(path: '${base.path}$path', queryParameters: query);
    HttpClientRequest? request;
    var cancelled = false;
    try {
      return await (() async {
        final opened = await _client.openUrl(
          body == null ? 'GET' : 'POST',
          uri,
        );
        request = opened;
        if (_disposed || cancelled) {
          opened.abort();
          throw StateError('请求已取消');
        }
        opened.followRedirects = false;
        upstreamHeaders.forEach(opened.headers.set);
        opened.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (body != null) {
          opened.headers.contentType = ContentType(
            'text',
            'plain',
            charset: 'utf-8',
          );
          opened.write(jsonEncode(body));
        }
        final response = await opened.close();
        if (response.statusCode == 401) {
          token = '';
          account = null;
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > maxResponseBytes) {
            opened.abort();
            throw const FormatException('服务响应过大');
          }
        }
        dynamic data;
        try {
          data = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          throw OpusApiException(
            response.statusCode == 401
                ? '登录已过期，请重新登录'
                : '服务未返回有效 JSON（HTTP ${response.statusCode}）',
            status: response.statusCode,
          );
        }
        final error = data is Map ? data['error'] : null;
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            error != null) {
          throw OpusApiException(
            response.statusCode == 401
                ? '登录已过期，请重新登录'
                : error?.toString() ?? '请求失败（HTTP ${response.statusCode}）',
            status: response.statusCode,
          );
        }
        return data;
      })().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      cancelled = true;
      request?.abort();
      throw const OpusApiException('请求超时，请检查服务地址与网络');
    } on SocketException {
      throw const OpusApiException('无法连接上游服务，请检查服务地址与网络');
    } on HandshakeException {
      throw const OpusApiException('上游服务的 TLS 连接失败');
    } on HttpException {
      throw const OpusApiException('上游服务连接中断，请重试');
    }
  }

  void dispose() {
    _disposed = true;
    token = '';
    account = null;
    _client.close(force: true);
  }
}

class OpusApiException implements Exception {
  const OpusApiException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => message;
}
