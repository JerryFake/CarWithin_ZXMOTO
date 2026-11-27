# ZXMOTO 820R 输出集成方案（Integration Plan）

- 目标仓库：`C:\Users\x1043\Documents\Carwithin`（CarWithin fork，`JerryFake/CarWithin_ZXMOTO`）
- 上游基线：CarWithin **1.0.6**（`cffbf58`，tag `v1.0.6` = `59d955f`）
- 当前 HEAD：`6f27771`（“ZXMOTO: validate ACK frame prefix AA BB CC 0F, add 12s no-connection hint”），分支 `zxmoto-500rr-upstream`；`6704a30` 之后已有两次协议修正（`a419721` 小端 + TCP 11111 主通道 + 控制 11113 + 820R 文档；`6f27771` ACK 前缀 + 12 s 未连接提示）。
- 权威线协议文档：`docs/ZXMOTO-EYLINK-PROTOCOL.md`（官方 Android 1.4.5 反编译，92 行）。并行 RE Agent 还将产出 `docs/zxdash-protocol.md`（第三方 1.0.9 IPA）与 `docs/eymirror-protocol.md`（官方 iOS appex），落地时交叉验证。
- 现状：前一轮已在 **上游 1.0.6 架构**上追加了一套实验性 ZXMOTO EYLink 输出（`App/EylinkOutput.swift`，**776 行单文件**，已按官方协议修正为小端 / TCP 11111 主通道），并已接好枚举、菜单、设置、`NativeReceiver` 生命周期链路。`dist/CarWithin-ZXMOTO-500RR-1.0.6-ZXMOTO/` 里有一次 **BUILD SUCCEEDED** 的 unsigned IPA 打包记录。
- 本方案定位：**在有 `EylinkOutput` 既有实现的基础上重构成可长期维护的 ZXMOTO 输出**，与最终选用的线协议解耦（候选 A：官方 EYLink/EryaNet，Android 1.4.5 反编译，主候选；候选 B：ZxDash，第三方 1.0.9 参考实现）。实现 Agent 不能在本地编译（Windows、无 Xcode），真实编译门禁是 GitHub Actions `macos-15`；因此本方案给出可静态检查的改动清单和精确锚点。

---

## 0. TL;DR（推荐做法）

1. **保留两个菜单项** `.zxmoto500rr` / `.zxmoto820r`（持久化 rawValue 28/29 绝不能变），二者都进入同一个输出类，用 `ZxmotoProfile` 的 model 区分默认参数；不要为 820R 复制一套输出代码。
2. **按上游 `MotorcycleOutput` + transport 对象的模式重构**：`ZxmotoOutput` 只负责“CarPlay H.264 → 解码 → 缩放/letterbox → 重编码 → 逐帧发送”这段不断复用的转码流水线；连线、握手、协议编解码全部下沉到 `ZxmotoConnection`（可换实现）。
3. 新建四个文件：`Sources/TDSCarKitCore/ZxmotoProfile.swift`、`Sources/TDSCarKitCore/ZxmotoProtocol.swift`（纯字节、可单测）、`App/ZxmotoConnection.swift`、`App/ZxmotoOutput.swift`；**删除** `App/EylinkOutput.swift`。文件命名与上游 `ShouquConnection/ShouquProtocol`、`YunmoConnection/YunmoProtocol` 的 conventions 一致。
4. 协议无关层用 `protocol ZxmotoTransport`（`start/checkHealth/send/close` + negotiated size 回调）收口；候选 A/B 只需各自实现一个 transport 子类，`ZxmotoOutput`、`NativeReceiver`、设置页都不再改。
5. **`App/EylinkOutput.swift` 的“乱码”已被证伪**：文件本身是合法 UTF-8（`e4bbaae8a1a8` = 仪表、`e5bca0e99baa` = 张雪；`gbk-roundtrip differs=False`），之前看到的乱码只是 Windows PowerShell 控制台按 GBK 解码 UTF-8 的显示问题。**不要修乱码**；重写是为了拆分架构，不是为了编码。打包脚本应加 UTF-8 校验（仅防止未来脚本写坏）。
6. 设置侧：IP 字段（默认 `192.168.43.1`）+ 协议选择（`auto`/`EYLink`，ZxDash 先编译不露出）+ 画面规格（`auto`→800×480、可手动 800×480 / 960×480 / 1280×720），全部走现有 `ChoiceMenu` + `UserDefaults` 模式；改画面尺寸需重启 CarPlay，页面注明。
7. `Info.plist` **不需要新增 key**：`NSLocalNetworkUsageDescription`（`App/Info.plist:41`）和 `NSAppTransportSecurity/NSAllowsLocalNetworking`（`App/Info.plist:27-29`）已覆盖直连 IP 场景；没有 Bonjour 发现就不加 `NSBonjourServices`。版本继续 `1.0.6 (18)`，实车验证通过再谈 bump。
8. `Tools/generate_project.py` **无需改动**：它自动 glob `App/*.swift` 与 `Sources/TDSCarKitCore/**/*.swift`（`Tools/generate_project.py` 源文件发现逻辑），新增/删除文件后本地跑一次生成器、把重新生成的 `TDSCarKit.xcodeproj/project.pbxproj` 一起提交即可；CI 每次构建前都会重跑生成器，所以即使漏提交 pbxproj，CI 也能过（但本地 Xcode 会红）。
9. 构建/打包沿用现有 workflow（`.github/workflows/build-ipa.yml` → artifact `CarWithin-unsigned-ipa` + `build-log`），再按 `dist/CarWithin-ZXMOTO-500RR-1.0.6-ZXMOTO/` 的 shape 做 `dist/ZXMOTO-820R-1.0.6-<sha7>/`：`BUILD-INFO.md`、`README-FIRST.md`、`TEST-CHECKLIST.md`、`SHA256SUMS.txt`、`changes-against-upstream-1.0.6.diff`、`source-<sha>.zip`、unsigned IPA、identity IPA（`tmp/embed_identity.py`）。把 `embed_identity.py` 从 gitignore 的 `tmp/` 移到 `Tools/` 才可复现。
10. 第三方 500RR fork（`_research/zx500rr-src`）只借三个点子：`gateway(for:)` 自动补 `.1`、首包解析画面尺寸（JSON + 小端 u16 兜底）、日志里 hex+text 预览；它的握手是**空的**（文档明说“真实握手报文尚未抓到”），不要当作协议依据。

---

## 1. 目标、范围与约束

### 1.1 目标

- 为 ZXMOTO **820R**（先按 5 寸 800×480、30 FPS、4 Mbps 处理，画面规格可在设置里选）提供一个与上游输出体系一致的投屏输出。
- 同时保留 500RR 菜单项（已经存在），二者共享实现、按 model 取默认参数。
- 连接层必须能换：候选 A（官方 EYLink/EryaNet，主候选）与候选 B（ZxDash，第三方 1.0.9 参考）在 RE 完成前不阻塞主架构落地。
- 输出随 CarPlay 会话生命周期起停，行为与九号/春风/台铃等已有输出一致。

### 1.2 硬约束

- 只改 `App/`、`Sources/TDSCarKitCore/`、`Tests/`、`Tools/`、`docs/`、`.github/`；不碰 `ThirdParty/`、`Legacy62Original/`。
- 本地无 macOS/Xcode；**所有 Swift 改动必须以 CI 编译为最终门禁**，本地方案必须能靠静态检查发现大部分低级错误。
- 不修改上游已有输出的行为；新增代码不能改变现有持久化 enum 的 rawValue。
- 身份文件（`certificate.p7b` / `leaf.cer` / `private.x963`）绝不入库（`.gitignore` 已覆盖 `App/BundledIdentity/`、`*.p7b`、`*.cer`、`*.x963`）。
- 不把 `_research/`（RE 产物、反编译、APK）提交进仓库。

---

## 2. 当前仓库现状（实现前必读）

### 2.1 已经存在的 ZXMOTO 链路（前一轮补丁，全部已验证可编译并出过 IPA）

| 位置 | 现状 |
|---|---|
| `App/EylinkOutput.swift`（**776 行**，HEAD `6f27771`） | 单文件包含 `EylinkProfile`（16-53）、`EylinkPacket`（56-95）、`EylinkOutput`（100-131）、`Session`（133-776）。EYLink wire（**TCP 11111 主通道 + UDP 11111 仅 BLE 回退、控制 TCP 11113、`OK` 13 字节协商、`MIRROR_START` 重试、`AA BB ?? 0F` ACK/心跳 + 12 s 超时、Annex-B→VideoToolbox 解码→letterbox→重编码，全部小端**）全在这一个文件里。最终会被拆成 4 个新文件。 |
| `App/ReceiverConfiguration.swift` | `eylinkAddress` / `eylinkProfile` 在 46-50 行；IPv4 校验 198-204 行（拒绝 `.0`/`.255`/回环/组播，报错文案在 204 行“请输入 ZXMOTO 仪表真实的 IPv4 地址……”）。 |
| `App/NativeReceiver.swift` | 实例与回调 70-71 行；`start()` 里启动块 185-191 行；`stopOnQueue()` 里 `eylink.stop()` 417 行；`media.onVideo` 里 `append` 525-527 行；`onVideo` 闭包整体 502-559 行。 |
| `App/ReceiverViewController.swift` | 字段 228-243；`HeadUnitOutput` 枚举 294-360（`.zxmoto500rr` raw 28、`.zxmoto820r` raw 29，`menuOrder` 298，标题 315-316，`eylink` 358，`usesInstrumentWiFi` 359）；`planDisplay` 999-1003；`configureDisplay` 1359-1361；状态回调 `onEylinkState` 811-813；连接卡 644-651；卡可见性 1282-1284；设置页 case 3155-3159；画面页 2767-2772；品牌分组 2276；地址字段 2372-2374；保存 2428；启动状态 3220；字段启用 2071；`saveHeadUnitOutput` 2422-2433；`headUnitOutputChanged` 2506-2515。 |
| `App/Info.plist` | 版本 1.0.6 (18) 在 17/19 行；本地网络/ATS 27-41 行已齐。 |
| `.github/workflows/build-ipa.yml` | `macos-15` 上 `generate_project.py` → `xcodebuild Release`（无签名）→ `Payload/TDSCarKit.app` → `CarWithin-unsigned.ipa` → artifact。 |
| `Tools/generate_project.py` | 自动 glob 源文件，新文件零配置进入 app target；CI 构建前重跑。 |
| `dist/CarWithin-ZXMOTO-500RR-1.0.6-ZXMOTO/` | 上次成功 IPA 包（`4,013,006` bytes unsigned / `4,014,434` bytes with-identity；BUILD-INFO 记录 run `46014518045`、`BUILD SUCCEEDED`、arm64、iOS 16.0）。 |
| `docs/ZXMOTO-EYLINK-PROTOCOL.md` | **权威线协议文档**（92 行，官方 Android 1.4.5 `com.zxjc` / `com.eryanet.ite` 反编译）：端口、小端帧格式、OK/ACK/控制通道、追帧逻辑、待实车确认项。 |

### 2.2 编码（乱码）结论：**不存在需要修的乱码**

用“只输出 ASCII”的字节探针复核（绕开 Windows 控制台编码）：

- `App/EylinkOutput.swift` 34,413 bytes，UTF-8 解码成功；中文码点是真中文（如 `张雪` = `e5bca0 e99baa`，`仪表` = `e4bbaae8a1a8`）。
- `dist/.../BUILD-INFO.md` 首行码点 `0x23 0x20 0x6784 0x5efa 0x4fe1 0x606f` = “# 构建信息”；`gbk-encode → utf8-decode` 往返 `differs=False`（即不是“二次编码乱码”）。
- `TEST-CHECKLIST.md`、`README-FIRST.md`、`ZXMOTO-500RR.md`、`docs/首驱仪表适配-20261127.md` 同样通过；全 `App/*.swift` 对 `瀹/銆/锛` 等典型 mojibake 字符扫描为 0 命中。
- 之前观察到的乱码是 PowerShell 控制台默认 GBK/codepage 与管道 UTF-8 解码不一致造成的显示假象（`Get-Content` 输出里“张雪”也会显示成“寮犻洩”）。
- `tmp/EylinkOutput.decoded.swift` 是抽取工件（CRLF 双写 `0d0d`），**不要**拿它当源码；`tmp/` 已被 `.gitignore` 忽略。

**结论：重写 `EylinkOutput.swift` 的目的是拆架构（协议可换），不是修编码。** 重写时照抄现有中文文案（它们是对的），只在最后做一次 UTF-8 校验防止新写的脚本弄坏。

### 2.3 候选协议状态（2026-11-28 更新）

> 权威来源已入库：`docs/ZXMOTO-EYLINK-PROTOCOL.md`（官方 Android 1.4.5 反编译，92 行）。`App/EylinkOutput.swift` 已按它修正（commit `a419721` 小端 / TCP 11111 主通道 / 控制 11113；`6f27771` ACK 前缀 `AA BB CC 0F` + 12 s 未连接提示）。并行 RE Agent 还在产出 `docs/zxdash-protocol.md`（第三方 ZXMOTO 1.0.9 IPA：`ZxDashPacket`/`ZxDashPacketizer`/`EylinkOutput.Session`）与 `docs/eymirror-protocol.md`（官方 iOS ReplayKit `MotorMirror.appex`：`EYMirrorConfiguration`/`EYMirrorTCPHeaderData`/`parsingReadHeader`），**三份文档交叉验证后再锁协议**。

| 候选 | 现状 | 用途 / 风险 |
|---|---|---|
| **EYLink / EryaNet（官方 Android，主候选）** | 已入库且已被实现：镜像 **TCP 11111 主通道**（UDP 11111 仅 BLE 老设备回退），控制 **TCP 11113**；12 字节头 `AA BB CC func 00 00 00 00 <LE32 len>`；`func=0` 视频（`LE32 时间戳ms + Annex-B`）、`func=4` MIRROR_START（`LE16 min + LE16 max`）、`func=5` MIRROR_STOP、`func=6` WIDTH_HEIGHT；`OK` 13 字节画面参数（LE16 尺寸×4 + fps u8 + LE16 kbps）；`AA BB ?? 0F` ACK/心跳（LE32 len + JSON `ver`/`ack`/`timestamp`，12 s 超时）；控制帧 `'E','Y' + BE32 jsonLen + BE32 extraLen + JSON`。**长度/时间戳/尺寸全部小端**；旧实现用大端是错的。 | 主候选。剩余未知见该文档 §7：热点密码 / 是否必须先 BLE 配对、820R 实际回包尺寸。 |
| **ZxDash（第三方参考实现，备用）** | 第三方 ZXMOTO CarWithin 1.0.9 IPA 的 `ZxDashPacket`（`videoPort`/`dataPort`、`hello()`、`frame(type:flag:payload:)`、`video(timestamp:nal:)`、`dataMessage`、`timeMessage`、`parseReply`）与 `ZxDashPacketizer`（分包规则/关键帧 NAL 切分）；帧头为 `LE32 type + flag + LE32 len`，与官方 Android EYLink **不是同一套**。 | 备用 transport + 交叉验证来源；RE 完成后填 `ZxmotoProtocol.ZxDash`，细节以 `docs/zxdash-protocol.md` 为准。 |
| **EYMirror（官方 iOS appex，对齐参考）** | 官方 iOS `MotorMirror.appex`（ObjC + Swift `EryaMirrorExtensionKit`、GCDAsyncSocket/UDP、`EYNH264VideoEncoder`）的 `EYMirrorConfiguration`（portraitWidth/Height、commandPort、dataPort、socketType）、`EYMirrorTCPHeaderData`/`UDPHeaderData`、`ParsingReadHeader`。代表官方 iPhone→仪表 封装，可能与 Android EYLink 同族但字段/端口默认值不同。 | 用于校验 EYLink 字段语义；除非发现实质差异，不单独再写一套 transport。以 `docs/eymirror-protocol.md` 为准。 |

**架构要求**：所有候选都只是 `ZxmotoTransport` 的实现；`ZxmotoProtocol.Eylink` 先按官方 Android 文档实现，`ZxmotoProtocol.ZxDash`/`ZxmotoProtocol.EyMirror` 作为可选编译分支（测试通过后再在 UI 露出）。主流程、UI、持久化、生命周期在协议确认前就能落地并被 CI 编译。

---

## 3. 上游输出架构分析（选型依据）

| 输出族 | 结构 | 对本任务的参考价值 |
|---|---|---|
| `ShouquConnection.swift` + `ShouquProtocol.swift` | Protocol 纯字节（无 Networking import）；Connection 用 `TailingSocket` 同步握手，`func start() throws -> (Int, Int)` 返回协商尺寸；`MotorcycleOutput` 的 Session 持有 conn 并调 `checkHealth/send/close`。 | **最接近目标**：协议/连接分离、`start() -> (Int,Int)` 的契约。 |
| `YunmoConnection.swift` + `YunmoProtocol.swift` | `YunmoProtocol` 是纯 codec（`simple`/`jpeg`/`read`/`dimensions`/`ack`）；Connection 持 `NSCondition`，`func start(local:target:) throws -> (Int, Int)`，收包循环维护 size/ack/error。 | 同上的“纯协议 + 连接对象”范本；JPEG 路径不适用，但握手/协商/线程模型可复制。 |
| `MotorcycleOutput.swift` + `MotorcycleProfile.swift` | `MotorcycleProfile` 是纯数据 enum（title/width/height/fps/detail/instructions/transport）；`MotorcycleOutput.Session` 按 `profile.transport` 实例化一个 transport 对象，统一 decode→scale→encode→send；H.264/JPEG 二选一。 | **选它作为主结构**：一个输出类 + 一个按配置选择的传输对象，正好满足“协议可换”。 |
| `CfmotoOutput.swift` + `CfmotoProfile` | `CfmotoProfile` 带 `width/height/fps/bitrate/label` 与 `encodeWidth/encodeHeight`；Session 带重连、按协商值重建 encoder、`report` 状态去重。 | Profile 数值/clamp/状态文案可直接复用；重连逻辑按需吸取。 |
| `TailingDisplayProfile.swift` | 枚举 `InstrumentFrameSize`、per-device `outputSize(for reported:) -> InstrumentFrameSize?` 的“上报尺寸→输出尺寸”策略、`fps/bitrate/canvas` 选项。 | **几何可覆盖/协商策略**的范本：`ZxmotoProfile.Geometry` + `effectiveSize(reported:)` 照这个思路写。 |
| `NinebotH264Encoder.swift`（`struct H264EncodedFrame`、`final class H264Encoder`） | VideoToolbox 封装：BGRA、RealTime、Baseline AutoLevel、`MaxKeyFrameInterval = fps`、`DataRateLimits 1.5×bitrate`、AVCC→Annex-B、关键帧带 SPS/PPS。 | **直接复用**，不重写编码器。 |
| `TailingH264Decoder.swift` + `VideoParameterSets`/`AnnexB`（Sources/TDSCarKitCore） | 解 CarPlay H.264、SPS/PPS 吸收、IDR 等待。 | **直接复用**，不重写解码器。 |

**选型结论**：`ZxmotoOutput` = `MotorcycleOutput` 的 Session/转码流水线 + `CfmotoOutput` 的 profile 数值风格 + `TailingDisplayProfile` 的尺寸策略；传输用 `ZxmotoConnection` 收口，协议用 `ZxmotoProtocol` 收口。这样既贴合上游 conventions，又把“换协议”限制在一个文件里。

---

## 4. 目标架构

### 4.1 组件与数据流

```
CarPlay RTSP/Video  ── NativeReceiver.media.onVideo(data:codec:)
                              │  (仅 codec == .h264 时)
                              ▼
                       ZxmotoOutput.append(data, codec:, keyframe:)
                              │  (私有串行 queue)
                              ▼
                  Session: AnnexB 拆包 → VideoParameterSets → TailingH264Decoder
                              │  (最新 CVPixelBuffer)
                              ▼
                  encodeLoop（墙上时钟按 fps 节拍，丢旧帧/背压）
                              │  fittedImage（CIImage letterbox 到 encodeW×encodeH）
                              ▼
                  H264Encoder（NinebotH264Encoder）→ Annex-B H.264
                              │
                              ▼
                  ZxmotoConnection.send(videoFrame)
                     ├── EylinkTransport   （现在：TCP 11111 主 / UDP 11111 回退 / 控制 11113，小端）
                     └── ZxDashTransport   （RE 确认后填握手；暂空实现）
```

- `NativeReceiver` 对输出只做三件事：`start(...)`、`append(...)`、`stop()`（与现在完全一致）。
- `ZxmotoConnection` 负责“连线 + 握手 + 协商尺寸 + 发送”，通过回调 `onNegotiated(size:fps:bitrate:)` 把仪表屏幕参数告诉 `ZxmotoOutput`；输出在该尺寸变化时重建 encoder（与 `CfmotoOutput` 协商后重建的逻辑相同）。
- 会话生命周期：输出连接在 CarPlay 开始（`NativeReceiver.start`）时建立，CarPlay 停止（`ReceiverViewController` 里 `receiver.stop()` → `stopOnQueue()`）时关闭；CarPlay 会话中途的 RTSP TEARDOWN 不会重连输出（与现有输出一致），视频恢复由 `requestKeyframe` 处理。

### 4.2 文件地图（推荐最终形态）

| 文件（新增/删除） | 职责 | 依赖 |
|---|---|---|
| `Sources/TDSCarKitCore/ZxmotoProfile.swift`（新） | `ZxmotoProfile`、`Model`、`Geometry`、`ZxmotoWireMode`：纯数据与默认参数、用户几何覆盖、`effectiveSize(reported:)` 策略。 | Foundation |
| `Sources/TDSCarKitCore/ZxmotoProtocol.swift`（新） | `ZxmotoProtocol.Eylink`（12 字节包、OK 包解析、心跳时间戳）与 `ZxmotoProtocol.ZxDash`（占位常量/握手，RE 后填）；纯字节、无 `Network`/`VideoToolbox`。 | Foundation |
| `App/ZxmotoConnection.swift`（新） | `protocol ZxmotoTransport`、`final class ZxmotoConnection`（按 `ZxmotoWireMode` 造 transport、统一状态/日志/错误回调）、`EylinkTransport`、`ZxDashTransport`（空壳）。 | Network, Foundation |
| `App/ZxmotoOutput.swift`（新） | `final class ZxmotoOutput` + `Session`：转码流水线、节拍、背压、关键帧恢复、状态去重。 | CoreImage, Foundation, VideoToolbox + 上述类型 |
| `App/EylinkOutput.swift`（删除） | 旧单文件实现；删除前把详细实现搬进上面四个文件。 | — |
| `Tests/TDSCarKitCoreTests/ZxmotoProtocolTests.swift`（新，推荐） | 纯字节黄金向量：MIRROR_START/VIDEO/OK/心跳解析；ZxDash 占位测试（待 RE 后补）。 | XCTest, TDSCarKitCore |
| `Tools/validate_zxmoto_release.py`（新，推荐） | 无 Mac 的发布前静态校验（见 §15）。 | Python 3 |
| `Tools/embed_identity.py` / `Tools/package_dist.py`（新，推荐） | 从 `tmp/` 移出身份嵌入脚本并固化 dist 组装；`tmp/` 是 gitignore。 | Python 3 |
| `docs/zxmoto-820r-integration.md`（新，推荐） | 面向用户/维护者的协议状态、验证记录、测试清单。 | — |

> **为什么协议/Profile 放 `Sources/TDSCarKitCore`**：`generate_project.py` 同时把 `Sources/TDSCarKitCore/**/*.swift` 编进 App target，因此 App 代码可直接使用、无需 import；同时 `Tests/TDSCarKitCoreTests` 可以 `@testable import TDSCarKitCore` 跑纯字节测试（CI 可加 `swift test`）。如果你更想严格贴上游 conventions，也可放 `App/ZxmotoProfile.swift` / `App/ZxmotoProtocol.swift`——生成器同样自动收录、CI 同样能过，但就无法用现有 XCTest target 单测。**推荐 Core 方案**，文件命名保持 `Zxmoto*` 前缀不变。

### 4.3 可换协议契约（`ZxmotoTransport`）

```swift
// App/ZxmotoConnection.swift
import Foundation

/// 一种 ZXMOTO 线上协议的传输实现：只做“连接 + 握手 + 收发包”，不做编解码。
protocol ZxmotoTransport: AnyObject {
    var name: String { get }
    /// 协议是否需要发送方给出毫秒时间戳（EYLink 需要，ZxDash 待定）。
    var needsTimestamp: Bool { get }

    /// 异步建立连接并完成握手/协商；结果通过 onNegotiated 回调给出。
    /// - Parameters:
    ///   - localAddress: iPhone 当前 Wi-Fi 地址（绑定 `.wifi` 接口；UDP 回退时必须绑本地地址，不能 0.0.0.0）。
    ///   - targetAddress: 仪表 IP（默认 192.168.43.1）。
    func start(localAddress: String?, targetAddress: String)
    /// 心跳/连接健康检查；失败时抛错，由 Connection 决定是否重连。
    func checkHealth() throws
    /// 发送一帧 H.264（Annex-B）。实现负责协议封装与时间戳。
    func send(videoFrame: Data) throws
    /// 关闭所有 socket/定时器，幂等。
    func close()
}
```

`ZxmotoConnection` 是 `ZxmotoOutput` 唯一认识的连接类型：

```swift
final class ZxmotoConnection: @unchecked Sendable {
    struct Callbacks {
        var onState: (String) -> Void          // 给 UI 的状态文案（主线程回调）
        var onLog: (String) -> Void            // 给日志面板
        var onNegotiated: (ZxmotoNegotiation) -> Void  // 仪表上报的画面参数
        var requestKeyframe: () -> Void        // 解码/发送异常时请求 CarPlay 关键帧
    }

    init(mode: ZxmotoWireMode, queue: DispatchQueue, callbacks: Callbacks)
    func start(localAddress: String?, targetAddress: String)
    func checkHealth() throws
    func send(videoFrame: Data) throws
    func close()
}

struct ZxmotoNegotiation: Equatable {       // 也可直接复用 ZxmotoProtocol.Eylink.Negotiation
    let width: Int
    let height: Int
    let fps: Int
    let bitrateKbps: Int
}
```

**换协议 = 新增一个 `ZxmotoTransport` 实现 + 在 `ZxmotoConnection` 的工厂里加一行 case**；`ZxmotoOutput`、`NativeReceiver`、`ReceiverViewController` 一律不动。选择逻辑：

```swift
enum ZxmotoWireMode: Int, CaseIterable, Sendable {
    case auto = 0     // 先试 EYLink；ZxDash 落地后按失败回退
    case eyLink = 1
    case zxDash = 2   // 先编译保留，UI 暂不露出（RE 未确认）

    var title: String {
        switch self {
        case .auto:   return CWL("自动")
        case .eyLink: return "EYLink"
        case .zxDash: return "ZxDash"
        }
    }
}
```

工厂（`ZxmotoConnection.init` 内）：

```swift
private static func makeTransport(mode: ZxmotoWireMode,
                                  localAddress: String?,
                                  targetAddress: String,
                                  callbacks: Callbacks) -> ZxmotoTransport {
    switch mode {
    case .eyLink:
        return EylinkTransport(localAddress: localAddress, targetAddress: targetAddress, callbacks: callbacks)
    case .zxDash, .auto:
        // .auto 在 ZxDash 未实现前等价于 EYLink；实现后改为“先 ZxDash，失败回退 EYLink”。
        return EylinkTransport(localAddress: localAddress, targetAddress: targetAddress, callbacks: callbacks)
    }
}
```

---

## 5. Files-by-file 改动清单

> 行号以当前工作区 `6f27771` 为准；实现时以符号名搜索，而不是死记行号。

### 5.1 新增 `Sources/TDSCarKitCore/ZxmotoProfile.swift`

```swift
import Foundation

/// 张雪 ZXMOTO 仪表输出规格（纯数据：不联网、不解码、不依赖 UIKit/VideoToolbox）。
/// 820R 先按 5 寸 800×480 处理；仪表若在上报里给出其它尺寸，`Geometry.auto` 时以仪表为准。
struct ZxmotoProfile: Equatable, Sendable {
    enum Model: Int, CaseIterable, Sendable {
        case fiveInch500RR = 0
        case fiveInch820R = 1

        var label: String {
            switch self {
            case .fiveInch500RR: return CWL("张雪 500RR 5 寸")
            case .fiveInch820R: return CWL("张雪 820R 5 寸")
            }
        }
    }

    /// 可选画面规格。`.auto` 表示“沿用仪表上报尺寸”，其余是用户强制的输出尺寸。
    enum Geometry: Int, CaseIterable, Sendable {
        case auto = 0
        case w800h480 = 1
        case w960h480 = 2
        case w1280h720 = 3

        var size: (width: Int, height: Int)? {
            switch self {
            case .auto:      return nil
            case .w800h480:  return (800, 480)
            case .w960h480:  return (960, 480)
            case .w1280h720: return (1280, 720)
            }
        }

        var title: String {
            switch self {
            case .auto:      return CWL("自动（仪表上报）")
            case .w800h480:  return "800×480"
            case .w960h480:  return "960×480"
            case .w1280h720: return "1280×720"
            }
        }
    }

    let model: Model
    let geometry: Geometry
    let fps: Int          // 默认 30；有效范围 20...60
    let bitrate: Int      // bps，默认 4_000_000

    static let fiveInch500RR = ZxmotoProfile(model: .fiveInch500RR, geometry: .auto,
                                             fps: 30, bitrate: 4_000_000)
    static let fiveInch820R = ZxmotoProfile(model: .fiveInch820R, geometry: .auto,
                                            fps: 30, bitrate: 4_000_000)

    /// 用户设置里选择的 geometry/fps/bitrate 覆盖默认值后的 profile。
    static func make(model: Model, geometry: Geometry, fps: Int = 30, bitrate: Int = 4_000_000) -> ZxmotoProfile {
        ZxmotoProfile(model: model, geometry: geometry,
                      fps: min(max(fps, 20), 60), bitrate: min(max(bitrate, 1_000_000), 12_000_000))
    }

    var defaultWidth: Int { 800 }
    var defaultHeight: Int { 480 }
    var requestedWidth: Int { geometry.size?.width ?? defaultWidth }
    var requestedHeight: Int { geometry.size?.height ?? defaultHeight }

    var encodeWidth: Int { requestedWidth - requestedWidth % 2 }        // H.264 需要偶数宽
    var encodeHeight: Int { requestedHeight % 2 == 0 ? requestedHeight : requestedHeight + 1 }

    var label: String { model == .fiveInch500RR ? CWL("张雪 500RR 5 寸") : CWL("张雪 820R 5 寸") }
    var title: String { "\(label) · \(geometry.title)" }
    var encodeTitle: String { "\(encodeWidth)×\(encodeHeight) · H.264 · \(fps) FPS" }

    /// 仪表上报尺寸 → 实际输出尺寸。
    /// `.auto`：采用上报值（clamp 到 320...2560 × 240...1600，并偶数化）；上报缺失用默认 800×480。
    /// 用户强制尺寸：用用户值，忽略上报值。
    func effectiveSize(reported: (width: Int, height: Int)?) -> (width: Int, height: Int, fps: Int) {
        if let override = geometry.size {
            return (override.width - override.width % 2,
                    override.height % 2 == 0 ? override.height : override.height + 1,
                    fps)
        }
        guard let reported else {
            return (encodeWidth, encodeHeight, fps)
        }
        let w = min(max(reported.width, 320), 2560)
        let h = min(max(reported.height, 240), 1600)
        return (w - w % 2, h % 2 == 0 ? h : h + 1, fps)
    }
}
```

要点：
- `CWL()` 在 Core 模块里可用（`Sources/TDSCarKitCore/Localization.swift` 已存在）。
- 500RR/820R **共享同一个结构**；以后若 820R 实车是 7 寸，只改 `Geometry` 选项/默认值，不动输出代码。
- 尺寸语义：`requestedWidth/Height` 用于 `MIRROR_START` 初始请求与 CarPlay 流渲染尺寸；`effectiveSize` 用于协商后的实际输出（两者不同时由 `fittedImage` letterbox 补齐）。

### 5.2 新增 `Sources/TDSCarKitCore/ZxmotoProtocol.swift`

纯字节，不 import `Network`/`VideoToolbox`；所有实现照抄现有 `EylinkPacket` + `handleOK` + 心跳解析逻辑（`App/EylinkOutput.swift:37-76` 与 `Session.handleOK` 附近），只是搬进 enum 并补 `Data` 安全解析（越界返回 nil，不允许先 `dropFirst` 再假设长度）。

```swift
import Foundation

/// ZXMOTO 仪表线协议编解码（纯字节，可单测）。
enum ZxmotoProtocol {
    /// 候选 B：EYLink / EYMirror（当前实现使用）。
    enum Eylink {
        static let headerSize = 12
        static let videoFunction: UInt8 = 0
        static let mirrorStartFunction: UInt8 = 4
        static let mirrorStopFunction: UInt8 = 5
        static let maximumPayload = 2 * 1024 * 1024

        struct Negotiation: Equatable {
            let width: Int        // landscape 宽
            let height: Int
            let fps: Int
            let bitrateKbps: Int
        }

        /// AA BB CC func 00 00 00 00 <LE32 payloadLen> <payload>
        static func packet(function: UInt8, payload: Data = Data()) -> Data {
            var data = Data([0xAA, 0xBB, 0xCC, function, 0, 0, 0, 0])
            data.appendLE32(UInt32(payload.count))
            data.append(payload)
            return data
        }

        /// payload = LE16 min(w,h) + LE16 max(w,h)
        static func mirrorStart(width: Int, height: Int) -> Data {
            var payload = Data()
            payload.appendLE16(UInt16(clamping: min(width, height)))
            payload.appendLE16(UInt16(clamping: max(width, height)))
            return packet(function: mirrorStartFunction, payload: payload)
        }

        static var mirrorStop: Data { packet(function: mirrorStopFunction) }

        /// payload = LE32 时间戳（毫秒）+ Annex-B H.264
        static func video(_ frame: Data, timestampMilliseconds: UInt32) -> Data {
            var payload = Data()
            payload.appendLE32(timestampMilliseconds)
            payload.append(frame)
            return packet(function: videoFunction, payload: payload)
        }

        /// 13 字节 OK 包：'O''K' + portraitW LE16 + portraitH LE16 +
        /// landscapeW LE16 + landscapeH LE16 + fps u8 + bitrateKbps LE16。
        /// 取 landscape 尺寸；bitrate = kbps * 1000。
        static func parseOK(_ data: Data) -> Negotiation? {
            guard data.count == 13, data[0] == 0x4F, data[1] == 0x4B else { return nil }
            let width = Int(data.u16LE(at: 6))
            let height = Int(data.u16LE(at: 8))
            guard width >= 240, height >= 240 else { return nil }
            let fps = Int(data[10].clampedFPS)   // 0/异常值 → 30
            let kbps = Int(data.u16LE(at: 11))
            return Negotiation(width: width, height: height, fps: fps,
                               bitrateKbps: kbps > 0 ? kbps : 4000)
        }

        /// 从缓冲区解出一个完整帧：返回 (function, payload, consumedBytes)，不足返回 nil。
        static func nextFrame(in buffer: Data) -> (function: UInt8, payload: Data, consumed: Int)? { ... }

        static func heartbeatTimestamp(_ payload: Data) -> UInt32? {
            // 心跳 payload 是 JSON；容忍非 JSON 时返回 nil（仅日志用）
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
            return (object["timestamp"] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) }
        }
    }

    /// 候选 A：ZxDash（第三方 1.0.9 参考实现；RE 进行中，细节以 `docs/zxdash-protocol.md` 为准）。
    /// 对应符号：`ZxDashPacket.videoPort/dataPort/hello()/frame(type:flag:payload:)/
    /// video(timestamp:nal:)/dataMessage/timeMessage/parseReply`、`ZxDashPacketizer.packets/resetConnection`。
    enum ZxDash {
        static let defaultPort: UInt16 = 11111      // 占位；以 RE 文档的 videoPort 为准
        /// RE 完成后填：`ZxDashPacket.hello()` 的字节。
        static let handshake = Data()
        /// RE 完成后填：`ZxDashPacket.parseReply` 的参数（宽/高/fps/码率）。
        static func parseMediaSize(_ data: Data) -> (width: Int, height: Int, fps: Int)? { nil }
        /// RE 完成后填：`ZxDashPacket.video(timestamp:nal:)` / `ZxDashPacketizer.packets` 的分包结果。
        static func video(_ frame: Data, timestampMilliseconds: UInt32) -> Data { frame }
    }
}

extension Data {
    mutating func appendLE16(_ value: UInt16) { ... }   // 小端
    mutating func appendLE32(_ value: UInt32) { ... }   // 小端
    func u16LE(at index: Int) -> UInt16 { ... }         // 越界安全
}
```

注意：
- 现有 `EylinkPacket` 的 `appendUInt16/appendUInt32` 是 `static func`，可直接搬成 `Data` 扩展；如果 `Sources/TDSCarKitCore` 已有同名扩展（检查 `Binary.swift`），改为 `private` 前缀或复用现有 helper，避免重复符号。
- `Data` 越界访问在 Swift 会崩，`ZxmotoProtocol` 的所有解析必须先判 `count`，这是无 Mac 环境下最容易靠 review 抓到的点。

### 5.3 新增 `App/ZxmotoConnection.swift`

把 `App/EylinkOutput.swift` 中 `Session` 的网络部分原样搬入 `EylinkTransport`：

- 连接参数：**TCP 11111 为主通道**（`NWParameters.tcp`，`noDelay`、keepalive、`requiredInterfaceType = .wifi`），`OK` 协商完成后按需保留；UDP 11111 仅作为 BLE 老设备回退（暂不实现）。控制通道 TCP 11113 独立连接、只读日志。所有尺寸/长度/时间戳按**小端**编解码。
- 状态机：`tcpConnecting → negotiating（MIRROR_START 重发）→ streaming`；连接失败/超时先重试，`OK` 到达后停重发并 `onNegotiated`。
- 发送：`MIRROR_START` 每 500–1000 ms 重发，最多约 15–30 次；`OK` 到达后先单独发 SPS、PPS 帧，再逐帧发视频；`checkHealth()` 检查连接状态 + 心跳 12 s 超时。
- 背压/丢帧策略留在 `ZxmotoOutput`（不是 transport 职责）。
- 迁移时**不要改**协议细节（12 字节头、OK 13 字节、MIRROR_START payload 顺序、时间戳毫秒、控制帧 `EY` JSON），这些是唯一的现存实现资产。

`ZxmotoConnection` 本身：

```swift
final class ZxmotoConnection: @unchecked Sendable {
    struct Callbacks {
        var onState: (String) -> Void
        var onLog: (String) -> Void
        var onNegotiated: (ZxmotoNegotiation) -> Void
        var requestKeyframe: () -> Void
    }

    private let queue: DispatchQueue
    private let mode: ZxmotoWireMode
    private let callbacks: Callbacks
    private let localAddress: String?
    private let targetAddress: String
    private var transport: ZxmotoTransport?

    init(mode: ZxmotoWireMode, queue: DispatchQueue, localAddress: String?,
         targetAddress: String, callbacks: Callbacks) { ... }

    func start() {
        let transport = Self.makeTransport(mode: mode, localAddress: localAddress,
                                           targetAddress: targetAddress, callbacks: callbacks)
        self.transport = transport
        callbacks.onState(CWL("正在连接 ZXMOTO 仪表…"))
        transport.start(localAddress: localAddress, targetAddress: targetAddress)
    }
    func checkHealth() throws { try transport?.checkHealth() }
    func send(videoFrame: Data) throws { try transport?.send(videoFrame: videoFrame) }
    func close() { transport?.close(); transport = nil }
}
```

`EylinkTransport` 可以暂时把 `Session` 里的 NWConnection 代码整体搬过来（保留 `@unchecked Sendable` + `NSLock`），把 `onState/onLog/requestKeyframe/encoded` 改成 `Callbacks`。RE 完成后新增 `ZxDashTransport`，其余零改动。

### 5.4 新增 `App/ZxmotoOutput.swift`

`ZxmotoOutput` 的公开 API 必须与 `EylinkOutput` 完全对齐（这样 `NativeReceiver` 只换类型名）：

```swift
import CoreImage
import Foundation
import VideoToolbox

final class ZxmotoOutput {
    private let queue: DispatchQueue
    private var session: Session?

    init(name: String = "zxmoto") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
    }
    deinit { stop() }

    func start(localAddress: String?, targetAddress: String, profile: ZxmotoProfile,
               wireMode: ZxmotoWireMode,
               onState: @escaping (String) -> Void,
               onLog: @escaping (String) -> Void,
               requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress,
                           profile: profile, wireMode: wireMode,
                           onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    private final class Session: @unchecked Sendable {
        // 从 EylinkOutput.Session 原样迁移：
        // - 解码：AnnexB 拆包 + VideoParameterSets + TailingH264Decoder
        // - 编码：NinebotH264Encoder 的 H264Encoder，尺寸/fps/bitrate 来自 negotiated 或 profile
        // - letterbox：CIImage scale + 黑边合成（fittedImage）
        // - 节拍：DispatchSourceTimer 或墙上时钟 loop，按 fps 取 latest 帧
        // - 背压：inFlight 上限（≈10）超过时丢帧并 requestKeyframe
        // - 恢复：解码/编码失败 → invalidate + 等 IDR + requestKeyframe
        // - 文案：状态去重 report(...)，中文与现有 EylinkOutput 保持一致
    }
}
```

实现迁移策略：先机械迁移（保持行为不变）→ 再拆 `ZxmotoConnection`。CI 每次只小步验证，避免一次大 diff 排查困难。

### 5.5 删除 `App/EylinkOutput.swift`

- 前一轮的所有 `Eylink*` 类型将被 `Zxmoto*` 取代。
- 删除后 `grep -rn "EylinkOutput\|EylinkProfile" App/ Sources/ Tests/` 必须为 0；`Eylink` 作为协议名允许出现在 `ZxmotoProtocol.Eylink` 和用户文案里。
- `project.pbxproj` 由生成器重算，删文件不需要手改工程文件；本地跑一次 `python Tools/generate_project.py` 并提交生成结果（见 §14）。
- 旧实现的最终版本留在 git 历史（`6f27771:App/EylinkOutput.swift`）；`6704a30` 版本是大端/UDP 优先的错误线协议，只作历史参考，不要复制。不要保留 `tmp/EylinkOutput.decoded.swift` 在仓库里（`tmp/` 本来就被 ignore）。

### 5.6 `App/ReceiverConfiguration.swift`

当前（40-56 行）：

```swift
var cfmotoProfile: CfmotoProfile?
var motorcycleProfile: MotorcycleProfile?
...
/// ZXMOTO（EYLink / EryaNet）：手机加入仪表热点 `iteAP` 后直连 192.168.43.1，
/// EYLink（官方 Android 1.4.5）：镜像 TCP 11111 主通道（UDP 11111 仅 BLE 回退），控制 TCP 11113。
/// 留空默认 192.168.43.1。
var eylinkAddress: String?
var eylinkProfile: EylinkProfile?
```

改为：

```swift
/// ZXMOTO（张雪 500RR / 820R）：手机加入仪表热点（iteAP / iteAP-…）后直连仪表。
/// 默认网关 192.168.43.1；EYLink 镜像 TCP 11111（UDP 11111 仅 BLE 回退），控制 TCP 11113，全部小端。
/// 留空使用默认网关。
var zxmotoAddress: String?
var zxmotoProfile: ZxmotoProfile?
var zxmotoWireMode: ZxmotoWireMode = .auto
```

`validate()` 现有 198-206 行整块改名（逻辑不变）：

```swift
if let zxmotoAddress, !zxmotoAddress.isEmpty {
    var target = in_addr()
    guard inet_pton(AF_INET, zxmotoAddress, &target) == 1, zxmotoAddress != address,
          !zxmotoAddress.hasPrefix("127."), !zxmotoAddress.hasPrefix("0."),
          !zxmotoAddress.hasPrefix("169.254."), UInt32(bigEndian: target.s_addr) < 0xe0000000,
          !zxmotoAddress.hasSuffix(".0"), !zxmotoAddress.hasSuffix(".255") else {
        throw ConfigurationError(CWL("请输入 ZXMOTO 仪表真实的 IPv4 地址（不能用 .0/.255），默认 192.168.43.1。"))
    }
}
```

其它：`eylinkProfile != nil` 用于判断“是否启用 ZXMOTO 输出”的地方改为 `zxmotoProfile != nil`（只有 `NativeReceiver` 和 `ReceiverViewController` 两处，见下）。

### 5.7 `App/NativeReceiver.swift`

1. 实例与回调（当前 70-71 行）：

```swift
private let zxmoto = ZxmotoOutput()
var onZxmotoState: ((String) -> Void)?
```

2. `start()` 里当前 185-191 行整块替换：

```swift
if let profile = configuration.zxmotoProfile {
    let target = configuration.zxmotoAddress.flatMap({ $0.isEmpty ? nil : $0 }) ?? "192.168.43.1"
    self.zxmoto.start(localAddress: configuration.address,
                      targetAddress: target,
                      profile: profile,
                      wireMode: configuration.zxmotoWireMode,
                      onState: { [weak self] in self?.onZxmotoState?($0) },
                      onLog: { [weak self] in self?.log($0) },
                      requestKeyframe: { [weak self] in self?.requestKeyFrame(reason: "ZXMOTO 解码恢复") })
}
```

3. `stopOnQueue()`（当前 417 行）：`eylink.stop()` → `zxmoto.stop()`。
4. `media.onVideo`（当前 525-527 行）：

```swift
if configuration.zxmotoProfile != nil {
    self.zxmoto.append(data, codec: codec, keyframe: keyframe)
}
```

> 生命周期无需新增回调：`start()` 在 `ReceiverViewController` 点击启动时调用，`stopOnQueue()` 在停止/失败路径调用。CarPlay RTSP 中途重连不会重建输出（现有所有输出都是这个行为），恢复靠 `requestKeyFrame`。

### 5.8 `App/ReceiverViewController.swift`（改动最多，逐个锚点列）

1. **输出枚举（294-360 行）**：两个 case 已经存在且顺序/rawValue 正确（28/29），**不要动** `case` 列表和 `menuOrder` 的相对顺序。只把 `var eylink` 改成 `var zxmoto`，新增 `var zxmotoProfile: ZxmotoProfile?`，`usesInstrumentWiFi` 跟随改名：

```swift
var zxmotoProfile: ZxmotoProfile? {
    switch self {
    case .zxmoto500rr: return .fiveInch500RR
    case .zxmoto820r: return .fiveInch820R
    default: return nil
    }
}
var zxmoto: Bool { zxmotoProfile != nil }
var usesInstrumentWiFi: Bool {
    motorcycleProfile != nil || cfmoto || zxmoto || self == .tailing
        || zeehoProfile != nil || ninebotMode != nil
}
```

2. **字段（228-243 行）**：`eylinkCard/eylinkCardStatus/eylinkStatus/eylinkAddressField/eylinkProfile/updateEylinkStatus` 全部改名为 `zxmoto*`；新增两个 ChoiceMenu：

```swift
private let zxmotoAddressField = UITextField()
private let zxmotoWireModeControl = ChoiceMenu(items: ZxmotoWireMode.allCases.map(\.title))
private let zxmotoGeometryControl = ChoiceMenu(items: ZxmotoProfile.Geometry.allCases.map(\.title))

private var zxmotoProfile: ZxmotoProfile? {
    guard let model = outputMode.zxmotoProfile?.model else { return nil }
    let geometry = ZxmotoProfile.Geometry(rawValue: zxmotoGeometryControl.selectedSegmentIndex) ?? .auto
    return ZxmotoProfile.make(model: model, geometry: geometry)
}
private var zxmotoWireMode: ZxmotoWireMode {
    ZxmotoWireMode(rawValue: zxmotoWireModeControl.selectedSegmentIndex) ?? .auto
}
private func updateZxmotoStatus(_ message: String) {
    zxmotoStatus.text = message
    zxmotoCardStatus.text = message
}
```

> 注意：`ChoiceMenu` 的 `selectedSegmentIndex`/`selectedTitle`/`.title` 用法见文件现有控件（如 `resolutionControl` 90 行、`zeehoAE4iFrameRateControl` 等），`ChoiceMenu(items:)` 初始化即可；中文标题通过 `CWL` 在 title 里已处理。

3. **默认值初始化**（`configureSettingsControls`，2265 行起；当前地址字段在 2372-2374、字段启用列表 2407 行含 `eylinkAddressField`）：

```swift
zxmotoAddressField.text = defaults.string(forKey: "zxmotoAddress")
    ?? defaults.string(forKey: "eylinkAddress") ?? "192.168.43.1"
zxmotoAddressField.keyboardType = .decimalPad
zxmotoAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
let savedWireMode = ZxmotoWireMode(rawValue: defaults.integer(forKey: "zxmotoWireMode")) ?? .auto
zxmotoWireModeControl.selectedSegmentIndex = savedWireMode.rawValue
zxmotoWireModeControl.addTarget(self, action: #selector(zxmotoSettingsChanged), for: .valueChanged)
let savedGeometry = ZxmotoProfile.Geometry(rawValue: defaults.integer(forKey: "zxmotoGeometry")) ?? .auto
zxmotoGeometryControl.selectedSegmentIndex = savedGeometry.rawValue
zxmotoGeometryControl.addTarget(self, action: #selector(zxmotoSettingsChanged), for: .valueChanged)
```

4. **保存**（`saveHeadUnitOutput` 2422-2433；当前 2428 行 `eylinkAddress`）：

```swift
UserDefaults.standard.set(zxmotoAddressField.text ?? "", forKey: "zxmotoAddress")
UserDefaults.standard.set(zxmotoWireModeControl.selectedSegmentIndex, forKey: "zxmotoWireMode")
UserDefaults.standard.set(zxmotoGeometryControl.selectedSegmentIndex, forKey: "zxmotoGeometry")
// 兼容回退：旧版本读取 eylinkAddress，一两个版本后再删。
UserDefaults.standard.set(zxmotoAddressField.text ?? "", forKey: "eylinkAddress")
```

新增 handler（尺寸/协议改动需要重启 CarPlay 才生效，给页面 footer 写清楚）：

```swift
@objc private func zxmotoSettingsChanged() {
    saveHeadUnitOutput()
    refreshVideoOutputSummary()
    if running {
        updateZxmotoStatus(CWL("设置已保存，重新启动 CarPlay 后生效。"))
    }
}
```

5. **`headUnitOutputChanged`（2506-2515）** 不变（已调用 `saveHeadUnitOutput` / `refreshVideoOutputSummary`）。
6. **连接卡（644-651）**：改名 + 文案更新（协议候选、默认端口、BLE 握手限制）。当前 644 行 `configureConnectionCard(eylinkCard, title: "ZXMOTO 仪表连接", ...)`；改成 `zxmotoCard`，`instructions` 改成：“让 iPhone 加入 ZXMOTO 仪表 Wi-Fi（iteAP），在仪表上打开投屏导航，再启动 CarPlay。500RR / 820R 默认走 EYLink：镜像 TCP 11111（UDP 11111 仅 BLE 回退），控制 TCP 11113，默认网关 192.168.43.1，全部小端。”
7. **状态回调（811-813）**：`receiver.onEylinkState` → `receiver.onZxmotoState`；`outputMode.eylink` → `outputMode.zxmoto`；`updateEylinkStatus` → `updateZxmotoStatus`。
8. **`planDisplay`（998-1003）**：

```swift
if let profile = zxmotoProfile {
    return DisplayPlan(width: profile.encodeWidth, height: profile.encodeHeight,
                       fps: profile.fps, codec: .h264, iconWidthMM: icon)
}
```

9. **`configureDisplay`（1359-1361）**：

```swift
if let profile = zxmotoProfile {
    config.zxmotoAddress = (zxmotoAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    config.zxmotoProfile = profile
    config.zxmotoWireMode = zxmotoWireMode
}
```

> `planDisplay` 把 CarPlay 流渲染成用户选择的规格，避免“先高分辨率再每帧大幅缩放”；若仪表协商尺寸不同，`ZxmotoOutput` 的 `fittedImage` 再做 letterbox。

10. **连接卡可见性（1282-1284）**：`eylinkCard.isHidden = !showsLocalOutput || !outputMode.eylink` → `zxmotoCard`；空闲文案 1284 行换成 `“等待启动 CarPlay · 仪表 IP：…”`（fallback `192.168.43.1`）。
11. **设置页 case（3155-3159）**：改成：

```swift
case .zxmoto500rr, .zxmoto820r:
    return [SettingsSection(headUnitOutput.selectedTitle, footer: CWL("iPhone 加入 ZXMOTO 仪表 Wi-Fi（iteAP），在仪表打开投屏导航后启动 CarPlay。500RR 与 820R 共用同一套输出；镜像默认 TCP 11111（UDP 11111 仅 BLE 回退），控制 TCP 11113，默认网关 192.168.43.1，所有帧格式为小端。修改画面规格后需重新启动 CarPlay。BLE 扫码握手暂未实现，若手动连接无画面请提交日志。"), [
        .field(CWL("仪表 IP 地址"), zxmotoAddressField, placeholder: "192.168.43.1"),
        .control(CWL("连接协议"), icon: ("network", .systemBlue), zxmotoWireModeControl),
        .control(CWL("仪表画面"), icon: ("aspectratio", .systemGreen), zxmotoGeometryControl),
        .info(CWL("当前画布"), zxmotoProfile?.encodeTitle ?? ""),
        .note(zxmotoStatus)
    ])]
```

12. **画面页（2767-2772）**：`if let eylink = eylinkProfile` → `if let profile = zxmotoProfile`；`.info(CWL("仪表画面"), "\(profile.encodeWidth)×\(profile.encodeHeight) · H.264 · \(zxmotoWireMode.title) · \(profile.fps) FPS")`。
13. **品牌分组（2276）**：已经是 `(CWL("ZXMOTO"), [.zxmoto500rr, .zxmoto820r])`，无需改。
14. **字段启用（2071）**：`eylinkAddressField.isEnabled = value` → `zxmotoAddressField.isEnabled = value`（若该函数是统一字段循环，把新字段加入即可）。
15. **启动状态（3220）**：`if configuration.zxmotoProfile != nil { updateZxmotoStatus("正在连接 ZXMOTO 仪表…") }`。
16. **测试/调试入口（454 行附近）**：URL scheme 的 `headUnitPage()` 跳转保持不变；不建议新增 scheme。

### 5.9 `App/Localization/Localizable.xcstrings`

- 现有 1364 个 key，新增 key 必须补 en/zh-Hans，否则英文界面回退中文。需要补的：`"ZXMOTO 仪表连接"`、`"张雪 500RR 5 寸"`、`"张雪 820R 5 寸"`、`"连接协议"`、`"自动"`、`"自动（仪表上报）"`、`"当前画布"`、`"正在连接 ZXMOTO 仪表…"`、`"设置已保存，重新启动 CarPlay 后生效。"`、`"仪表 IP 地址"`（若已存在则复用）。
- 编辑方式：直接编辑 JSON（`strings` 字典，每条 `localizations.{en,zh-Hans}.stringUnit.{state:"translated",value}`）；不要用脚本整文件重写（会改变排序/转义，diff 巨大）。用现有 `CWL()` 的 key 语义（key = 中文源串）。
- 如果时间紧，可以先只补最高频的菜单标题和连接卡文案，其余记录在 `docs/zxmoto-820r-integration.md` 的 known limitation 里（前一轮补丁的 5 个 key 就漏了，英文界面仍显示中文——这次补上）。

### 5.10 `App/Info.plist`

**不需要新增任何 key**：

- `NSLocalNetworkUsageDescription`（41 行）已存在，iOS 首次 `NWConnection` 连本地网段时自动弹本地网络授权；`ZxmotoConnection` 直连 `192.168.43.1` 会触发该提示。
- `NSAppTransportSecurity → NSAllowsLocalNetworking = true`（27-29 行）覆盖本地 HTTP/裸 TCP 场景。
- `NSBonjourServices`（34 行）只有做 Bonjour 发现才需要；ZXMOTO 是直连 IP，不需要添加 `_…._tcp` 条目。
- `NSBluetoothAlwaysUsageDescription` 已存在，后续若要加 BLE 扫码握手可直接用。
- 版本键（17/19 行）保持 `1.0.6` / `18`，实验功能不 bump（遵循上游 `docs/首驱仪表适配-20261127.md` 的版本策略：实车验证通过才在 release 前 bump）。
- 备注：CI unsigned 构建 `CODE_SIGN_ENTITLEMENTS=$(TDS_WIFI_ENTITLEMENTS)` 为空，因此 **SSID 读取（`com.apple.developer.networking.wifi-info`）在 CI IPA 里不可用**；不要依赖 SSID 自动填 IP，也不要在设置页把“自动检测 Wi-Fi 名字”作为 ZXMOTO 的必需步骤。

### 5.11 `Tools/generate_project.py` 与 `project.pbxproj`

- **不改生成器**：源码发现已覆盖 `App/*.swift`、`Sources/TDSCarKitCore/**/*.swift`（还有 `App/*.m`、`App/*.c`、`Sources/CTDSCarKitCrypto/*.c`）。新增 4 个 Swift 文件、删除 1 个，生成器都会自动处理。
- 本地（Windows）执行：

```powershell
python Tools/generate_project.py
git diff --stat TDSCarKit.xcodeproj/project.pbxproj   # 应出现 4 个新增 + 1 个删除
```

- 生成器在非 macOS 上会跳过 `plutil` 保留本地签名设置（try/except），所以 Windows 生成是安全的；生成 UID 用 `sha1(name)[:24]`，同名文件 UID 稳定，diff 可预期。
- 提交重新生成的 `project.pbxproj`（仓库同时服务本地 Xcode 用户）；即使漏提交，CI 步骤 `python3 Tools/generate_project.py` 也会在构建前重算，所以构建不会因此失败。
- 删除 `App/EylinkOutput.swift` 后确认 pbxproj 里没有 `EylinkOutput.swift` 的 `PBXFileReference`/`PBXBuildFile` 残留（重新生成即无）。

### 5.12 `Tests/TDSCarKitCoreTests/ZxmotoProtocolTests.swift`

新增纯字节测试（XCTest，`@testable import TDSCarKitCore`；现有 `Tests/TDSCarKitCoreTests` 有 15 个测试文件可照抄风格）：

```swift
import XCTest
@testable import TDSCarKitCore

final class ZxmotoProtocolTests: XCTestCase {
    func testMirrorStartPayloadOrder() {
        let packet = ZxmotoProtocol.Eylink.mirrorStart(width: 800, height: 480)
        XCTAssertEqual(Array(packet.prefix(12)), [0xAA, 0xBB, 0xCC, 4, 0, 0, 0, 0, 4, 0, 0, 0])
        // payload = LE16(min=480=0x01E0) + LE16(max=800=0x0320)
        XCTAssertEqual(Array(packet.suffix(4)), [0xE0, 0x01, 0x20, 0x03])
    }

    func testVideoPacketHeaderAndTimestamp() {
        let frame = Data([0x00, 0x00, 0x00, 0x01, 0x67])
        let packet = ZxmotoProtocol.Eylink.video(frame, timestampMilliseconds: 1234)
        XCTAssertEqual(packet.count, 12 + 4 + frame.count)
        XCTAssertEqual(Array(packet.prefix(12)), [0xAA, 0xBB, 0xCC, 0, 0, 0, 0, 0, 9, 0, 0, 0])
        XCTAssertEqual(Array(packet[12..<16]), [0xD2, 0x04, 0x00, 0x00])   // 1234 LE32
    }

    func testParseOKThirteenBytePacket() {
        // 'O''K' + portrait 480x800 + landscape 800x480 + fps 30 + kbps 4000（全部小端）
        let bytes: [UInt8] = [0x4F, 0x4B,
                              0xE0, 0x01, 0x20, 0x03,
                              0x20, 0x03, 0xE0, 0x01,
                              0x1E, 0xA0, 0x0F]
        let negotiation = ZxmotoProtocol.Eylink.parseOK(Data(bytes))
        XCTAssertEqual(negotiation?.width, 800)
        XCTAssertEqual(negotiation?.height, 480)
        XCTAssertEqual(negotiation?.fps, 30)
        XCTAssertEqual(negotiation?.bitrateKbps, 4000)
    }

    func testParseOKRejectsShortAndWrongMagic() {
        XCTAssertNil(ZxmotoProtocol.Eylink.parseOK(Data([0x4F, 0x4B])))
        XCTAssertNil(ZxmotoProtocol.Eylink.parseOK(Data(repeating: 0, count: 13)))
    }

    // RE 完成后补：ZxDash 黄金向量（`docs/zxdash-protocol.md`）
    // func testZxDashHandshakeGoldenVector() { ... }
}
```

> 注意 `bitrateKbps=4000` 的 LE16 是 `0xA0 0x0F`；实现时以 `docs/ZXMOTO-EYLINK-PROTOCOL.md` 与真实抓包为准。若 CI 没跑测试，这些测试在 macOS 本地 `swift test` 或加 CI 步骤（§14）时生效。

### 5.13 `docs/` 与文档

- 现有 `ZXMOTO-500RR.md`（仓库根，186 行）改成 `ZXMOTO-820R.md` 或在仓库根保留并在其中加“820R / 两种协议”章节；旧的“EYLink 已实现内容/已知限制”仍有效，但需更新文件名、类名（`ZxmotoOutput`）、协议可切换说明、新设置项。
- 新增 `docs/zxmoto-820r-integration.md`（面向维护者）：协议候选状态、RE 证据（官方字符串 `parsingReadHeader`/`EYMirrorConfiguration`/`bindServerPortInRange`/`EYMirrorTCPHeaderData`、EYLink 端口 TCP 11111 / 控制 11113（以 `docs/ZXMOTO-EYLINK-PROTOCOL.md` 为准）、BLE `0000aaa0`/`0000aaaa`）、本次重构的边界、实车验证记录、测试日志附件要求。
- 更新 `docs/车型适配整合.md`（42,398 字节的总览文档）加一行 ZXMOTO 820R 状态；`docs/摩托车协议适配调研-20261126.md`（8,779 字节）加 EYMirror/ZxDash 小节或链接。
- `docs/首驱仪表适配-20261127.md` 是本仓库“新车型适配文档”的模板（型号与菜单/连接实现/身份边界/验证清单/日志复查），ZXMOTO 文档按这个骨架写。

### 5.14 `.github/workflows/build-ipa.yml`

- 现有触发分支 `[main, master, zxmoto-500rr, zxmoto-500rr-upstream]` 已覆盖当前分支 `zxmoto-500rr-upstream`；继续在该分支开发则**无需改**。
- 建议追加（可选、低风险）：
  1. `paths` 加 `Tools/**`（打包/校验脚本改动也触发构建）和 `docs/**`（不必要，别加，省 CI）。
  2. `generate_project.py` 之后加一步防回归：

```yaml
      - name: Verify generated project contains new sources
        run: |
          for f in App/ZxmotoConnection.swift App/ZxmotoOutput.swift Sources/TDSCarKitCore/ZxmotoProfile.swift Sources/TDSCarKitCore/ZxmotoProtocol.swift; do
            grep -q "$f" TDSCarKit.xcodeproj/project.pbxproj || { echo "missing $f in pbxproj"; exit 1; }
          done
```

  3. 可选：`xcodebuild` 前加 `swift test`（macos-15 自带 Swift toolchain）；若 `TDSCarKitCore` 在 macOS 上编译通过，这一步能在打包前发现纯协议层错误。若报 iOS-only 依赖，删掉这步即可。
- artifact 名保持 `CarWithin-unsigned-ipa`（文件 `CarWithin-unsigned.ipa`）和 `build-log`（`build-xcodebuild.log`）；打包脚本按这两个名字下载（`gh run download <run-id> -n CarWithin-unsigned-ipa` 需要本机 `gh` 登录，否则用网页下载）。

### 5.15 新增 `Tools/` 脚本（从 gitignore 的 `tmp/` 移出）

- `Tools/embed_identity.py`：原样搬运 `tmp/embed_identity.py`（用法不变：`python Tools/embed_identity.py <source.ipa> <output.ipa> <identity_dir>`），它只操作 IPA zip、不读私钥内容，入库安全；identity 文件本身继续留在库外。
- `Tools/package_dist.py`：一次性完成 §14 的 dist 组装（复制 IPA/日志、生成 BUILD-INFO/SHA256SUMS、校验文件名/版本/UTF-8），避免手工步骤漏项。参数：`--dist-dir`、`--run-id`、`--commit`、`--branch`。
- `Tools/validate_zxmoto_release.py`：见 §15。
- 现有 `dist/` 未入库（untracked），建议在 `.gitignore` 加 `dist/`（以及 `*.zip` 顶层的产物）避免误提交；`tmp/` 已在 ignore 中，但 `dist/` 目前显示为 untracked，加 ignore 更安全。

### 5.16 其它文档/元数据

- `README.md` / `README.en.md`：加 ZXMOTO 820R 实验状态、构建产物下载说明（链接 dist/Actions artifact）。
- 根目录 `ZXMOTO-500RR.md`：按 §5.13 更新。
- 不新增 `App/Support` 资源、不改 `Assets.xcassets`。

---

## 6. 输出选择枚举：精确补丁（含当前状态）

当前 `HeadUnitOutput` 已经是**追加过**的形态（`6f27771`），因此实现时不是“从头加 820R”，而是**保留并改名外延**：

```swift
private enum HeadUnitOutput: Int {
    // Persisted in headUnitOutputV2. Append new modes after existing values.
    case browser, carLife, airPlay, tailing, ninebot, zeeho, ninebotSeven, ninebot43,
         zeehoSEPlus, zeehoAE2, cfmoto5, cfmoto62, cfmoto700MT, cfmoto800MT, cfmoto675SRR,
         benelliTRK, vogeDS800X, zontes368E, zontes368G, zontes703RR, qjSRT550, kove625X,
         moriniXCape1200, kove450Rally, kove800X, shouqu, zeehoAE4i, koveInstrument,
         zxmoto500rr, zxmoto820r          // raw 28 / 29 —— 绝对不要插入或重排
    static let menuOrder: [Self] = [.browser, .carLife, .airPlay, .ninebot43, .ninebot,
        .ninebotSeven, .tailing, .zeeho, .zeehoSEPlus, .zeehoAE2, .zeehoAE4i,
        .cfmoto5, .cfmoto62, .cfmoto700MT, .cfmoto800MT, .cfmoto675SRR, .shouqu,
        .benelliTRK, .vogeDS800X, .zontes368E, .zontes368G, .zontes703RR, .qjSRT550,
        .kove625X, .koveInstrument, .moriniXCape1200, .kove450Rally, .kove800X,
        .zxmoto500rr, .zxmoto820r]
    var menuIndex: Int { Self.menuOrder.firstIndex(of: self)! }
    var title: String {
        switch self {
        case .zxmoto500rr: return CWL("张雪 500RR 5 寸")
        case .zxmoto820r: return CWL("张雪 820R 5 寸")
        ...
        }
    }
    var zxmotoProfile: ZxmotoProfile? { ... }   // 见 §5.8
}
```

**如果要在一个“未打补丁的上游 1.0.6”上重新加**（例如从 `cffbf58` 重建），顺序是：

1. `case` 末尾追加 `zxmoto500rr, zxmoto820r`（rawValue = 当前 case 数，28/29）。
2. `menuOrder` 末尾追加两项。
3. `title` 增加两个 case。
4. 新增 `var zxmotoProfile`、`var zxmoto`，`usesInstrumentWiFi` 加上 `zxmoto`。
5. 其余 UI/持久化按 §5.8 接。

**为什么保留两个条目而不是合并成一个“ZXMOTO”**：
- 500RR 与 820R 是用户可感知的不同车型（即使是同一协议）；保留两个条目可以分别给默认几何/文案，未来 820R 若确认为 7 寸或不同端口，只需在 `ZxmotoProfile`/`Model` 上区分。
- 反例：合并成一个条目会丢失“用户到底骑哪台车”的持久化信息，且违背上游“一个菜单项 = 一个车型 profile”的惯例（九号 4.3/5/7 寸、极核各型号都是分开的）。
- 若最终确认两者硬件/协议完全一致，也可以合并菜单项，但**保留 rawValue 28/29 的解析映射**（做兼容迁移），不要在 old rawValue 上重排。

---

## 7. 设置/UI 插入点（汇总 + 现状锚点）

| 功能 | 现状位置（`6f27771`） | 重构后 |
|---|---|---|
| 输出菜单控件 | `headUnitOutput = ChoiceMenu(...)` 293 行 | 不变 |
| 枚举/持久化 | 294-360 行；`headUnitOutputV2` 保存 2423、读取 2331-2335 | 改名外延（§6） |
| 品牌分组 | 2276 行 `(CWL("ZXMOTO"), [.zxmoto500rr, .zxmoto820r])` | 不变 |
| 连接卡 | 644-651 行 | `zxmotoCard`，文案更新 |
| 卡可见性/空闲状态 | 1282-1284 行 | 改名 |
| 输出设置页 | 3155-3159 行 | 加协议/画面控件（§5.8-11） |
| 画面页 | 2767-2772 行 | 改名 + 显示协议 |
| 地址字段 | 2372-2374 行 | `zxmotoAddressField` + 迁移读取 |
| 保存 | 2428 行 | 写新 key + 兼容旧 key |
| 状态回调 | 811-813 行 | `onZxmotoState` |
| 启动状态文案 | 3220 行 | `updateZxmotoStatus` |
| 字段启用 | 2071 行 | 改名/加入新控件 |
| 新增持久化键 | — | `zxmotoAddress` / `zxmotoWireMode` / `zxmotoGeometry`（§8） |

`configureConnectionCard(_:title:symbol:color:instructions:status:)` 定义在 1220 行，返回 instruction label（九号卡 652 行用到了返回值）——ZXMOTO 卡如果不需要动态改 instruction，可不接返回值。

---

## 8. UserDefaults 键与迁移

| Key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `headUnitOutputV2` | Int | 0 | 当前输出枚举 rawValue（已有；ZXMOTO 500RR=28，820R=29） |
| `zxmotoAddress` | String | `""` | 仪表 IP；空 = 默认 `192.168.43.1` |
| `zxmotoWireMode` | Int | `0` | `ZxmotoWireMode` rawValue：0 auto / 1 EYLink / 2 ZxDash（ZxDash UI 暂不露出） |
| `zxmotoGeometry` | Int | `0` | `ZxmotoProfile.Geometry` rawValue：0 auto / 1 800×480 / 2 960×480 / 3 1280×720 |
| `eylinkAddress`（legacy） | String | — | 只读回退 + 过渡期写兼容；1-2 个版本后删除 |
| `headUnitOutput`（legacy） | Int | — | 上游已有迁移逻辑（2331-2335），不动 |

迁移规则：

```swift
let savedAddress = defaults.string(forKey: "zxmotoAddress")
    ?? defaults.string(forKey: "eylinkAddress")
    ?? "192.168.43.1"
```

- 不做“按型号分别存 IP/尺寸”：上游所有输出都是单组设置，ZXMOTO 两车型共享 IP/协议/几何，只有 `Model` 决定默认值，保持与 `CfmotoOutput`/`NinebotOutput` 一致的心智模型。
- 用户切 500RR↔820R 时几何/协议设置保留（是“这台手机连这套仪表”的偏好），文案里说明即可。
- 若以后要支持“每车型不同 IP”，再新增 `zxmotoAddress_820R` 之类的 key，不要复用旧 key 语义。

---

## 9. Info.plist / 本地网络 / ATS / Bonjour 结论

- **必须改**：无。
- **NSLocalNetworkUsageDescription**：已有（`App/Info.plist:41`），首次连接本地 IP 时系统弹窗；文案里写清楚“连接 ZXMOTO 仪表 Wi-Fi 需要本地网络权限”。
- **ATS**：已有 `NSAppTransportSecurity → NSAllowsLocalNetworking = true`（27-29 行）。裸 TCP/UDP 的 `Network.framework` 不受 ATS 约束，但保留该键对 `http://192.168.x.x` 的调试接口有益。
- **Bonjour**：不需要。ZXMOTO 是直连 IP + 固定端口，不做 `NWBrowser` 发现；`NSBonjourServices` 里不要加 `_zxmoto._tcp` 之类的假服务（加了反而要求真实注册/权限）。
- **BLE**：若后续实现扫码握手，`NSBluetoothAlwaysUsageDescription` 已存在；还需在 `App/TDSCarKit.entitlements`/签名时留意 MFi，但 CI unsigned 包无 entitlements，BLE 相关只影响本地开发。
- **SSID 自动检测**：CI unsigned 包没有 `wifi-info` entitlement，`TDSWiFiNameDetection` 不可用；不要把“自动识别 iteAP”作为连接前提，IP 手动输入 + 默认 `192.168.43.1` 兜底即可。

---

## 10. `NativeReceiver` 生命周期（与 CarPlay 会话对齐）

现状（不改结构，只改名/接线）：

- 输出实例与回调：70-71 行（`private let zxmoto = ZxmotoOutput(); var onZxmotoState: ((String) -> Void)?`）。
- `func start(configuration:identity:advertise:preferredViewer:)`（104-249 行）在私有 queue 上执行：先 `stopOnQueue()`（防重入），再按配置启动所有输出；ZXMOTO 启动块在 185-191 行。
- `func stop()`（325 行）→ `queue.async { self.stopOnQueue() }`；`stopOnQueue()`（405-431 行）里 `zxmoto.stop()`（替换 417 行 `eylink.stop()`）。
- CarPlay 视频回调：`media.onVideo = { ... }`（502-559 行）在 receiver queue 上逐帧调用；ZXMOTO append 在 525-527 行。
- 请求关键帧：`requestKeyFrame(reason:)`（369 行）/`requestKeyFrameOnQueue`（372 行）；ZXMOTO 解码/编码恢复时复用，reason 用 `"ZXMOTO 解码恢复"`。
- 状态回调：`onZxmotoState` 由 `Session.report` 在主线程调用（保持现有 `onEylinkState` 行为：`receiver.onEylinkState` 在 811-813 行里 guard `self.running && outputMode.zxmoto`）。

**已知行为（无需改动）**：输出在 CarPlay 会话开始前就连线（加入仪表 Wi-Fi 后先连、再启动 CarPlay），RTSP TEARDOWN/重建只影响视频流，不影响 ZXMOTO socket；如果仪表要求“先启动投屏导航再连”，用户按文档顺序操作即可，失败时 `ZxmotoConnection` 已带 15×500 ms 的 `MIRROR_START` 重试与 TCP 回退。

---

## 11. 820R Profile 默认值与“画面尺寸可选”

| 参数 | 默认 | 依据/说明 |
|---|---|---|
| 屏幕 | 800×480（5 寸，按 500RR 假设） | 任务假设。`docs/ZXMOTO-EYLINK-PROTOCOL.md` §7 提示 820R 可能 6.2 寸（1280×720/1280×480 类），**实车必须采用 OK 回包**；800×480 只是 MIRROR_START 初值 |
| FPS | 30 | 800×480@30 是 500RR 同款；`DisplayPlan` 用该值协商 CarPlay 流；实车以 OK 回包 fps 为准 |
| 码率 | 4,000,000 bps（4 Mbps） | 现有 EYLink 默认；OK 回包 `bitrateKbps×1000` 优先；H.264 Baseline AutoLevel（`NinebotH264Encoder` 默认） |
| 关键帧间隔 | 1 s（`MaxKeyFrameInterval = fps`） | `NinebotH264Encoder` 默认；官方 Android 用 i-frame 2 s，实车可调 |
| 字节序 | 全部小端（LE） | 官方 Android 1.4.5 协议；旧实现大端已由 `a419721` 修正 |
| 编码尺寸 | 偶数化：`800×480`（已是偶数） | H.264 硬编码要求 |
| letterbox | `CIImage` 等比缩放 + 黑边 | 仪表协商尺寸与 CarPlay 流不同时兜底 |
| 用户可覆盖 | `Geometry`：auto / 800×480 / 960×480 / 1280×720 | 设置页 ChoiceMenu；改后需重启 CarPlay |

**协商优先级**：
1. `Geometry != .auto` → 用户强制尺寸（只接受 320…2560 × 240…1600，偶数化）。
2. `Geometry == .auto` 且仪表上报了尺寸（EYLink `OK` 包 / ZxDash 首包）→ 采用上报值（同样 clamp）。
3. 都没有 → profile 默认 800×480。

**500RR 条目怎么处理**：
- 保留 `.zxmoto500rr`（rawValue 28）与菜单项；`ZxmotoProfile.fiveInch500RR` 与 `.fiveInch820R` 目前参数相同（800×480/30/4 Mbps），只是 label 不同。
- 待 RE/实车确认差异后，只改对应 `Model` 的默认值或 `Geometry` 选项；**不要**删除 500RR 条目（用户已在用默认 500RR 打包版本，删了持久化会 fallback 到 browser）。
- 文档里统一写“500RR / 820R 共用 EYLink 输出；820R 默认按 5 寸 800×480 处理”。

---

## 12. 协议无关连接层与候选协议接入

### 12.1 EYLink 线协议资产（以 `docs/ZXMOTO-EYLINK-PROTOCOL.md` 为准）

- 镜像通道 **TCP 11111（主）**；UDP 11111 仅 BLE 老设备回退。控制通道 **TCP 11113**（默认 `TCP_PORT_MESSAGE=11113`，BLE/二维码协商可改）。
- 12 字节头：`AA BB CC <func> 00 00 00 00 <LE32 payloadLen>`，payload 从 byte 12 开始；**长度/时间戳/尺寸全部小端**。
- `func=0` VIDEO_DATA：`LE32 毫秒时间戳 + Annex-B H.264`；`func=1` AUDIO_DATA（投屏不用）；`func=4` MIRROR_START：`LE16 min(W,H) + LE16 max(W,H)`；`func=5` MIRROR_STOP 空 payload；`func=6` WIDTH_HEIGHT：`LE16 W + LE16 H`（约每 2 s 重发）。
- `OK` 13 字节：`'O','K' + LE16 portraitW/H + LE16 landscapeW/H + fps(u8) + LE16 bitrateKbps`；按屏幕方向取 portrait/landscape，bitrate = kbps×1000，奇数尺寸 +1。
- `AA BB ?? 0F` ACK/心跳：完整 12 字节头 + LE32 len + JSON（`ver` 心跳 / `ack` / `timestamp` 播放进度），心跳 **12 s 超时**；`|timestamp - carTime| > 2000 ms` 时只发关键帧，恢复后先发关键帧。
- 连接顺序（官方 Android）：TCP connect（3 s 超时）→ 每 500–1000 ms 发一次 MIRROR_START（最多约 15–30 次）直到收到 OK → 先单独发 SPS、PPS 帧，再逐帧发视频；编码 CBR、i-frame 2 s、fps/bitrate 采用 OK 值。
- 控制帧：`'E','Y' + BE32 jsonLen + BE32 extraLen + JSON`（注意控制通道是**大端**；`fun=mirrorControl type="0"` 表示仪表要求停止投屏）。
- 反例：`6704a30` 版本用大端 + UDP 优先 + 控制 11112，已被 `a419721` 修正；迁移时以现文件（776 行）为准，**不要**搬旧版本。

### 12.2 换/加协议的步骤（ZxDash / EYMirror 为例）

1. 以 `docs/zxdash-protocol.md` / `docs/eymirror-protocol.md` 填 `ZxmotoProtocol.ZxDash`：端口（`ZxDashPacket.videoPort/dataPort`）、`hello()`、`frame(type:flag:payload:)`、`video(timestamp:nal:)`、`dataMessage`、`timeMessage`、`parseReply` 参数结构、`ZxDashPacketizer` 分包规则。
2. 在 `App/ZxmotoConnection.swift` 新增 `ZxDashTransport: ZxmotoTransport`：TCP 连接、hello 交换、参数应用（尺寸/fps/码率）、发送、保活、重连退避；错误文案走 `onState/onLog`，不抛到 `NativeReceiver`。
3. `ZxmotoWireMode.zxDash` 先编译不露 UI；`ZxmotoProtocolTests` 补黄金向量、`swift test` + CI 编译通过后再露出。
4. `.auto` 回退策略：先 EYLink（TCP 11111，连接超时 3 s）→ 失败再 ZxDash；判定逻辑集中在 `ZxmotoConnection` 的工厂/状态机，`ZxmotoOutput` 不感知。
5. 所有字节细节必须落在 `ZxmotoProtocol`（纯函数、可单测）；连接层只做 IO 与状态机。
6. 在 `docs/zxmoto-820r-integration.md` 记录证据（pcap、官方 App 版本、端口、请求/响应 hex、实车结果），并回填 `docs/ZXMOTO-EYLINK-PROTOCOL.md` 的新发现。

### 12.3 EYLink 剩余缺口（协议层 TODO，不阻塞重构）

- 官方 BLE 扫码握手（GATT service `0000aaa0-…` / char `0000aaaa-…`，`LinkFragment.startConnect`）未实现；若实车必须 BLE 触发，新增 `ZxmotoBootstrap.swift`（CoreBluetooth 扫描→连接→写特征→等通知）并做成设置开关，不阻塞主链路。
- 820R 实车回包尺寸未确认：`ZXMOTO-EYLINK-PROTOCOL.md` §7 提示 820R 可能 6.2 寸、1280×720/1280×480 类；实现必须完全采用 OK 回包参数，`ZxmotoProfile` 的 800×480 只是 MIRROR_START 初值。
- UDP 回退路径（BLE 老设备）未实现（官方 Android 仅在蓝牙老设备走 UDP 11111），暂标 TODO；控制通道 11113 的“停止投屏”指令已可接收，业务 JSON（天气/导航）不实现。

---

## 13. `App/EylinkOutput.swift` 的去留（决策）

**决策：替换（删除旧文件，新增 4 文件），不做“修乱码”式就地修改。**

理由：
1. **乱码不存在**（§2.2），没有任何字符串需要修；旧文件的问题是结构（单文件混合 profile/wire/transport/转码），不是编码。
2. 目标要求“连接层容易替换”，而旧文件把 EYLink 协议、NWConnection、转码流水线焊死在一起；直接改会形成更长的 if/switch 分支。
3. 旧实现可 100% 从 git 历史取回（`6f27771:App/EylinkOutput.swift`，已含小端/TCP 11111 修正），迁移风险由 CI 编译 + 设备日志兜底。

**分阶段方案（推荐给“不能本地编译”的执行者）**：

- **阶段 1（机械拆分，行为不变）**：新建 `ZxmotoProfile/Protocol/Connection/Output`，把旧 `Session` 代码原样搬入；`NativeReceiver`/`ReceiverConfiguration`/`ReceiverViewController` 改类型名；删除旧文件；本地 static check + CI 构建。此阶段完成后功能应与 `6f27771` 完全等价（EYLink 路径：小端 / TCP 11111 主 / 控制 11113 / ACK 0x0F / 12 s 超时）。
- **阶段 2（设置增强）**：加 `zxmotoWireMode` / `zxmotoGeometry` UI 与持久化；改 `planDisplay` 使用用户几何；补 xcstrings。
- **阶段 3（协议接入）**：RE 完成后加 `ZxDashTransport` + UI 露出 + 测试 + 实车验证。

**不推荐的替代方案**：保留 `EylinkOutput.swift` 并复制出 `ZxmotoOutput.swift` 双实现——两份 EYLink 代码会立刻漂移，且 `EylinkProfile` 与 `ZxmotoProfile` 类型重复；上游 conventions 也不接受同一输出两份实现。

---

## 14. 构建与打包（无本地 Mac，全流程 GitHub Actions）

### 14.1 现有 workflow 事实

- 文件：`.github/workflows/build-ipa.yml`（66 行，`name: Build unsigned IPA`）。
- 触发：`workflow_dispatch` + push 到 `[main, master, zxmoto-500rr, zxmoto-500rr-upstream]`（当前分支 `zxmoto-500rr-upstream` 在列）。
- Runner：`macos-15`，timeout 30 min。
- 步骤：checkout@v4 → `python3 Tools/generate_project.py` → `xcodebuild -project TDSCarKit.xcodeproj -scheme TDSCarKit -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/source CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build | tee build-xcodebuild.log` → 手工组装 `Payload/TDSCarKit.app` 并 `zip -qry CarWithin-unsigned.ipa Payload`（IPA 根必须是 `Payload/`，不要 `ditto --keepParent`）→ `upload-artifact@v4`：
  - `CarWithin-unsigned-ipa` → `CarWithin-unsigned.ipa`（missing 即 fail）
  - `build-log` → `build-xcodebuild.log`（always）
- 上次成功 run：`https://github.com/JerryFake/CarWithin_ZXMOTO/actions/runs/46014518045`（构建产物见 `dist/CarWithin-ZXMOTO-500RR-1.0.6-ZXMOTO/`）。

### 14.2 实现/构建/打包步骤清单

1. **前置**：确认在 `zxmoto-500rr-upstream` 分支；`python --version`（Windows 3.x）与 `git` 可用；无需 Xcode。
2. **改代码**：按 §5 清单编辑/新增/删除；同时更新 `docs/` 与 xcstrings。
3. **本地静态校验**：

```powershell
python Tools/generate_project.py
python Tools/validate_zxmoto_release.py --check-pbxproj --check-utf8 --check-enum
git status --short
git diff --check
```

   `validate_zxmoto_release.py` 至少覆盖：
   - `App/EylinkOutput.swift` 已删除、仓库内无 `EylinkOutput`/`EylinkProfile` 符号残留；
   - `project.pbxproj` 含 4 个新文件路径、不含旧文件；
   - `HeadUnitOutput` 的 case 顺序没有改变（解析源码枚举行，对比已知 30 个 case 序列，rawValue 28/29 仍是 zxmoto 两项）；
   - UserDefaults 读写键一致（grep `zxmotoAddress`/`zxmotoWireMode`/`zxmotoGeometry` 在 save/load 都出现）；
   - 文档 UTF-8（`bytes.decode('utf-8')` 通过、无 U+FFFD、无典型 mojibake 字符 `瀹/銆/锛/鏋`）；
   - `Info.plist` 的 version=`1.0.6`、build=`18`、含 `NSLocalNetworkUsageDescription`/`NSAllowsLocalNetworking`。
4. **提交并推送**：

```powershell
git add App Sources Tests Tools docs .github TDSCarKit.xcodeproj/project.pbxproj
git commit -m "Refactor ZXMOTO output: profile/protocol/connection/output split, selectable geometry"
git push fork zxmoto-500rr-upstream
```

   push 触发构建；也可在 Actions 页面 `Run workflow`（选分支）。
5. **等待构建**：Actions → `Build unsigned IPA` → 确认 `BUILD SUCCEEDED`；失败先下载 `build-log` artifact，按首个 `error:` 修（Swift 编译错误通常是类型名/参数标签/重复符号）。
6. **下载产物**：`CarWithin-unsigned-ipa`（内含 `CarWithin-unsigned.ipa`）+ `build-log`；无 `gh` 登录就用网页 artifact 下载。
7. **本地校验 IPA**（Windows Python）：

```powershell
python -c "import zipfile,sys; z=zipfile.ZipFile('CarWithin-unsigned.ipa'); names=z.namelist(); print(len(names)); print([n for n in names if n.startswith('Payload/')][:5]); assert 'Payload/TDSCarKit.app/TDSCarKit' in names"
python -c "import zipfile,plistlib; z=zipfile.ZipFile('CarWithin-unsigned.ipa'); p=plistlib.loads(z.read('Payload/TDSCarKit.app/Info.plist')); print(p['CFBundleShortVersionString'], p['CFBundleVersion'], p['CFBundleIdentifier'])"
```

   期望：`1.0.6 18 local.tds.carkit`；`Payload/TDSCarKit.app/TDSCarKit` 存在；无 `_CodeSignature`（unsigned）。
8. **嵌入身份（with-identity IPA）**：

```powershell
python Tools/embed_identity.py CarWithin-unsigned.ipa CarWithin-ZXMOTO-820R-1.0.6-with-identity-unsigned.ipa .\identity
```

   身份目录（`certificate.p7b` 607B / `leaf.cer` 558B / `private.x963` 97B，来自官方 unsigned IPA 抽取）**只在本地/打包机保存**，绝不入库；`tmp/identity-archive` 目前就是本地副本。
9. **组装 dist**（按上次 shape）：

```
dist/CarWithin-ZXMOTO-820R-1.0.6-<sha7>/
  BUILD-INFO.md
  README-FIRST.md
  TEST-CHECKLIST.md
  SHA256SUMS.txt
  build-xcodebuild.log
  changes-against-upstream-1.0.6.diff
  CarWithin-ZXMOTO-820R-1.0.6-unsigned.ipa
  CarWithin-ZXMOTO-820R-1.0.6-with-identity-unsigned.ipa
  CarWithin-ZXMOTO-820R-source-<sha>.zip
```

   命令示例：

```powershell
$sha = git rev-parse --short=7 HEAD
$dir = "dist/CarWithin-ZXMOTO-820R-1.0.6-$sha"
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item CarWithin-unsigned.ipa "$dir/CarWithin-ZXMOTO-820R-1.0.6-unsigned.ipa"
Copy-Item CarWithin-ZXMOTO-820R-1.0.6-with-identity-unsigned.ipa $dir
git diff cffbf58..HEAD -- . ':(exclude)_research' ':(exclude)dist' > "$dir/changes-against-upstream-1.0.6.diff"
git archive --format=zip --prefix=CarWithin/ -o "$dir/CarWithin-ZXMOTO-820R-source-$sha.zip" HEAD
python Tools/package_dist.py --dist-dir $dir --commit $sha --run-id <run-id> --branch zxmoto-500rr-upstream
Compress-Archive -Path $dir -DestinationPath "dist/CarWithin-ZXMOTO-820R-1.0.6-$sha.zip"
```

   `package_dist.py` 负责：复制 IPA/log、生成 `BUILD-INFO.md`（上游 cffbf58、tag v1.0.6=59d955f、分支、提交、Actions run URL、Runner macos-15、结果、Bundle ID、Version、架构 arm64、最低 iOS 16.0、IPA 表含大小/SHA-256、身份文件大小、源码 zip + diff 说明）、`SHA256SUMS.txt`（`<sha256>  <filename>` 每行一个）、并调用 `validate_zxmoto_release.py --dist` 做 UTF-8/命名/版本一致性校验。

10. **发布包清单**：`SHA256SUMS.txt` 至少覆盖两个 IPA + source zip + build log + changes diff（沿用上次 5 行格式）。
11. **文档更新**：`README.md`/`README.en.md`/`ZXMOTO-820R.md`/`docs/zxmoto-820r-integration.md` 写明下载链接、安装方式（AltStore/SideStore/TrollStore/Sideloadly）、with-identity 与 unsigned 的区别、测试步骤与已知限制。

### 14.3 版本策略

- 当前 `App/Info.plist`：`CFBundleShortVersionString = 1.0.6`（17 行）、`CFBundleVersion = 18`（19 行）。
- 实验阶段**不 bump**（沿用上游 `docs/首驱仪表适配-20261127.md` 的做法：开发中功能保持上游版本号；fork 的 dist 用文件夹名区分实验特性）。
- 实车验证通过、准备正式发布时：bump 到 `1.0.7 (19)` 或跟上游下个版本，同一提交同时更新 `README`/`BUILD-INFO`/标签；不要为了让 IPA 文件名不同而随意改版本号。

---

## 15. 无 Mac 环境下的验证策略

1. **静态校验（每次提交前，Windows 可跑）**：`Tools/validate_zxmoto_release.py`（§14.2 第 3 步清单）。
2. **CI 编译（权威门禁）**：push 后看 `build-log`；Swift 编译错误会精确到文件/行，按日志迭代。常见错误清单：
   - 类型改名遗漏（`EylinkProfile`/`EylinkOutput` 残留）；
   - `ChoiceMenu` 初始化参数或 `selectedSegmentIndex` 用法错误（照抄现有控件）；
   - `Sendable`/`@unchecked Sendable` 标注与跨队列捕获（保持现有模式）；
   - `CWL` 在 Core 模块可用（已存在），但 App-only 类型不能放在 `Sources/TDSCarKitCore`（如 `VideoCodec` 已在 Core，`ChoiceMenu` 是 App）。
3. **协议单元测试**：`ZxmotoProtocolTests` 在 `Tests/TDSCarKitCoreTests`；如果本机没有 Swift toolchain 就依赖 macOS CI 可选步骤 `swift test`，或在加测试的 PR 里让维护者跑。黄金向量以 §12.1 的 EYLink 规格为准，不依赖实车。
4. **审核 diff 重点**：枚举 rawValue 顺序、持久化 key 读写对称、`NativeReceiver` 三处接线（启动/追加/停止）、设置页 case 覆盖、`planDisplay` 返回的尺寸。
5. **实车验证清单**（写入 `TEST-CHECKLIST.md`，由有设备的人执行）：
   - 安装 with-identity IPA；iPhone 加入 ZXMOTO `iteAP` 热点；
   - 设置→当前输出→ZXMOTO→500RR/820R；填 IP（默认 192.168.43.1）；
   - 仪表打开投屏导航 → 启动 CarPlay；观察状态：
     `正在连接 ZXMOTO 仪表…` →（EYLink）`EYLink 镜像通道已连接，正在请求仪表开启投屏…` → `仪表已就绪 · 800×480 · 30 FPS` → `正在投屏 · 800×480 · H.264`；
   - 画面正常、触控/旋钮操作在 iPhone 侧完成；切换 500RR/820R 与几何设置，重启 CarPlay 验证；
   - 失败时记录：仪表型号/固件、iPhone 型号/iOS、App 版本、完整日志（状态行 + build log）、是否收到 `OK`/心跳是否超时；
   - 已知限制：BLE 扫码握手未实现、无音频、大关键帧在 UDP 回退时可能丢包（主通道 TCP 不受影响）、unsigned 包无 MFi 身份（必须用 with-identity 包测 CarPlay）。

---

## 16. 风险、开放问题与非目标

| 风险 | 影响 | 缓解 |
|---|---|---|
| 两个候选协议都未被实车证实 | 可能白做 | 架构与协议解耦；EYLink 先跑通；ZxDash 只留 transport 壳 |
| 820R 实际屏幕不是 800×480 | 尺寸错、letterbox 黑边 | `Geometry` 可覆盖 + `OK`/首包协商优先；实车日志回来后改 `ZxmotoProfile` 默认值 |
| UDP 回退（BLE 老设备）关键帧分片丢失 | 花屏/黑屏（主通道 TCP 11111 不受影响） | 降码率/分辨率、关键帧重发/请求关键帧逻辑；BLE 路径本期暂缓 |
| 官方 App 需要 BLE 触发投屏 | 手动连接无画面 | 预留 `ZxmotoBootstrap`（CoreBluetooth）；文档写明“若仪表不响应需抓包/BLE” |
| CI unsigned 包无 MFi 身份 | CarPlay 起不来 | 打包必须 with-identity（`Tools/embed_identity.py`）；文档强调 |
| 本地无法编译 | 低级错误靠 CI 发现 | 静态校验脚本 + 小步提交 + build-log 迭代 |
| xcstrings 漏 key | 英文界面中文 | 本次补齐（§5.9） |
| 误提交身份文件/研究产物 | 安全/仓库噪音 | `.gitignore` 已覆盖；`dist/` 也建议 ignore |

**非目标（本期不做）**：BLE 扫码握手、音频转发、OTA/远程升级、820R 专属 UI 主题、Android 端。

---

## 17. 附录 A：当前符号与行号锚点（`6f27771`，2026-11-28）

| 符号 | 位置 |
|---|---|
| `EylinkProfile` | `App/EylinkOutput.swift:16` |
| `EylinkPacket` | `App/EylinkOutput.swift:56` |
| `EylinkOutput` | `App/EylinkOutput.swift:100` |
| `EylinkOutput.start` | `App/EylinkOutput.swift:110` |
| `EylinkOutput.Session` | `App/EylinkOutput.swift:133`（文件共 776 行） |
| `eylinkAddress` / `eylinkProfile` | `App/ReceiverConfiguration.swift:46-50` |
| ZXMOTO IPv4 校验 | `App/ReceiverConfiguration.swift:198-204` |
| 权威协议文档 | `docs/ZXMOTO-EYLINK-PROTOCOL.md`（92 行） |
| `eylink` / `onEylinkState` | `App/NativeReceiver.swift:70-71` |
| ZXMOTO 启动块 | `App/NativeReceiver.swift:185-191` |
| `eylink.stop()` | `App/NativeReceiver.swift:417` |
| ZXMOTO append | `App/NativeReceiver.swift:525-527` |
| `media.onVideo` | `App/NativeReceiver.swift:502-559` |
| `HeadUnitOutput` | `App/ReceiverViewController.swift:294-360` |
| `.zxmoto500rr` / `.zxmoto820r` | 296 行（raw 28/29） |
| `menuOrder` | 298 行 |
| ZXMOTO 标题 | 315-316 行 |
| `eylink` / `usesInstrumentWiFi` | 358-359 行 |
| `planDisplay` | 998 行（ZXMOTO 999-1003） |
| `onEylinkState` 接线 | 811-813 行 |
| ZXMOTO 连接卡 | 644-651 行 |
| 卡可见性 | 1282-1284 行 |
| `configureDisplay` | 1319 行（ZXMOTO 1359-1361） |
| 地址字段 | 2372-2374 行 |
| `saveHeadUnitOutput` | 2422-2433 行（eylinkAddress 2428） |
| `headUnitOutputChanged` | 2506-2515 行 |
| 输出设置页 | 3117 行（ZXMOTO case 3155-3159） |
| 画面页 | 2765 行（ZXMOTO 2767-2772） |
| 启动状态 | 3220 行 |
| `Info.plist` 版本 | 17 / 19 行 |
| `Info.plist` 本地网络/ATS | 27-41 行 |
| 生成器源文件发现 | `Tools/generate_project.py`（`root.glob('App/*.swift')` 等） |
| workflow | `.github/workflows/build-ipa.yml` |

---

## 18. 附录 B：第三方 500RR fork 的可借鉴点（`_research/zx500rr-src`）

来源：`_research/zx500rr-src/App/Zx500rrOutput.swift`（28,198 bytes / 607 行，上游 1.0.5 base，单文件）与 `_research/zx500rr-src/docs/zx500rr-experimental.md`（6,918 bytes / 107 行）。**明确声明实验性、未实车验证、握手未抓到；只借思路，不借协议。**

可借鉴：

1. `static func gateway(for localIP: String) -> String?`：把本机 IP 最后一段换成 `1`，实现“默认网关 .1”自动填充（和现有 `PxcConnection.gateway(for:)` 思路一致）。ZXMOTO 默认就是 `192.168.43.1`，可在设置页用“留空=默认网关”表达，不必单独写代码；若写，放 `ZxmotoProfile` 旁的 helper。
2. 首包画面尺寸解析：JSON（嵌套 data/params/media/screen/resolution，键 width/w/Height/fps）失败后回退小端 u16（offset 0/2/4）——作为 ZxDash 候选协议的解析兜底思路；EYLink 已有确定的 `OK` 包，不需要。
3. 日志 hook：首包按“24 字节 hex + 96 字节 UTF-8 文本预览”打印——ZXMOTO 的 RE/实车日志非常有用，可放进 `ZxmotoConnection` 的 `onLog`（可读性远好于纯 hex）。
4. 设置键命名 `zx500rrAddress` / `zx500rrProfile` 与“profile Chooser”模式——本方案沿用为 `zxmotoAddress` / `zxmotoWireMode` / `zxmotoGeometry`。
5. 菜单/卡片/设置页的接入位置（`ReceiverViewController` 菜单、连接卡、输出设置页、持久化、状态刷新）——与本方案 §5/§7 一致，可对照检查没有漏项。

不可借鉴 / 需纠正：

- TCP video 1111 + message 11113 是**猜测**（文档原文“真实握手报文尚未抓到”）；不要据此改 `ZxmotoProtocol`。当前 EYLink 用 TCP 11111 镜像 / TCP 11113 控制（官方 Android 1.4.5，见 `docs/ZXMOTO-EYLINK-PROTOCOL.md`），以官方 App 行为与实车抓包为准。
- 它把 H.264 裸发、没有握手/鉴权；ZXMOTO 官方 App 明确有 `LinkFragment.startConnect` BLE 流程与 `EYMirror` 类，不能假设“连上就能投”。
- 它基于上游 1.0.5，`App/` 只有 `Zx500rrOutput.swift` 一个新增文件（没有 `ZxmotoProfile` 拆分），不能直接 cherry-pick；只能对照思路。
- 该 fork 的文档没有 UTF-8 问题（同样是控制台显示假象）；但它没有单元测试、没有 xcstrings、pbxproj 手改——这些正是本方案要改进的。

---

## 19. 附录 C：给协议 RE Agent 的交付契约（换协议时只填这些）

当你（或另一个 agent）完成 ZxDash 或 EYMirror 的抓包/反编译后，只需提供下面这份“填表”，实现 Agent 不需要理解转码层：

```
协议名：
官方 App 版本 / 触发路径（手动 vs BLE 扫码）：
iPhone 侧连接顺序：Wi-Fi →（BLE?）→ TCP/UDP
目标 IP / 端口：
握手请求（hex，含发送前等待/触发条件）：
握手响应（hex，字段偏移与含义：宽/高/fps/码率/版本/加密）：
视频帧封装：header 长度/字段/时间戳单位/是否 Annex-B/fragmentation/MTU 处理
控制/心跳：端口、周期、包格式、ACK/流控
失败回退：UDP→TCP? TCP→UDP? 重试次数/间隔
抓包证据：pcap 文件名 + 关键包 hex + 官方 App 版本
```

落点：
- 常量/解析 → `Sources/TDSCarKitCore/ZxmotoProtocol.swift` 的 `ZxmotoProtocol.ZxDash`；
- 连接状态机 → `App/ZxmotoConnection.swift` 的 `ZxDashTransport`；
- 黄金向量 → `Tests/TDSCarKitCoreTests/ZxmotoProtocolTests.swift`；
- 证据与实车结果 → `docs/zxmoto-820r-integration.md`；
- 设置项露出：`ZxmotoWireMode` 的 UI 列表加 `.zxDash`（若尚未露出）。

现有可用的 RE 线索（已在仓库/研究中出现，供交叉验证）：官方字符串 `parsingReadHeader`、`EYMirrorConfiguration`、`bindServerPortInRange`、`EYMirrorTCPHeaderData`；EYLink 端口 TCP 11111（镜像；UDP 11111 仅 BLE 回退）/ TCP 11113（控制），字节序小端；BLE GATT service `0000aaa0-…` / char `0000aaaa-…`（`ZXMOTO-500RR.md` 记录）；`_research/zx500rr-src` 的 TCP 1111/11113 只是第三方猜测。优先顺序：`docs/ZXMOTO-EYLINK-PROTOCOL.md`（官方 Android）→ `docs/eymirror-protocol.md`（官方 iOS）→ `docs/zxdash-protocol.md`（第三方 1.0.9 参考）。

---

## 20. 验收标准（Definition of Done）

- [ ] `App/EylinkOutput.swift` 删除；仓库无 `EylinkOutput`/`EylinkProfile` 引用；`grep -rn "Eylink" App Sources Tests` 只在 `ZxmotoProtocol.Eylink` 与用户文案中出现。
- [ ] 4 个新文件通过 CI `xcodebuild` 编译（`BUILD SUCCEEDED`）。
- [ ] `HeadUnitOutput` 的 rawValue 顺序未变（`.zxmoto500rr`=28、`.zxmoto820r`=29），旧设置不丢。
- [ ] 设置页可为 820R 配置：IP、协议（auto/EYLink）、画面（auto/800×480/960×480/1280×720）；保存/读取/迁移生效。
- [ ] `NativeReceiver` 在 start/append/stop 三处接线完成，CarPlay 起停不崩溃、不重复连接。
- [ ] `ZxmotoProtocolTests` 通过（macOS 或 CI 可选步骤）。
- [ ] `Info.plist` 无新增键，本地网络提示可用；版本仍 1.0.6 (18)。
- [ ] 文档：`docs/zxmoto-820r-integration.md` + `ZXMOTO-820R.md`（或更新 `ZXMOTO-500RR.md`）+ `README` 更新；dist 包按 §14 shape 产出并校验 UTF-8/SHA-256。
- [ ] 无身份文件、`_research/`、`tmp/` 内容进入提交。
- [ ] 协议修正不回退：保留 `a419721`/`6f27771` 的小端、TCP 11111 主通道、控制 11113、`AA BB CC 0F` ACK 前缀与 12 s 超时；不得以 `6704a30` 的大端/UDP 版本为基线。
