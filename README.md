# OpusMCAgent

Windows Flutter 桌面程序：使用 OpusMC 个人识别码登录，选择正式多人房间，将房间的 WebSocket 语义协议转换为 Minecraft Java **26.2 / 协议 776** 的本地 TCP 入口。注册表快照随程序打包，运行时不需要 Java。不集成 ViaVersion。

## 使用

1. 运行 `flutter pub get` 和 `flutter run -d windows`，或打开构建后的 Windows 程序。
2. 输入自己的识别码并登录。
3. 刷新公开房间、查看自己的房间，或输入朋友给的邀请码。
4. 选择房间并启动代理，默认地址 `127.0.0.1:25565`。
5. Minecraft Java 26.2 → 多人游戏 → 直接连接 → 输入该地址。

跨版本请自行配置 ViaVersion/ViaProxy 等工具，并将目标服务端版本设置为 26.2。本程序代理正式托管房间；浏览器 WebRTC 本地房间使用另一套协议。

识别码、账号 token 只保留在内存，不写入配置文件；重启后重新登录。上游服务地址可修改，默认来自客户端 `netconfig.js`。账号多人权限、房间人数及排队由上游判定。

一个代理实例允许一个 Java 玩家同时使用登录的 OpusMC 账号；服务器列表 ping 不占此名额。其他玩家分别运行自己的实例并登录自己的账号，然后加入同一个房间。默认仅本机监听；修改监听地址后，该入口使用的是本程序已登录的 OpusMC 身份。

## 开发和构建

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

发行时复制整个 `build/windows/x64/runner/Release` 目录，不能只复制 exe。运行程序本身不需要 Flutter SDK 或 Java。

## 实现

- `lib/main.dart`：中文桌面界面、账号、房间选择、配置和日志。
- `lib/services/opus_api.dart`：识别码登录、公开/自有房间查询。
- `lib/services/java_proxy.dart`：TCP 分帧、Status/Login/Configuration/Play 状态机和会话生命周期。
- `lib/protocol/game_bridge.dart`：玩家、方块、实体等游戏语义转换。
- `lib/protocol/inventory_bridge.dart`：背包/容器语义转换。
- `lib/protocol/chunks.dart`：二进制区块和光照转换。
- `lib/protocol/ids.dart`：由本地 26.2 源码生成的包编号。
- `assets/registries.json`：原版 26.2 配置包及物品/实体等 ID 快照。
- `tool/generate_protocol.py`：重新生成协议数据的开发工具。参数见 `python tool/generate_protocol.py --help`；日常使用无需运行。

## 验证范围与限制

自动化测试使用本地模拟 HTTP/WebSocket 房间和 Java TCP 客户端，覆盖分帧、登录配置、区块转换、接口和消息转发。它们不能替代真实 26.2 客户端进入真实房间的联调。开发过程中没有使用个人识别码或向真实房间发送游戏操作。

OpusMC 上游协议裁剪了完整 Java 数据。物品完整 data components、所有实体 metadata、方块实体 NBT、配方书、计分板、进度、BossBar 等无法保证完整还原；这些信息也无法由 ViaVersion 补齐。这是需要真实房间验证的桥接版本，自动化测试通过不代表完整原版兼容。
