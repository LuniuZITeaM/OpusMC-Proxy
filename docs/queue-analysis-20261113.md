# 入房与 queue 复核（2026-11-13）

## 证据

取得官方静态资源版本 `47455601425408-v47877` 的 `js/net.js`、`js/account.js`、`js/screens.js`、`js/netconfig.js`，解压 gzip 并统一换行后，与本地原始 Dump 对应文件一致。B站外层页面的脚本请求返回 HTTP 412，因此这次只能确认该静态版本的内容，不能据此认定它是所有用户拿到的最新版本。

- `net.js` 的 `NetClient` 在 WebSocket 打开后直接发送 `hello`，字段为 `name/version/proto/room/key/token/rd`，没有额外 HTTP 加入或启动请求。
- `MultiplayerScreen.okName()` 优先取 `Account.name`；`account.js` 包装的 `RoomService.key()` 优先取账号 `roomKey`。
- `screens.js` 的 `LoadingScreen` 将 `queue.pos` 显示为房间队列位置，`queue.of` 显示为等待房间总数；等待两分钟后提示换正在玩的公开房间或本地联机，没有固定排队超时。
- `net.js` 的 `notice` 清除加载界面的 queue；`login` 才进入世界。`NetClient.tick()` 在没有玩家或不处于 play 时直接返回，因此没有证据支持增加排队期间的应用层 tick。

2026-11-13 约 22:22（Asia/Shanghai），只读请求 `/api/rooms/3V75VK` 得到 `state: stopped`、`max: 4`；`/api/capacity` 得到 `sizes` 全 false、`max: 0`、`reason: 服务器现在太忙了`、`queue: 11`。这些是查询时快照，11 是容量接口的全局等待数，不是该用户的位置。

用户随后确认：网页能进入的是其他房间或本地联机。因此目前没有同账号、同一托管房间在两端表现不同的证据，也不能将账号名差异认定为排队原因。

## 修复

- 入房 hello 使用账号名，与网页保持一致，允许账号中文名；本地 Java 登录仍使用原 Java 玩家名。
- queue 暂停 90 秒房间启动超时；notice 离开 queue 后重新计时；login、断开与停止代理取消计时。
- 显示排队位置和总数，不输出 token、识别码或完整 hello。
- 加载阶段的 notice 只记入代理日志，不在 Java LOGIN 包之前发送游戏聊天；queue、room 不再被当作不支持的游戏消息。

回归测试通过虚拟时间覆盖长时间排队、重复队列更新、notice 恢复超时、成功登录与取消；本地 TCP/WebSocket 集成测试覆盖中文账号名、roomKey、queue → notice → login 以及之后的区块与聊天。

没有使用个人账号凭据连接真实房间；本地测试不等同于真实 Java 客户端完整游戏兼容验证。
