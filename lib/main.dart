import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/java_proxy.dart';
import 'services/opus_api.dart';

void main() => runApp(const MyApp());

const _accent = Color(0xFF80E5C3);
const _muted = Color(0xFF939EAF);
const _panel = Color(0xFF161E2A);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpusMC-Proxy',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _accent,
        brightness: Brightness.dark,
        surface: _panel,
      ).copyWith(primary: _accent),
      scaffoldBackgroundColor: const Color(0xFF0C121C),
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'PingFang SC',
        'sans-serif',
      ],
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF101722),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2A3545)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 17,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 19),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      dividerColor: const Color(0xFF293344),
    ),
    home: const AgentHome(),
  );
}

class AgentHome extends StatefulWidget {
  const AgentHome({super.key});

  @override
  State<AgentHome> createState() => _AgentHomeState();
}

class _AgentHomeState extends State<AgentHome> with WidgetsBindingObserver {
  final _upstream = TextEditingController(text: 'https://xz.honghemc.cn:8443');
  final _code = TextEditingController();
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '25565');
  final _room = TextEditingController();
  final _logScroll = ScrollController();
  final List<String> _logs = [];
  late OpusApi _api;
  late JavaProxy _proxy;
  Timer? _statusTimer;
  List<Map<String, dynamic>> _public = [];
  List<Map<String, dynamic>> _own = [];
  String? _publicError;
  String? _ownError;
  String? _notice;
  String? _activeRoom;
  bool _noticeError = false;
  bool _busy = false;
  bool _refreshing = false;
  bool _showCode = false;
  bool _lastRunning = false;
  int _tab = 0;
  int _renderDistance = 8;

  bool get _authenticated => _api.token.isNotEmpty && _api.account != null;
  bool get _locked => _busy || _refreshing || _proxy.running;
  String get _localAddress {
    final host = _host.text.trim();
    final formatted = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return '$formatted:${_proxy.port}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = OpusApi(_upstream.text);
    _proxy = JavaProxy(api: _api, log: _appendLog);
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _lastRunning == _proxy.running) return;
      setState(() {
        _lastRunning = _proxy.running;
        if (!_proxy.running) _activeRoom = null;
      });
    });
    // Opening the dashboard never makes a network or credential request.
    _appendLog('工作台已就绪。登录账户，选择房间后启动本地代理。');
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    try {
      await _proxy.stop();
    } finally {
      _api.dispose();
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    unawaited(_proxy.stop().catchError((Object _) {}));
    _api.dispose();
    for (final controller in [_upstream, _code, _host, _port, _room]) {
      controller.dispose();
    }
    _logScroll.dispose();
    super.dispose();
  }

  void _appendLog(String value) {
    if (!mounted) return;
    var safe = value;
    for (final secret in [_api.token, _code.text]) {
      if (secret.isNotEmpty) safe = safe.replaceAll(secret, '••••••');
    }
    final now = DateTime.now();
    final time = [
      now.hour,
      now.minute,
      now.second,
    ].map((part) => part.toString().padLeft(2, '0')).join(':');
    final follow =
        !_logScroll.hasClients ||
        _logScroll.position.maxScrollExtent - _logScroll.offset < 64;
    setState(() {
      _logs.add('[$time] $safe');
      if (_logs.length > 600) _logs.removeRange(0, _logs.length - 600);
    });
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _message(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = text;
      _noticeError = error;
    });
  }

  String _error(Object error) {
    if (error is FormatException) return error.message;
    return error.toString().replaceFirst(
      RegExp(r'^(Exception|Bad state): '),
      '',
    );
  }

  void _syncUpstream() {
    final next = OpusApi(_upstream.text);
    if (next.base == _api.base) {
      next.dispose();
      return;
    }
    _api.dispose();
    _api = next;
    _proxy = JavaProxy(api: _api, log: _appendLog);
    _public = [];
    _own = [];
    _publicError = null;
    _ownError = null;
    _appendLog('上游服务已切换，请在新服务上重新登录。');
  }

  Future<void> _perform(Future<void> Function() task) async {
    if (_busy || _refreshing) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await task();
    } catch (error) {
      _message(_error(error), error: true);
      _appendLog('操作失败：${_error(error)}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _lastRunning = _proxy.running;
          if (!_authenticated) _own = [];
          if (!_proxy.running) _activeRoom = null;
        });
      }
    }
  }

  Future<void> _login() => _perform(() async {
    if (_code.text.trim().isEmpty) throw const FormatException('请输入身份识别码');
    _syncUpstream();
    await _api.login(_code.text);
    _code.clear();
    _message('登录成功，欢迎 ${_api.account?['name'] ?? '回来'}');
    _appendLog('账户登录成功。识别码已清空，令牌仅保存在内存。');
    await _loadRooms();
  });

  Future<void> _logout() => _perform(() async {
    await _proxy.stop();
    await _api.logout();
    _code.clear();
    _own = [];
    _ownError = null;
    _message('已退出登录，内存中的账户信息已清除');
    _appendLog('已退出登录。');
  });

  Future<void> _refresh() async {
    if (_locked) return;
    setState(() {
      _refreshing = true;
      _notice = null;
    });
    try {
      _syncUpstream();
      await _loadRooms();
    } catch (error) {
      _message(_error(error), error: true);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _loadRooms() async {
    // One failed endpoint must not hide the other endpoint's room list.
    await Future.wait([
      (() async {
        try {
          final rooms = await _api.publicRooms();
          if (mounted) {
            setState(() {
              _public = rooms;
              _publicError = null;
            });
          }
        } catch (error) {
          if (mounted) {
            setState(() {
              _public = [];
              _publicError = _error(error);
            });
          }
        }
      })(),
      (() async {
        if (!_authenticated) return;
        try {
          final rooms = await _api.ownRooms();
          if (mounted) {
            setState(() {
              _own = rooms;
              _ownError = null;
            });
          }
        } catch (error) {
          if (mounted) {
            setState(() {
              _own = [];
              _ownError = _error(error);
            });
          }
        }
      })(),
    ]);
    if (!mounted) return;
    if (!_authenticated) setState(() => _own = []);
    if (_publicError != null || _ownError != null) {
      _message(_ownError ?? _publicError!, error: true);
    }
  }

  Future<void> _toggleProxy() => _perform(() async {
    if (_proxy.running) {
      await _proxy.stop();
      _message('本地代理已停止');
      return;
    }
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final room = _room.text.trim().toUpperCase();
    if (host.isEmpty || RegExp(r'[\s/]').hasMatch(host)) {
      throw const FormatException('请输入有效的本地监听主机');
    }
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('监听端口必须在 1–65535 之间');
    }
    if (!RegExp(r'^[A-Z0-9]{4,8}$').hasMatch(room)) {
      throw const FormatException('请输入 4–8 位字母或数字房间码');
    }
    _syncUpstream();
    if (!_authenticated) throw StateError('请先使用识别码登录当前上游服务');
    _room.text = room;
    await _proxy.start(
      host: host,
      port: port,
      room: room,
      renderDistance: _renderDistance,
    );
    _activeRoom = room;
    _message('代理已启动，在 Java 版多人游戏中连接 $_localAddress');
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, viewport) {
          final padding = viewport.maxWidth < 600 ? 16.0 : 28.0;
          return SingleChildScrollView(
            padding: EdgeInsets.all(padding),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1260),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    const SizedBox(height: 26),
                    _connectionBanner(),
                    if (_notice != null) ...[
                      const SizedBox(height: 16),
                      _noticeBanner(),
                    ],
                    const SizedBox(height: 22),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final settings = Column(
                          children: [
                            _accountCard(),
                            const SizedBox(height: 20),
                            _settingsCard(),
                          ],
                        );
                        if (constraints.maxWidth < 900) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              settings,
                              const SizedBox(height: 20),
                              _roomsCard(),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 358, child: settings),
                            const SizedBox(width: 22),
                            Expanded(child: _roomsCard()),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 22),
                    _logsCard(),
                    const SizedBox(height: 18),
                    const Text(
                      'OPUSMCAGENT  /  本地连接工作台',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 11,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _header() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _accent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.hub_rounded,
              color: Color(0xFF122B26),
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OpusMC-Proxy',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
                Text(
                  '连接你的下一场冒险',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _pill(
        _authenticated ? '账户已连接' : '等待登录',
        _authenticated ? _accent : _muted,
        _authenticated ? Icons.verified_user_outlined : Icons.person_outline,
      ),
    ],
  );

  Widget _connectionBanner() => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF183830), Color(0xFF172332)],
      ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFF2B5147)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              _proxy.running
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: _proxy.running ? _accent : _muted,
              size: 16,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                _proxy.running ? '本地代理运行中' : '准备好，即可出发',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _proxy.running
              ? '房间 $_activeRoom · 在 Java 版添加下方服务器地址'
              : '登录账户，选择世界，让 Java 版连接 OpusMC。',
          style: const TextStyle(
            color: Color(0xFFB4C7C3),
            fontSize: 12,
            height: 1.7,
          ),
        ),
        const SizedBox(height: 18),
        if (_proxy.running)
          OutlinedButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(_localAddress, softWrap: true),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _localAddress));
              _message('本地服务器地址已复制');
            },
          )
        else
          _pill('JAVA EDITION', _accent, Icons.sports_esports_outlined),
      ],
    ),
  );

  Widget _noticeBanner() => Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
    decoration: BoxDecoration(
      color: _noticeError ? const Color(0xFF34232B) : const Color(0xFF1D302D),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(
          _noticeError ? Icons.error_outline : Icons.check_circle_outline,
          color: _noticeError ? const Color(0xFFFFA8AC) : _accent,
          size: 19,
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(_notice!, style: const TextStyle(fontSize: 13))),
        IconButton(
          tooltip: '关闭提示',
          onPressed: () => setState(() => _notice = null),
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    ),
  );

  Widget _accountCard() => _card(
    children: [
      _sectionTitle('账户', '01', Icons.fingerprint_rounded),
      const SizedBox(height: 22),
      if (_authenticated) ...[
        Row(
          children: [
            const CircleAvatar(
              backgroundColor: Color(0xFF294B40),
              child: Icon(Icons.person_rounded, color: _accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_api.account?['name'] ?? _api.account?['nick'] ?? 'Opus 玩家'}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Text(
                    '身份已验证 · 仅本次会话有效',
                    style: TextStyle(color: _muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: _busy || _refreshing ? null : _logout,
          icon: const Icon(Icons.logout, size: 17),
          label: const Text('退出登录'),
        ),
      ] else ...[
        const Text(
          '使用个人身份识别码登录',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          '识别码不会写入磁盘，关闭应用即清除会话。',
          style: TextStyle(color: _muted, fontSize: 12, height: 1.7),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _code,
          enabled: !_locked,
          obscureText: !_showCode,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) {
            if (!_locked) _login();
          },
          decoration: InputDecoration(
            labelText: '身份识别码',
            hintText: '输入你的个人识别码',
            suffixIcon: IconButton(
              tooltip: _showCode ? '隐藏识别码' : '显示识别码',
              onPressed: () => setState(() => _showCode = !_showCode),
              icon: Icon(
                _showCode
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 19,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _locked ? null : _login,
          icon: const Icon(Icons.arrow_forward_rounded, size: 18),
          label: Text(_busy ? '请稍候…' : '登录账户'),
        ),
      ],
    ],
  );

  Widget _settingsCard() => _card(
    children: [
      _sectionTitle('连接设置', '02', Icons.tune_rounded),
      const SizedBox(height: 22),
      TextField(
        controller: _upstream,
        enabled: !_locked,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: '上游服务 URL',
          helperText: '更换服务后需重新登录',
          helperStyle: TextStyle(fontSize: 11),
        ),
      ),
      const SizedBox(height: 18),
      LayoutBuilder(
        builder: (context, constraints) {
          final host = TextField(
            controller: _host,
            enabled: !_locked,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '监听主机'),
          );
          final port = TextField(
            controller: _port,
            enabled: !_locked,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '端口'),
          );
          if (constraints.maxWidth < 280) {
            return Column(children: [host, const SizedBox(height: 14), port]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: host),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: port),
            ],
          );
        },
      ),
      const SizedBox(height: 22),
      Wrap(
        spacing: 14,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        children: [
          const Text('渲染距离', style: TextStyle(fontSize: 13)),
          Text(
            '$_renderDistance 区块',
            style: const TextStyle(color: _accent, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      Slider(
        value: _renderDistance.toDouble(),
        min: 2,
        max: 16,
        divisions: 14,
        label: '$_renderDistance 区块',
        onChanged: _locked
            ? null
            : (value) => setState(() => _renderDistance = value.round()),
      ),
      const Text(
        '较低的距离可减少网络流量与客户端负载。',
        style: TextStyle(color: _muted, fontSize: 11, height: 1.7),
      ),
    ],
  );

  Widget _roomsCard() => _card(
    children: [
      Row(
        children: [
          Expanded(child: _sectionTitle('选择世界', '03', Icons.public_rounded)),
          IconButton(
            tooltip: '刷新房间',
            onPressed: _locked ? null : _refresh,
            icon: _refreshing || _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (index, label) in ['公开房间', '我的房间', '邀请码'].indexed)
            ChoiceChip(
              label: Text(label),
              selected: _tab == index,
              showCheckmark: false,
              onSelected: _busy ? null : (_) => setState(() => _tab = index),
            ),
        ],
      ),
      const SizedBox(height: 18),
      if (_tab == 2)
        _empty(Icons.vpn_key_outlined, '朋友的世界，一码直达', '在下方输入 4–8 位房间邀请码，再启动代理。')
      else if (_tab == 1 && !_authenticated)
        _empty(Icons.lock_outline_rounded, '登录后查看你的世界', '使用身份识别码登录，即可读取我的房间。')
      else if ((_tab == 0 ? _publicError : _ownError) != null)
        _empty(
          Icons.cloud_off_rounded,
          '暂时无法读取房间',
          _tab == 0 ? _publicError! : _ownError!,
        )
      else if ((_tab == 0 ? _public : _own).isEmpty)
        _empty(
          Icons.landscape_outlined,
          _refreshing || _busy ? '正在读取房间…' : '这里还没有房间',
          _tab == 0 ? '点击右上角刷新，或使用邀请码连接。' : '点击刷新读取你在上游服务创建的房间。',
        )
      else
        SizedBox(
          height: 300,
          child: ListView.separated(
            itemCount: (_tab == 0 ? _public : _own).length,
            separatorBuilder: (_, index) => const SizedBox(height: 10),
            itemBuilder: (context, index) =>
                _roomTile((_tab == 0 ? _public : _own)[index]),
          ),
        ),
      const SizedBox(height: 20),
      const Divider(height: 1),
      const SizedBox(height: 22),
      TextField(
        controller: _room,
        enabled: !_locked,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        maxLength: 8,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
        ],
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: '目标房间码',
          hintText: '选择房间，或手动输入邀请码',
          prefixIcon: Icon(Icons.tag_rounded),
          counterText: '',
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        style: _proxy.running
            ? FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6A303C),
                foregroundColor: Colors.white,
              )
            : null,
        onPressed: _busy || _refreshing ? null : _toggleProxy,
        icon: Icon(
          _proxy.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
        ),
        label: Text(
          _busy
              ? '正在处理…'
              : _proxy.running
              ? '停止代理'
              : '启动本地代理',
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        '启动后，在 Minecraft Java 版 → 多人游戏中添加本地监听地址。',
        style: TextStyle(color: _muted, fontSize: 11, height: 1.6),
      ),
    ],
  );

  Widget _roomTile(Map<String, dynamic> room) {
    final code = '${room['code'] ?? ''}'.toUpperCase();
    final selected = code == _room.text.trim().toUpperCase();
    final players = room['players'];
    final count = players is List ? players.length : players ?? 0;
    final mode =
        {
          'survival': '生存',
          'creative': '创造',
          'adventure': '冒险',
          'spectator': '旁观',
        }[room['gamemode']] ??
        '世界';
    return Material(
      color: selected ? const Color(0xFF203A34) : const Color(0xFF101722),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? _accent : const Color(0xFF283344)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _locked || code.isEmpty
            ? null
            : () => setState(() => _room.text = code),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_circle_rounded : Icons.grass_rounded,
                color: selected ? _accent : const Color(0xFF7CA29A),
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${room['name'] ?? '未命名世界'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '$mode · 房主 ${room['owner'] ?? '未知'} · $code',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '$count / ${room['max'] ?? '—'} 人在线',
                      style: const TextStyle(color: _accent, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logsCard() => _card(
    children: [
      Row(
        children: [
          Expanded(
            child: _sectionTitle('运行日志', 'LIVE', Icons.terminal_rounded),
          ),
          IconButton(
            tooltip: '清空日志',
            onPressed: () => setState(_logs.clear),
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Container(
        height: 205,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF090F17),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Scrollbar(
          controller: _logScroll,
          child: ListView.builder(
            controller: _logScroll,
            itemCount: _logs.length,
            itemBuilder: (_, index) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: SelectableText(
                _logs[index],
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: ['Microsoft YaHei'],
                  fontSize: 12,
                  color: Color(0xFFA6C9BD),
                  height: 1.6,
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _card({required List<Widget> children}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF263141)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _sectionTitle(String title, String index, IconData icon) => Row(
    children: [
      Icon(icon, size: 19, color: _accent),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      const SizedBox(width: 10),
      Text(
        index,
        style: const TextStyle(color: _muted, fontSize: 10, letterSpacing: 1.5),
      ),
    ],
  );

  Widget _pill(String label, Color color, IconData icon) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _empty(IconData icon, String title, String subtitle) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 230),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFF56746D), size: 44),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, fontSize: 12, height: 1.7),
            ),
          ],
        ),
      ),
    ),
  );
}
