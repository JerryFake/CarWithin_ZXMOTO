import CoreImage
import Foundation
import Network
import UIKit
import VideoToolbox

/// ZXMOTO 仪表（EYLink / EryaNet）的输出规格。
///
/// 500RR 与 820R 的“投屏导航”都走 EYLink：手机加入仪表热点（`iteAP` 或 `ZXMOTO-…`）后直连 `192.168.43.1`：
/// - TCP 11111：镜像通道（官方 Android App 在无蓝牙/手动连热点时走 TCP），
///   收 `OK` 画面参数、发 `MIRROR_START` 与 H.264 帧；
/// - UDP 11111：旧固件的镜像通道（本实现作为回退）；
/// - TCP 11113：控制通道，收发 `EY` JSON 帧（可选，本实现只用来读日志）。
///
/// 仪表尺寸由 `OK` 包协商，默认值只用于 MIRROR_START 的初始请求。
struct EylinkProfile: Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let label: String

    static let zxmoto500rr = EylinkProfile(width: 800, height: 480, fps: 30, bitrate: 4_000_000,
                                           label: "张雪 500RR 5 寸")

    /// 820R 的仪表是 6.2 寸 TFT（部分资料/早期样车按 5 寸处理）；这里仍以
    /// 仪表 `OK` 包回报的尺寸为准，800×480 只是 MIRROR_START 的初始请求值。
    static let zxmoto820r = EylinkProfile(width: 800, height: 480, fps: 30, bitrate: 4_000_000,
                                          label: "张雪 820R")

    /// MIRROR_START 携带的是手机屏幕像素尺寸（官方 Android 用 WindowUtil 的值，
    /// 长边压到 2560 以内）；仪表据此选择镜像布局，真正编码尺寸由 `OK` 包决定。
    static func mirrorRequest(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = width
        var h = height
        let longest = max(w, h)
        if longest > 2560 {
            let scale = 2560.0 / Double(longest)
            w = Int((Double(w) * scale).rounded())
            h = Int((Double(h) * scale).rounded())
        }
        w -= w % 2
        h -= h % 2
        return (max(160, w), max(160, h))
    }

    var encodeWidth: Int { width - width % 2 }
    var encodeHeight: Int { height % 2 == 0 ? height : height + 1 }
    var title: String { "\(width)×\(height)" }
}

/// EYLink 的 12 字节包头 + payload。
///
/// 头部固定为 `AA BB CC func 00 00 00 00`，payload 长度是 bytes[8..12] 的小端
/// uint32；payload 从 byte12 开始。视频 payload 是 `uint32LE 时间戳 + Annex-B H.264`。
private enum EylinkPacket {
    static let videoFunction: UInt8 = 0
    static let mirrorStartFunction: UInt8 = 4
    static let mirrorStopFunction: UInt8 = 5

    static func packet(function: UInt8, payload: Data = Data()) -> Data {
        var data = Data([0xAA, 0xBB, 0xCC, function, 0, 0, 0, 0])
        // 头部固定 12 字节：8 字节魔数/功能码 + 4 字节 payload 长度。
        // payload 为空时长度字段保持 0（MIRROR_STOP 就是 12 字节空包）。
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    static func mirrorStart(width: Int, height: Int) -> Data {
        var payload = Data()
        appendUInt16(UInt16(clamping: min(width, height)), to: &payload)
        appendUInt16(UInt16(clamping: max(width, height)), to: &payload)
        return packet(function: mirrorStartFunction, payload: payload)
    }

    static func video(_ frame: Data, timestamp: UInt32) -> Data {
        var payload = Data()
        appendUInt32(timestamp, to: &payload)
        payload.append(frame)
        return packet(function: videoFunction, payload: payload)
    }

    /// EYLink 的数值字段全部是小端（官方 Android App 用 intTo2Bytes/intTo4Bytes 写入）。
    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

/// ZXMOTO 投屏输出：把 CarPlay 的 H.264 解回像素，缩放成仪表协商尺寸重新编码，
/// 再按 EYLink 的镜像协议逐帧发送。
final class EylinkOutput {
    private let queue: DispatchQueue
    private var session: Session?

    init(name: String = "eylink") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
    }

    deinit { stop() }

    func start(localAddress: String?, targetAddress: String, profile: EylinkProfile,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress,
                           profile: profile, onState: onState, onLog: onLog,
                           requestKeyframe: requestKeyframe)
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
        let queue: DispatchQueue
        let localAddress: String?
        let targetAddress: String
        let profile: EylinkProfile
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void

        private let networkQueue = DispatchQueue(label: "CarWithin.eylink.network", qos: .userInitiated)
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?
        private var inFlight = 0
        private var status = ""

        private var mirror: NWConnection?
        private var control: NWConnection?
        private var mirrorBuffer: [UInt8] = []
        private var controlBuffer: [UInt8] = []
        private var mirrorReady = false
        private var mirrorIsUDP = false
        private var triedUDPFallback = false
        private var requestWidth: Int
        private var requestHeight: Int
        private var startTimer: DispatchSourceTimer?
        private var startAttempts = 0

        private var encodeWidth: Int
        private var encodeHeight: Int
        private var encodedFPS: Int
        private var encodedBitrate: Int
        private var configured = false
        private var startTime: TimeInterval = 0
        private var firstFrame = true
        private var waitingForKeyFrameAfterLag = false
        private var carTime: Int?
        private var lastCarTimeAt: TimeInterval = 0

        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity

        init(queue: DispatchQueue, localAddress: String?, targetAddress: String, profile: EylinkProfile,
             onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.localAddress = localAddress
            self.targetAddress = targetAddress
            self.profile = profile
            self.encodeWidth = profile.encodeWidth
            self.encodeHeight = profile.encodeHeight
            self.encodedFPS = profile.fps
            self.encodedBitrate = profile.bitrate
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
            let bounds = UIScreen.main.nativeBounds
            let screenWidth = Int(bounds.width)
            let screenHeight = Int(bounds.height)
            if screenWidth >= 160, screenHeight >= 160 {
                let request = EylinkProfile.mirrorRequest(width: screenWidth, height: screenHeight)
                requestWidth = request.width
                requestHeight = request.height
            } else {
                requestWidth = profile.width
                requestHeight = profile.height
            }
        }

        func start() {
            report("正在连接\(profile.label)仪表…")
            queue.async { [self] in
                openMirror(udp: false)
                openControl()
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                encodeLoop()
            }
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.active, !self.mirrorReady, !self.configured else { return }
                self.report("ZXMOTO 仪表未连接：请确认 iPhone 已加入仪表热点（iteAP 或 ZXMOTO-…），且仪表 IP 为 192.168.43.1")
            }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() {
            lock.withLock { cancelled = true; acceptingFrames = false }
            queue.async { [self] in
                stopStartTimer()
                if mirrorReady, let mirror {
                    mirror.send(content: EylinkPacket.packet(function: EylinkPacket.mirrorStopFunction),
                                completion: .contentProcessed { _ in })
                }
            }
            networkQueue.async { [self] in
                mirror?.cancel()
                control?.cancel()
            }
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            stopStartTimer()
            mirror?.cancel()
            control?.cancel()
            mirror = nil
            control = nil
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
        }

        // MARK: - EYLink 连接

        private func makeParameters(udp: Bool) -> NWParameters {
            if udp {
                // 回退路径：旧固件/BLE 分支走 UDP 11111。UDP 连接不建流，
                // 每个 MIRROR_START/VIDEO_DATA 都是一个独立 datagram。
                // 官方 DatagramSocket(11111) 会绑定本机 11111 再连接仪表；
                // 某些仪表固件会固定向手机 11111 回 OK，因此这里也绑定同端口。
                // 必须绑定到本机 Wi-Fi 地址，不能绑 0.0.0.0（NWConnection 不接受通配地址）。
                let parameters = NWParameters.udp
                parameters.requiredInterfaceType = .wifi
                if let localAddress, !localAddress.isEmpty,
                   let localPort = NWEndpoint.Port(rawValue: 11111) {
                    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localAddress),
                                                                  port: localPort)
                }
                return parameters
            }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.connectionTimeout = 8
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.requiredInterfaceType = .wifi
            return parameters
        }

        private func openMirror(udp: Bool = false) {
            guard let port = NWEndpoint.Port(rawValue: 11111) else { return }
            mirror?.cancel()
            mirrorBuffer.removeAll()
            mirrorReady = false
            mirrorIsUDP = udp
            startAttempts = 0
            let connection = NWConnection(host: NWEndpoint.Host(targetAddress), port: port,
                                          using: makeParameters(udp: udp))
            mirror = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                self.queue.async { self.mirrorStateChanged(state, connection: connection) }
            }
            connection.start(queue: networkQueue)
        }

        private func openControl() {
            // 控制通道：Constants.TCP_PORT_MESSAGE 默认 11113（不是 11112）。
            guard let port = NWEndpoint.Port(rawValue: 11113) else { return }
            let connection = NWConnection(host: NWEndpoint.Host(targetAddress), port: port,
                                          using: makeParameters(udp: false))
            control = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async { self?.controlStateChanged(state) }
            }
            connection.start(queue: networkQueue)
        }

        private func mirrorStateChanged(_ state: NWConnection.State, connection: NWConnection) {
            guard active, mirror === connection else { return }
            switch state {
            case .ready:
                mirrorReady = true
                report("EYLink 镜像通道已连接，正在请求仪表开启投屏…")
                if mirrorIsUDP {
                    receiveUDPMirror()
                } else {
                    receiveMirror()
                }
                beginStartTimer()
            case .waiting(let error):
                onLog("EYLink 等待网络：\(error.localizedDescription)")
            case .failed(let error):
                mirrorFailed(error)
            case .cancelled:
                mirrorReady = false
            default:
                break
            }
        }

        private func controlStateChanged(_ state: NWConnection.State) {
            guard active else { return }
            switch state {
            case .ready:
                receiveControl()
            case .failed(let error):
                onLog("EYLink 控制通道失败：\(error.localizedDescription)")
            default:
                break
            }
        }

        private func receiveMirror() {
            guard let connection = mirror else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.queue.async {
                        guard self.mirror === connection else { return }
                        self.consumeMirror(Array(data))
                    }
                }
                if let error {
                    self.queue.async { self.mirrorFailed(error, connection: connection) }
                    return
                }
                if complete {
                    self.queue.async { self.mirrorFailed(nil, connection: connection) }
                    return
                }
                guard self.mirror === connection else { return }
                self.receiveMirror()
            }
        }

        private func receiveUDPMirror() {
            guard let connection = mirror else { return }
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.queue.async {
                        guard self.mirror === connection else { return }
                        self.consumeMirror(Array(data), datagram: true)
                    }
                }
                if let error {
                    self.queue.async { self.mirrorFailed(error, connection: connection) }
                    return
                }
                guard self.mirror === connection else { return }
                self.receiveUDPMirror()
            }
        }

        private func mirrorFailed(_ error: Error?, connection: NWConnection? = nil) {
            guard active else { return }
            if let connection, mirror !== connection { return }
            mirrorReady = false
            stopStartTimer()
            if !mirrorIsUDP, !configured, !triedUDPFallback {
                triedUDPFallback = true
                report("TCP 11111 无响应，回退 UDP 11111…")
                openMirror(udp: true)
                return
            }
            let reason = error?.localizedDescription ?? "连接已关闭"
            report("ZXMOTO 镜像连接断开：\(reason)")
        }

        private func consumeMirror(_ bytes: [UInt8], datagram: Bool = false) {
            mirrorBuffer.append(contentsOf: bytes)
            defer {
                // UDP 每个 datagram 是完整的 EYLink 包；解析完仍有余量就清掉，
                // 避免把下一个包的字节拼到上一个包后面。
                if datagram { mirrorBuffer.removeAll() }
            }
            while true {
                guard mirrorBuffer.count >= 2 else { return }
                if mirrorBuffer[0] == 0x4F, mirrorBuffer[1] == 0x4B {
                    guard mirrorBuffer.count >= 13 else { return }
                    let packet = Array(mirrorBuffer.prefix(13))
                    mirrorBuffer.removeFirst(13)
                    handleOK(packet)
                } else if mirrorBuffer[0] == 0x54, mirrorBuffer[1] == 0x50 {
                    guard mirrorBuffer.count >= 15 else { return }
                    mirrorBuffer.removeFirst(15)
                    onLog("EYLink 仪表使用 TP 旧格式，暂不支持")
                } else if mirrorBuffer[0] == 0xAA, mirrorBuffer[1] == 0xBB {
                    guard mirrorBuffer.count >= 4 else { return }
                    // 官方把 AA BB CC 0F 当作 ACK 帧头，其余 AA BB 前缀按脏字节丢弃。
                    guard mirrorBuffer[2] == 0xCC, mirrorBuffer[3] == 0x0F else {
                        mirrorBuffer.removeFirst()
                        continue
                    }
                    guard mirrorBuffer.count >= 12 else { return }
                    let length = Int(mirrorBuffer[8]) | Int(mirrorBuffer[9]) << 8
                        | Int(mirrorBuffer[10]) << 16 | Int(mirrorBuffer[11]) << 24
                    guard length >= 0, length <= 2048, mirrorBuffer.count >= 12 + length else { return }
                    let payload = Array(mirrorBuffer[(12)..<(12 + length)])
                    mirrorBuffer.removeFirst(12 + length)
                    handleHeartbeat(payload)
                } else {
                    // 未知字节：丢掉一个继续同步，避免脏数据把后续 OK 包卡住。
                    mirrorBuffer.removeFirst()
                }
            }
        }

        private func handleOK(_ bytes: [UInt8]) {
            guard bytes.count >= 13, bytes[0] == 0x4F, bytes[1] == 0x4B else { return }
            func value(_ index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 }
            let portraitWidth = value(2)
            let portraitHeight = value(4)
            let landscapeWidth = value(6)
            let landscapeHeight = value(8)
            let fps = Int(bytes[10])
            let bitrateKbps = value(11)
            let width = landscapeWidth > 0 && landscapeHeight > 0 ? landscapeWidth : portraitWidth
            let height = landscapeWidth > 0 && landscapeHeight > 0 ? landscapeHeight : portraitHeight
            guard width >= 160, height >= 160, fps > 0 else {
                onLog("EYLink 仪表返回了无效画面参数：\(width)×\(height) @ \(fps) FPS")
                return
            }
            guard !configured else { return }
            configured = true
            encodeWidth = max(160, width + width % 2)
            encodeHeight = max(160, height + height % 2)
            encodedFPS = max(1, min(60, fps))
            encodedBitrate = bitrateKbps > 0 ? bitrateKbps * 1000 : profile.bitrate
            lastKeyframe = -.infinity
            firstFrame = true
            waitingForIDR = true
            encoder?.invalidate()
            encoder = nil
            stopStartTimer()
            report("仪表已就绪 · \(encodeWidth)×\(encodeHeight) · \(encodedFPS) FPS")
            requestKeyframe()
        }

        private static func eylinkInteger(_ value: Any?) -> Int? {
            if let number = value as? Int { return number }
            if let number = value as? Double { return Int(number) }
            if let text = value as? String, let number = Int(text) { return number }
            return nil
        }

        private func handleHeartbeat(_ payload: [UInt8]) {
            guard let text = String(bytes: payload, encoding: .utf8),
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any] else { return }
            if let timestamp = Self.eylinkInteger(json["timestamp"]) {
                carTime = timestamp
                lastCarTimeAt = ProcessInfo.processInfo.systemUptime
            }
            if let version = json["ver"] as? String, !version.isEmpty {
                onLog("EYLink 仪表心跳 ver=\(version)")
            }
        }

        private func beginStartTimer() {
            guard !configured, startTimer == nil else { return }
            startAttempts = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.sendMirrorStart() }
            startTimer = timer
            timer.resume()
        }

        private func stopStartTimer() {
            startTimer?.setEventHandler {}
            startTimer?.cancel()
            startTimer = nil
        }

        private func sendMirrorStart() {
            guard active, !configured, mirrorReady, let mirror else { return }
            startAttempts += 1
            if startAttempts > 15 {
                if !mirrorIsUDP, !triedUDPFallback, !configured {
                    triedUDPFallback = true
                    startAttempts = 0
                    report("TCP 11111 无响应，回退 UDP 11111…")
                    openMirror(udp: true)
                    return
                }
                stopStartTimer()
                report("仪表未响应投屏请求，请重启仪表后再试")
                return
            }
            if startAttempts == 1 {
                report("正在请求仪表开启投屏…")
            }
            // 官方 App 在每次 sendStartMirror 时都重置 startTime；视频时间戳必须与
            // 仪表心跳里的 carTime 用同一条时间轴，否则会永久进入“只发关键帧”的追帧模式。
            startTime = ProcessInfo.processInfo.systemUptime
            waitingForKeyFrameAfterLag = false
            mirror.send(content: EylinkPacket.mirrorStart(width: requestWidth, height: requestHeight),
                        completion: .contentProcessed { _ in })
        }

        // MARK: - 控制通道（只读日志）

        private func receiveControl() {
            guard let control else { return }
            control.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.queue.async { self.consumeControl(Array(data)) }
                }
                if error != nil || complete { return }
                self.receiveControl()
            }
        }

        private func consumeControl(_ bytes: [UInt8]) {
            controlBuffer.append(contentsOf: bytes)
            while controlBuffer.count >= 10 {
                guard controlBuffer[0] == 0x45, controlBuffer[1] == 0x59 else {
                    controlBuffer.removeFirst()
                    continue
                }
                let jsonLength = Int(controlBuffer[2]) << 24 | Int(controlBuffer[3]) << 16
                    | Int(controlBuffer[4]) << 8 | Int(controlBuffer[5])
                let extraLength = Int(controlBuffer[6]) << 24 | Int(controlBuffer[7]) << 16
                    | Int(controlBuffer[8]) << 8 | Int(controlBuffer[9])
                guard jsonLength >= 0, jsonLength <= 1 << 20, extraLength >= 0, extraLength <= 1 << 20 else {
                    controlBuffer.removeFirst()
                    continue
                }
                let total = 10 + jsonLength + extraLength
                guard controlBuffer.count >= total else { return }
                let json = Array(controlBuffer[10..<(10 + jsonLength)])
                controlBuffer.removeFirst(total)
                if let text = String(bytes: json, encoding: .utf8), !text.isEmpty {
                    onLog("EYLink 控制消息：\(text.prefix(300))")
                }
            }
        }

        // MARK: - 视频编码

        private func encodeLoop() {
            var nextFrame = ProcessInfo.processInfo.systemUptime
            while active {
                let ready = queue.sync { configured && latest != nil }
                if !ready {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                let (fps, width, height) = queue.sync { (encodedFPS, encodeWidth, encodeHeight) }
                let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                if remaining > 0 {
                    Thread.sleep(forTimeInterval: min(remaining, 0.04))
                    continue
                }
                nextFrame = ProcessInfo.processInfo.systemUptime + 1.0 / Double(max(1, fps))
                guard active else { break }
                let result = queue.sync { () -> H264EncodedFrame? in
                    guard active, let image = latest else { return nil }
                    return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: firstFrame)
                }
                if let result {
                    queue.sync {
                        firstFrame = false
                        sendVideo(result)
                        report("正在投屏 · \(width)×\(height) · H.264")
                    }
                }
            }
        }

        private func sendVideo(_ frame: H264EncodedFrame) {
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let timestamp = UInt32(truncatingIfNeeded: max(0, Int(elapsed * 1000)))
            if let carTime, carTime != 0 {
                let lag = abs(Int(timestamp) - carTime)
                if lag > 60_000 {
                    // 仪表的 timestamp 可能是另一个时钟域（例如 epoch 秒/毫秒）。
                    // 此时按官方“延迟 >2s 只发关键帧”会永久卡在关键帧，直接关闭追帧判断。
                    self.carTime = nil
                    onLog("EYLink 仪表时间戳与本地时间轴不同，已关闭追帧判断（仪表值 \(carTime)）")
                } else if lag > 2000 {
                    // 仪表时钟已经跑远：先丢非关键帧，等下一个 IDR 再恢复。
                    waitingForKeyFrameAfterLag = true
                }
            }
            if waitingForKeyFrameAfterLag {
                guard frame.isKeyframe else { return }
                waitingForKeyFrameAfterLag = false
            }
            let shouldSend = lock.withLock { () -> Bool in
                guard !cancelled, acceptingFrames else { return false }
                if inFlight > 10, !frame.isKeyframe { return false }
                inFlight += 1
                return true
            }
            guard shouldSend else { return }
            guard let mirror, mirrorReady else {
                lock.withLock { inFlight -= 1 }
                return
            }
            let packet = EylinkPacket.video(frame.data, timestamp: timestamp)
            mirror.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.withLock { self.inFlight -= 1 }
                if let error {
                    self.queue.async {
                        guard self.active else { return }
                        self.onLog("EYLink 视频发送失败：\(error.localizedDescription)")
                    }
                }
            })
        }

        // MARK: - H.264 解码 / 编码（与 CfmotoOutput 相同的管线）

        func append(_ data: Data, keyframe: Bool) {
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else {
                        picture.append(unit)
                    }
                }
                if waitingForIDR {
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000),
                    isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image { latest = image }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        private func encode(_ image: CVPixelBuffer, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: encodeWidth, height: encodeHeight,
                                              fps: encodedFPS, bitrate: encodedBitrate) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                let stamp = CMTime(seconds: now, preferredTimescale: 1_000_000)
                try encoder.encode(try fittedImage(image), presentationTime: stamp,
                                   forceKeyframe: forceKeyframe || lastKeyframe == -.infinity)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                let frame = try result?.get()
                if frame?.isKeyframe == true { lastKeyframe = now }
                return frame
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                lock.withLock { encoded = nil }
                logCodecFailure("编码", error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = encodeWidth, height = encodeHeight
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw ConfigurationError("无法分配\(profile.label)缩放画面（\(status)）")
            }
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 {
                onLog("\(profile.label)\(stage)恢复：\(error.localizedDescription)")
            }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            let changed = lock.withLock { () -> Bool in
                guard message != status else { return false }
                status = message
                return true
            }
            guard changed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }
    }
}
