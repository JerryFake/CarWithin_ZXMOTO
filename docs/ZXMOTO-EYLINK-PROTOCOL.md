# ZXMOTO 投屏协议（EYLink / EryaNet）— 从官方 Android App 逆向

来源：官方 ZXMOTO Android 1.4.5（包名 `com.zxjc`，`jadxout/sources/com/eryanet/ite/**`）。这是 500RR / 820R 仪表"手机投屏"的权威协议，手机（Android/iOS 同理）作为客户端连到仪表热点。

## 0. 网络

- 仪表 WiFi 热点：`iteAP` 或 `iteAP-xxxx`（手册提示加入该 WiFi；AP 网段 192.168.43.0/24）。
- 仪表 IP：`192.168.43.1`（Constants.SERVER_IP）。
- 镜像通道：**TCP 11111**（默认 `R2.id.bnav_enlarge_bottom_shadow=11111`），也支持 UDP 11111（Android 仅在蓝牙老设备回退时用）。
- 控制消息通道：TCP 11113（默认 `TCP_PORT_MESSAGE=11113`；BLE/二维码协商可改，二维码 JSON 的 `port1`=镜像口、`port2`=控制口）。
- Android 连接时绑定本地 p2p*/wlan* 网卡（与 192.168.43.1 同网段的本地 IP）。iOS 加入该 WiFi 后默认路由即可。

## 1. 镜像帧格式（AA BB CC）

12 字节头 + payload：

```
AA BB CC <func> 00 00 00 00 <LE32 payloadLen> <payload>
```

- bytes 0..3: `0xAA,0xBB,0xCC,func`
- bytes 4..7: 全 0（从不使用）
- bytes 8..11: payload 长度，**小端 uint32**
- bytes 12..: payload

func（`Parser.Func`）：

| func | 名称 | payload |
|---|---|---|
| 0 | VIDEO_DATA | `LE32 时间戳ms` + Annex-B H.264 字节（可含 SPS/PPS/IDR 等） |
| 1 | AUDIO_DATA | 未用于投屏 |
| 4 | MIRROR_START | `LE16 min(W,H)` + `LE16 max(W,H)`（手机窗口尺寸，长边 ≤2560，奇偶不严格） |
| 5 | MIRROR_STOP | 空 |
| 6 | WIDTH_HEIGHT | `LE16 W` + `LE16 H`（手机窗口；每 2 秒重发一次） |

注意：**长度/尺寸/时间戳全部小端**（ByteUtil.intTo4Bytes/intTo2Bytes 均为 LE；解析用的 byte4ToInt/byte2ToInt 也是 LE）。旧实现用了大端，是错的。

## 2. 镜像通道连接与握手（TCP 11111）

官方 Android 在无 BLE 场景（手动连 WiFi）直接：
1. TCP connect `192.168.43.1:11111`（connect timeout 3000ms；SO_SNDBUF/SO_RCVBUF=524288，keepAlive，tcpNoDelay）。
2. 连接成功后，单独线程每 500~1000ms 发送一次 `MIRROR_START`，直到收到 `OK` 参数（最多约 15~30 次）。每次发送都重置 startTime 基准（时间戳=now-startTime）。
3. 仪表回 **13 字节** `OK` 包（ASCII `'O','K'` + 11 字节）：
   ```
   b[0..1] = 'O','K'
   b[2..3]  LE16 portraitWidth
   b[4..5]  LE16 portraitHeight
   b[6..7]  LE16 landscapeWidth
   b[8..9]  LE16 landscapeHeight
   b[10]    uint8 fps
   b[11..12] LE16 bitrate (kbps)
   ```
   四个尺寸若为奇数都要 +1（ClientDataHandler）。随后按手机方向选尺寸：竖屏用 portrait，横屏用 landscape；启动编码器（fps、bitrate*1000）。
4. 镜像通道上还可能收到：
   - `'T','P'` + 13 字节（共 15 字节）：用途未知，忽略即可（Android 也只交给 msg0，未解析）。
   - `AA BB ?? 0F` 心跳/ACK 帧：完整 12 字节头（func=0x0F=ACK，长度在 bytes8..11 LE32），随后 JSON（长度 0<len<50）：
     - 含 `"ver"`：心跳，重置 12s 超时；
     - 含 `"ack"`：ACK；
     - 含 `"timestamp"`：`{"timestamp":"<ms>"}`，仪表播放进度（用于追帧，见下）。
5. 收到 OK 后开始发送视频帧（func 0）。发送顺序：先单独发 SPS、PPS（各一帧，Annex-B），随后编码器输出的 Annex-B 帧逐帧发送。
6. 断开：可发 func 5 `MIRROR_STOP`，然后关闭连接。

## 3. 编码参数（官方 Android ScreenRecorder）

- `video/avc`，CBR（bitrate-mode=2），`bitrate = 仪表回包 kbps * 1000`，`frame-rate = 仪表 fps`，`i-frame-interval = 2s`，输入 Surface。
- 分辨率 = 回包尺寸（按屏幕方向选 portrait/landscape）。
- 每个关键帧（IDR）建议带上 SPS/PPS（Android 在起始与输出格式变化时单独发 SPS、PPS 帧），iOS VideoToolbox 输出 AVCC 需要转 Annex-B。

## 4. 追帧逻辑（可选但建议）

- `startTime` = 每次发 MIRROR_START 的时刻；VIDEO_DATA 时间戳 = `now - startTime`（ms，LE32）。
- 若收到仪表 `timestamp`（carTime）：滞后 `|ts - carTime| > 2000ms` 时进入"只发关键帧"模式（丢非关键帧并请求编码器 IDR），滞后恢复后先发一个关键帧再恢复正常发送。
- 心跳超时 12s 视为断开。

## 5. 控制通道（TCP 11113，可选）

帧格式：`'E','Y'` + `BE32 jsonLen` + `BE32 extraLen` + JSON + extra。

- 仪表→手机 JSON：`fun` 可为 `mirrorControl`（`type=="0"` 表示仪表要求停止投屏）、`closeHeart`、`funSwitch`、`active`；另有天气/导航数据。
- 手机→仪表：`{"fun":"mirror","type":"0"}`（停投屏）；时间/日期、天气、导航 JSON（本 app 只做投屏，可不发）。
- 官方基础投屏（无 BLE）不依赖控制通道；打开它只用于接收"停止投屏"指令与日志。若连接失败不影响镜像。

## 6. 旧版非权威实现（不要照抄）

- `App/EylinkOutput.swift` 现有实现：大端长度/时间戳/尺寸、控制口 11112、UDP 优先 —— 与本协议不符，需修正为以上小端 + TCP 11111 优先。
- 第三方 fork（xyq9）的 `Zx500rrOutput.swift`：TCP 1111 / 11113、无握手，实验性质，未验证。
- 其他开发者 IPA 1.0.9 用另一套 `ZxDashPacket`（LE32 type + flag + LE32 len），与官方 Android 协议不同，可靠性未知；优先按本文件实现。

## 7. 待实车确认

- 仪表热点是否有密码、是否必须先经 BLE 配对才开放 11111/11113。
- 820R（6.2 寸，可能 1280x720/1280x480 类）回包尺寸与 500RR 是否相同；实现应完全采用 OK 回包参数，只把尺寸作为 MIRROR_START 初始值。

## 附：官方 iOS App 侧证据（补充，2026-11-28）

官方 iOS App 的 ReplayKit 扩展 MotorMirror.appex 代码受 FairPlay 加密，但从明文导出符号 + 主 App 字符串可确认：

- iPhone 端加入的热点除老车 iteAP 外，官方 iOS App 也会用 ZXMOTO-… 前缀热点（App 内 HotspotStatus/hotspotPassword/pplyHotspotConfiguration 走 NEHotspotConfiguration，CarWithin 无法自动加入，只能手动）。
- iOS 扩展是**服务端**设计（indServerPortInRange(_:socket:retryCount:)、didAcceptNewSocket、随机 command/data 端口 + UDP 广播端口信息），与 Android v1 的直连 11111 不同，属于 EYMirror v2；v2 多字节字段为大端，且只用于官方 App ↔ 扩展之间，仪表投屏主线仍是本文件描述的 EYLink v1。
- 心跳/时间同步语义：OK 之后仪表会以 AA BB CC 0F + 8 字节 + u32 LE 长度 + JSON 发 er/ck/	imestamp；12 秒收不到 er 视为链路断开。

详见 docs/eymirror-protocol.md（含符号地址与 v2 结构体候选布局）。
