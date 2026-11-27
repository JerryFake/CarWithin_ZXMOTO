# ZXMOTO（500RR / 820R 5 寸）× CarWithin（EYLink 输出）

这个分支给 CarWithin 增加了一个实验性的 **ZXMOTO 5 寸仪表**输出：**500RR 5 寸**与 **820R 5 寸**共用同一套 EYLink 方案，路径与春风（PXC）、极核（Zeeho）不同：

> 500RR 官方 App 的“投屏导航”调用的是 **EYLink / EryaNet SDK**，不是标准 CarLife，也不是春风 PXC。
> 手机加入仪表热点 `iteAP` 后，连接 `192.168.43.1` 的 **UDP 11111（P2P 镜像，默认）** / **TCP 11111（BLE 路径回退）** 和 **TCP 11112（控制）**。

协议是通过反编译 ZXMOTO Android v1.4.5（`com.zxjc`）中的 `com.eryanet.ite.*` 发送端还原的。CarWithin 现在按同一套包格式，把 CarPlay 画面重新编码成 H.264 后发给仪表。

> **状态：基于上游 1.0.6 的源码适配，GitHub Actions macOS 构建已通过（`BUILD SUCCEEDED`），尚未在 500RR 实车上验证。**
> 本机是 Windows，没有 Xcode，不能本地编译 IPA；请用 GitHub Actions 或 macOS 构建。
> 官方启动流程还包含 BLE/扫码握手，本实现没有做 BLE，因此“手动连 Wi-Fi 直连”能否让仪表开启镜像端口，需要实车确认。

---

## 1. 已实现的内容

- 新增 `App/EylinkOutput.swift`
  - 解析仪表 `OK` 包下发的画面尺寸、帧率、码率；
  - 按 EYLink 12 字节包头封装 `MIRROR_START`、`VIDEO_DATA`、`MIRROR_STOP`；
  - 镜像默认走 UDP 11111（iteAP/P2P），无响应自动回退 TCP 11111；控制 TCP 11112（只读日志）；
  - CarPlay H.264 → 解码 → 缩放/黑边 → 按仪表尺寸重新编码 → 逐帧发送；
  - 关键帧恢复、发送积压限流、仪表时钟追帧。
- `App/ReceiverConfiguration.swift`
  - 新增 `eylinkAddress`、`eylinkProfile`，默认 `192.168.43.1`；
  - IPv4 校验（禁止 `.0` / `.255` / 本机地址 / 组播等）。
- `App/NativeReceiver.swift`
  - 新输出实例、启动、视频帧分发、停止。
- `App/ReceiverViewController.swift`
  - 输出菜单新增「ZXMOTO」分组，下面是「张雪 500RR 5 寸」和「张雪 820R 5 寸」；
  - 连接卡片、状态、IP 设置页、画面说明、持久化。
- `Tools/generate_project.py`
  - 兼容 Windows（无 `plutil`），并用 POSIX 路径写入 pbxproj，保证 macOS 上能找到源文件。
- `.github/workflows/build-ipa.yml`
  - macOS runner 自动生成工程并构建 unsigned IPA。

---

## 2. 构建 unsigned IPA

### 方式 A：GitHub Actions（推荐）

1. 把本目录推到 GitHub 仓库；
2. 打开 **Actions → Build unsigned IPA → Run workflow**；
3. 构建完成后下载 `CarWithin-unsigned-ipa` artifact，里面的 `CarWithin-unsigned.ipa` 就是未签名包。

工作流执行的核心命令：

```sh
python3 Tools/generate_project.py
xcodebuild -project TDSCarKit.xcodeproj -scheme TDSCarKit \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/source \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

### 方式 B：macOS 本地

```sh
python3 Tools/generate_project.py
xcodebuild -project TDSCarKit.xcodeproj -scheme TDSCarKit \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/source \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

把 `build/source/Build/Products/Release-iphoneos/TDSCarKit.app` 放进 `Payload/`，压缩成 `.ipa`：

```sh
mkdir -p Payload
cp -R build/source/Build/Products/Release-iphoneos/TDSCarKit.app Payload/
zip -qry CarWithin-unsigned.ipa Payload
```

> unsigned IPA 不能直接安装。需要用 AltStore / SideStore / TrollStore 等工具签名安装。
>
> **本版本按“无 MFi 认证”的要求构建：不把 CarPlay 配件身份打进 App。** 但 CarPlay 接收
> 本身仍然需要 MFi 身份，这一步无法从协议层去掉；没有身份时 App 会停在“尚未导入有效的
> MFi 身份”。源码和 CI 构建产物都不含身份文件。安装后请在“文件”App 的
> “我的 iPhone → CarWithin”里把 `certificate.p7b`、`leaf.cer`、`private.x963` 放进
> `IdentityImport` 文件夹，再按 App 内提示导入；身份文件会存入本机 Keychain。
>
> 如果你确实需要“装完不再提示导入”的内嵌身份包，可把三个文件放到 `App/BundledIdentity/`
> 后重新生成工程并本地构建（`.gitignore` 已忽略该目录）。这仍然不是“去掉认证”，只是把身份
> 随包携带；不要把含私钥的 IPA 或身份文件提交到公开仓库。

---

## 3. 实车使用步骤（待验证）

1. 车辆上电，仪表进入“导航/投屏导航”界面；
2. iPhone 打开 Wi-Fi，加入仪表热点 **`iteAP`**（密码以仪表/官方 App 显示为准）；
3. 确认 iPhone 拿到 `192.168.43.x` 地址，仪表是 `192.168.43.1`；
4. 打开 CarWithin，输出选择 **「ZXMOTO → 张雪 500RR 5 寸 / 张雪 820R 5 寸」**；
5. 在“连接设置”里确认仪表 IP 为 `192.168.43.1`；
6. 启动 CarPlay。

正常时状态会依次显示：

```text
正在连接 ZXMOTO 仪表…
EYLink 镜像通道已连接，正在请求仪表开启投屏…
仪表已就绪 · 800×480 · 30 FPS
正在投屏 · 800×480 · H.264
```

如果卡在“正在请求仪表开启投屏…”：

- 仪表可能没有因为手动 Wi-Fi 连接而启动镜像服务；
- 官方 App 是先 BLE/扫码，再让仪表进入投屏状态；
- 本实现未做 BLE 握手，这种情况需要补 CoreBluetooth 流程，或先用官方 App 触发仪表进入投屏态再切换。

---

## 4. EYLink 协议要点（逆向结果）

### 4.1 连接

| 通道 | 地址 | 用途 |
|---|---|---|
| 镜像 | `192.168.43.1:11111` UDP（iteAP/P2P，默认） | 每个 `MIRROR_START` / `VIDEO_DATA` / `MIRROR_STOP` 是一个独立 datagram，收 `OK` / `TP` / 心跳 |
| 镜像回退 | `192.168.43.1:11111` TCP | BLE/非 P2P 路径；UDP 无响应时尝试 |
| 控制 | `192.168.43.1:11112` TCP | `EY` JSON 帧，官方用于导航/状态同步；本实现只读日志，不作为启动镜像的前置条件 |
| 热点 | `iteAP` | 仪表创建，手机加入 |

### 4.2 12 字节包头

```text
AA BB CC <func> 00 00 00 00 <uint32BE payloadLen> <payload>
```

- 始终写 `payloadLen`（无 payload 时为 0，`MIRROR_STOP` 是 12 字节空包）；
- `func 0` = `VIDEO_DATA`，payload = `uint32BE timestampMs + Annex-B H.264`；
- `func 4` = `MIRROR_START`，payload = `uint16BE min(w,h) + uint16BE max(w,h)`；
- `func 5` = `MIRROR_STOP`，无 payload（12 字节空包）。

`MIRROR_START` 每 500ms 重发一次，最多 15 次；UDP 静默无响应时自动改用 TCP 11111 再试一轮；收到 `OK` 后停止。

### 4.3 仪表 `OK` 包（13 字节）

```text
'O' 'K' | portraitW u16BE | portraitH u16BE | landscapeW u16BE | landscapeH u16BE | fps u8 | bitrateKbps u16BE
```

- 宽高为奇数时 +1；
- 实际编码使用 `landscapeWidth × landscapeHeight`；
- `bitrate = bitrateKbps * 1000`。

### 4.4 控制帧（可选）

```text
45 59 <uint32BE jsonLen> <uint32BE extraLen> <JSON> <extra>
```

---

## 5. 已知限制

- **未做 BLE/扫码握手**：官方 `LinkFragment.startConnect()` 必须先有 GATT 连接；本实现只走手动 Wi-Fi。P2P/iteAP 路径官方使用 UDP 11111，本实现已按 UDP 发送并绑定本机 Wi-Fi 地址:11111（不是 0.0.0.0），收不到 `OK` 会回退 TCP。
- **UDP 大包**：H.264 关键帧可能超过单个 Wi-Fi MTU，依赖 IP 分片；若仪表丢大包，需要改小关键帧或让仪表协商更低码率。
- **未实车验证**：仪表是否接受第三方发送端、`OK` 尺寸是否与 500RR/820R 5 寸一致，需要上车测试。
- **没有音频**：和 CarWithin 其他仪表输出一样，声音留在 iPhone/蓝牙。
- **控制通道未实现业务握手**：只读日志；如果仪表要求 11112 上先发特定 JSON，需要按实车日志补。
- **H.264 参数**：使用 VideoToolbox Baseline；若仪表只接受特定 profile/level，需要调整。
- **安全**：只在停车/驻车时调试，不要在骑行中操作手机或仪表。

---

## 6. 下一步

1. 用 GitHub Actions 出第一版 unsigned IPA，安装到测试 iPhone；
2. 抓取 App 日志（Xcode Console 过滤 `EYLink` / `CarWithin`）：
   - 是否连上 11111；
   - 是否收到 `OK`；
   - 仪表返回的宽高/fps/码率；
   - 是否发出 VIDEO_DATA 但仪表黑屏。
3. 若镜像端口未开，补 BLE：service `0000aaa0-0000-1000-8000-00805f9b34fb`，characteristic `0000aaaa-...`，以及扫码 `carNum` 的 GATT 写入流程。
4. 若 `OK` 返回的尺寸与 800×480 差异大，按日志调整 `EylinkProfile` 或直接采用 `OK` 尺寸（当前已经采用 `OK`）。

---

## 7. 许可与声明

本适配基于 CarWithin（AGPL-3.0-only）与逆向得到的 EYLink 包格式，仅用于个人设备互联研究。不要用于规避车辆安全限制、商业破解或侵犯他人知识产权。张雪、ZXMOTO、EYLink 等名称归其权利人所有，本项目与它们无隶属关系。
