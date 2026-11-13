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

HTTP 和 WebSocket 请求均携带原游戏 iframe 的 Origin/Referer，上游会在处理登录或房间请求之前检查来源。公开房间响应允许最大 16 MiB，避免当前约 5 MB 的列表被错误拒绝。

托管房间入房使用 OpusMC 账号名，Java 玩家名仅用于本地连接身份。`queue` 表示等待上游启动房间，日志显示 `pos` 队列位置和 `of` 等待房间总数；排队期间不受 90 秒启动超时限制，断开 Java 连接即可取消。上游发送 `notice` 离开排队后恢复启动超时，收到 `login` 后停止启动计时。本地 WebRTC 联机与已启动的公开房间不等同于启动一个停止的托管房间。

上游方块状态表通过名称和完整属性映射到 26.2，允许表长及编号顺序不同。区块、单个/批量方块更新、落沙实体和方块破坏/刷扫效果统一转换状态编号。26.2 中不存在的状态用石头显示并在日志列出数量及最多 8 个样例；编号越界、缺少 air 或无效表仍会断开。此映射解决方块表差异，不代表其他协议差异均已兼容。

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
- `lib/protocol/state_registry.dart`：上游到 26.2 的方块状态名称映射。
- `lib/protocol/ids.dart`：由本地 26.2 源码生成的包编号。
- `assets/registries.json`：原版 26.2 配置包及物品/实体等 ID 快照。
- `tool/generate_protocol.py`：重新生成协议数据的开发工具。参数见 `python tool/generate_protocol.py --help`；日常使用无需运行。

## 验证范围与限制

自动化测试使用本地模拟 HTTP/WebSocket 房间和 Java TCP 客户端，覆盖分帧、登录配置、区块转换、接口和消息转发。它们不能替代真实 26.2 客户端进入真实房间的联调。开发过程中没有使用个人识别码或向真实房间发送游戏操作。

OpusMC 上游协议裁剪了完整 Java 数据。物品完整 data components、所有实体 metadata、方块实体 NBT、配方书、计分板、进度、BossBar 等无法保证完整还原；这些信息也无法由 ViaVersion 补齐。这是需要真实房间验证的桥接版本，自动化测试通过不代表完整原版兼容。

当前实现覆盖登录配置、区块/光照、走动、聊天/命令、挖放方块、攻击/交互、基础背包/容器及实体显示。创造飞行开关尚未发现可验证的上游消息，暂不转发；特殊物品组件的创造栏操作会被拒绝并恢复槽位。音效、药水效果、完整交易与配方等仍需补充。遇到未实现的消息会在日志中提示。
