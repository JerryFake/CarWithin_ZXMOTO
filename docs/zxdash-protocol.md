# ZX MOTO dash protocol ("ZxDashPacket") — recovered from TDSCarKit 1.0.9 (local.tds.carkit)

Reverse-engineered 2026-11 from the unsigned GitHub IPA build of the third-party app
`local.tds.carkit` / module `TDSCarKit`.

Target binary: `_analyze_ipa/Payload/TDSCarKit.app/TDSCarKit`
- arm64 Mach-O, 4,867,744 bytes, no FairPlay, Swift symbol table intact (50,570 symbols).

All addresses below are virtual addresses in that binary (image base `0x100000000`).
Markers: **[P]** = proven from disassembly / raw bytes, **[I]** = inferred (evidence given),
**[U]** = unknown/unverified.

---

## 1. Transport

**[P]** The dash link is plain TCP via `Network.framework` `NWConnection` (symbols
`_$s7Network12NWConnectionC...`), not UDP and not raw BSD sockets.

| Use | TCP port | Symbol / raw bytes |
|---|---|---|
| Video + handshake channel | **11111** (0x2B67) | `ZxDashPacket.videoPort` static raw bytes at `0x1001fab60`: `67 2B`; getter `0x1001a23f0` (`ldrh`) |
| Time-sync / data channel | **11113** (0x2B69) | `ZxDashPacket.dataPort` static raw bytes at `0x1001fab62`: `69 2B`; getter `0x1001a23fc` |

**[P]** Connection parameters, built in `EylinkOutput.Session.openVideo()` @ `0x1000a07dc`
(and identically in `openData()` @ `0x1000a0bec`):

- `NWParameters(tls: nil, tcp: options)` — no TLS.
- `NWProtocolTCP.Options`:
  - `noDelay = true`
  - `enableKeepalive = true`
  - `keepaliveIdle = 5` (seconds)
  - `connectionTimeout = 6` (seconds)
- `params.requiredInterfaceType = .wifi` (symbol `_$s7Network11NWInterfaceV13InterfaceTypeO4wifiyA2EmFWC`).
- `NWConnection(host: NWEndpoint.Host(addressString), port: NWEndpoint.Port(rawValue: port)!)`
- `connection.start(queue: sessionQueue)`; the queue is a serial `DispatchQueue`
  created in `EylinkOutput.start()` @ `0x10009eb9c` (`DispatchQueue(label:qos:.userInitiated,...)`).

**[P]** Default dash address string: **`192.168.21.1`** (`EylinkProfile.defaultAddress`
getter `0x10009e310`, literal at `0x1001f5c90`). The session's host string is a stored
`String` field (Session +0x18), copied from the profile/receiver configuration.

---

## 2. Frame format (all packets)

**[P]** `ZxDashPacket.frame(type: UInt32, flag: UInt8, payload: Data) -> Data` @ `0x1001a30b4`
builds, in order (`appendLE32` = `ZxDashPacket.appendLE32` @ `0x1001a2e40`, writes
little-endian bytes one by one via `Data._Representation.replaceSubrange`):

```
offset  size  field
0       3     AA BB CC            (static literal, verified bytes at 0x10027bf40)
3       4     type    (UInt32 LE)
7       1     flag    (UInt8)
8       4     length  (UInt32 LE) = payload.count
12      N     payload bytes
```

Total overhead = 12 bytes. Confirmed by `frame()` reserving `payload.count + 12`
(`adds x0, count, #0xc` -> `Data._Representation.reserveCapacity`), the two LE32
appends, and the appended flag byte.

Known `type` values:

| type | use | source |
|---|---|---|
| `0` | video frame | `ZxDashPacket.video()` @ `0x1001a32e4` calls `frame(type: 0, flag: 0, ...)` |
| `4` | hello / handshake | `ZxDashPacket.hello()` @ `0x1001a2408` -> `frame(type: 4, flag: 0, ...)` |
| `6` | IDR/encoder-config marker | `ZxDashPacketizer.packets()` @ `0x1001a26a0` emits `frame(type: 6, flag: 0, payload: EE 09 C4 04)` |

**[P]** `flag` was 0 in every emitted frame found (hello, video, idr-marker). Meaning of
non-zero flag values: **[U]** (no producer observed in this binary).

---

## 3. Message: hello (video channel, right after TCP connect)

`ZxDashPacket.hello() -> Data` @ `0x1001a2408`

Payload is `Data([C4 04 EE 09])` (static array literal object at `0x10027bec0`; elements
at `0x10027bee0`, count 4). Sent as `frame(type: 4, flag: 0, payload: Data)`.

**[P] Exact wire bytes of hello (17 bytes):**

```
AA BB CC 04 00 00 00 00 04 00 00 00 C4 04 EE 09
```

Call site: `EylinkOutput.Session.videoStateChanged` @ `0x1000a13e4`, `bl 0x1001a2408` at
`0x1000a1834` — i.e. hello is sent from the video connection's `.ready` state handler.

Meaning of `C4 04 EE 09`: **[U]** (may be a magic/version/command). Do not assume ASCII.

---

## 4. Message: video frame (`type = 0`)

`ZxDashPacket.video(timestamp: UInt32, nal: Data) -> Data` @ `0x1001a32e4`

```
payload = LE32(timestamp) || 00 00 00 01 || nal
outer   = frame(type: 0, flag: 0, payload)
```

- The 4 raw bytes `00 00 00 01` come from static literal at `0x10027bf70` (count 4) and
  are the Annex-B 4-byte start code: each NAL unit is sent length-free with a start code
  prefix (`00 00 00 01`).
- `nal` is one NAL unit from `AnnexB.units2(in:)` (4-byte length-prefixed AVCC -> units).
- `timestamp` is milliseconds; the caller computes it as
  `elapsedMs = Int((systemUptime_now - lastFrameUptime) * 1000)` (see §8), so it is a
  **delta since the previous frame**, not an absolute clock. First frame after a keyframe
  is small/0.
- An empty `nal` is never sent (packetizer skips empty units).

One video TCP write may contain **several** frames concatenated — see §6.

---

## 5. Message: time sync (data channel, port 11113)

`ZxDashPacket.timeMessage(epochSeconds: Int, timeZoneHours: Int) -> Data` @ `0x1001a2550`
builds a JSON string and passes it to `ZxDashPacket.dataMessage(_:)` @ `0x1001a36d0`.

Data message container produced by `dataMessage(_: String) -> Data`:

```
45 59                 ASCII "EY"      (static literal object 0x10027bf80, elements 0x10027bfa0)
BE32 utf8.count       big-endian
BE32 0
<utf8 JSON bytes>
```

It is sent on the data connection as one TCP payload
(`NWConnection.send(content:contentContext:.defaultMessage isComplete:true ...)`,
`EylinkOutput.Session.sendTime()` @ `0x1000a3b4c`).

JSON for time sync (all numbers are **quoted decimal strings**; proven by the literal
pieces `{"data":{"timeZone":"` / `","timestamp":"` / `"},"fun":"time"}`):

```json
{"data":{"timeZone":"<tzHours>","timestamp":"<epochSeconds>"},"fun":"time"}
```

- `epochSeconds = Int(Date().timeIntervalSince1970)`.
- `timeZoneHours = TimeZone.current.secondsFromGMT() / 3600` (integer division,
  truncation toward zero; e.g. UTC+8 -> `8`).
- Sent immediately when data connection becomes `.ready`, then every **60 s**
  (data-channel `DispatchSourceTimer`, repeating interval constant `0x404e000000000000`
  = 60.0 s, scheduled at `0x1000a3738` in `dataStateChanged` @ `0x1000a33c8`).

No other `fun` values were found in this binary (`dataMessage` is called only from
`timeMessage`). The "EY" container + BE32 length format is the generic JSON message
envelope if other `fun` types are ever needed.

---

## 6. NAL aggregation / packetizer

`ZxDashPacketizer` = Swift struct `{ var sps: Data?; var pps: Data?; var configSent: Bool }`
(field descriptor `_$s9TDSCarKit16ZxDashPacketizerVMF` @ `0x10023db38`).

`mutating func packets(timestamp: UInt32, nals: [Data]) -> Data?` @ `0x1001a26a0`:

```
pass 1: for each nal (skip empty):
    t = nal.first & 0x1F
    t == 7 (SPS) -> self.sps = nal
    t == 8 (PPS) -> self.pps = nal

pass 2: out = Data()
for each nal (skip empty):
    t = nal.first & 0x1F
    if t == 1 (non-IDR slice):
        guard configSent else { return nil }
        out += video(timestamp, nal)             // frame type 0
    else if t == 5 (IDR slice):
        guard sps != nil && pps != nil else { return nil }
        if !configSent {
            out += video(timestamp, sps)         // frame type 0, payload LE32(ts)+00000001+sps
            out += video(timestamp, pps)
            configSent = true
        }
        out += frame(type: 6, flag: 0, payload: Data([EE,09,C4,04]))   // IDR marker
        out += video(timestamp, nal)             // actual IDR
    // other NAL types ignored
return out.isEmpty ? nil : out     // nil = nothing to send this iteration
```

`resetConnection()` @ `0x1001a2698`: **only** `configSent = false`
(`strb wzr,[x20,#0x20]`); `sps`/`pps` are kept.

Wire shape on the video port is therefore a concatenation of frames with no extra
packetization header; TCP segmentation is left to the stack. Order matters:
`[video SPS][video PPS][frame6 EE09C404][video IDR]...`.

---

## 7. Handshake reply + parameters (video channel)

The dash is expected to answer the hello on the **video** connection with a 13-byte reply.
`ZxDashPacket.parseReply(_ bytes: [UInt8]) -> Parameters?` @ `0x1001a24dc`:

```
require bytes.count >= 13
require bytes[0] == 0x4F 'O'
require bytes[1] == 0x4B 'K'
Parameters(
  width  = LE16(bytes[2..3]),
  height = LE16(bytes[4..5]),
  width2 = LE16(bytes[6..7]),
  height2= LE16(bytes[8..9]),
  fps    = bytes[10]              // unsigned byte
  kbps   = LE16(bytes[11..12])
)
```

Otherwise -> `nil` (all fields 0, Optional tag = 1).

`Parameters` = struct of 6 `Int`s, field descriptor `0x10023dae0`: `width, height,
width2, height2, fps, kbps` (48 bytes in memory; values arrive as described above).

`EylinkOutput.Session.applyParameters(_ params: Parameters?)` @ `0x1000a2d7c` (runs once,
guard `self.parametersApplied == false`):

- `nil` -> use current stored values (defaults/profile), proceed.
- width: require `160 <= width <= 1920`; else ignore that reply.
- height: require `height >= 160`.
- fps: clamp to `1...60`.
- kbps: if `kbps >= 308` then `bitrate = kbps * 1000` else use session default bitrate.
- round width/height up to even.
- if changed: store as applied width/height/fps/bitrate (Session +0x1C0/+0x1C8/+0x1D0/+0x1D8),
  rebuild/invalidate the `H264Encoder`.
- set `requestKeyframe = true`, resume video, report
  `"<label-ish> WxH fps FPS bitrate"` to UI.
- Fallback: if no reply within **3 s** of video `.ready`, the pending work item
  (`videoStateChanged`, 3 s `DispatchWorkItem`, cancellation handle Session +0x160)
  calls `applyParameters(nil)` so video starts with defaults.

Reply reassembly: `receiveReply(on:)` @ `0x1000a2124` starts
`NWConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096, completion:)`;
received bytes are appended to an accumulator (`[UInt8]` at Session +0x158) and parsed;
on success the completion `.defaultMessage` send is re-armed for the next reply.

---

## 8. Session flow (`EylinkOutput.Session`)

`EylinkOutput.start()` @ `0x10009eb9c`: creates the serial queue, allocates the Session
(holds `EylinkProfile`, `VideoParameterSets`, `ZxDashPacketizer`), then calls
`Session.start()` @ `0x10009f030`.

`Session.start()` (straight-line, [P]):

1. report initial status,
2. `queue.async { openVideo(); openData(); startWatchdog() }`.

`openVideo()` @ `0x1000a07dc` ([P]):

1. if `cancelled` (bit0 of Session +0xD8) -> return.
2. port = `ZxDashPacket.videoPort` = 11111; host = Session address string.
3. cancel previous video `NWConnection`, clear socket state: videoReady=false (Session +0x150),
   clear receive accumulator (+0x158), `packetizer.resetConnection()` (+0x178),
   set connecting flag (+0x199 = 1).
4. build TCP options (§1), `NWParameters`, `.wifi` required, create `NWConnection`,
   set `stateUpdateHandler` (-> `videoStateChanged` @ `0x1000a13e4`),
   `start(queue:)`.

`openData()` @ `0x1000a0bec` ([P]/[I]): same, with `dataPort` = 11113 and state handler
`dataStateChanged` @ `0x1000a33c8`.

`videoStateChanged` ([P] for calls, [I] for branch details):

- `.ready` -> log "connected, handshaking"; send `hello()`; start
  `receive(minimumIncompleteLength:1, maximumLength:4096)` with `receiveReply` closure;
  schedule 3 s fallback `applyParameters(nil)` work item.
- `.failed` / `.waiting` -> `videoLost()` @ `0x1000a1b60`; network errors -> report; then
  reconnect through the backoff path (`DashReconnectBackoff` type exists in this module)
  which re-enters `openVideo()` (+ `openData()`), i.e. full reconnect; log literals:
  `" 等待网络："`, `" 立即重试连接仪表（跳过退避）"`.
- video data send path: `NWConnection.send(content: Data, contentContext: .defaultMessage,
  isComplete: true, completion:)`.

`sendVideo(_ frame:)` @ `0x1000a3de8` (called from the H.264 encoder output closure
`encodeIteration`, [P]):

1. require `videoReady` (Session +0x150 == 1) **and** `parametersApplied` (+0x151 == 1);
2. `AnnexB.units2(in: frame.data)` -> `[Data]`; on error log + `requestKeyframe = 1`;
3. lock; `framesSinceKeyframe` = Session +0x130;
4. if `framesSinceKeyframe >= 11` and this frame is not a keyframe:
   set `requestKeyframe = 1` and drop the frame (asks encoder for IDR); else:
5. `elapsedMs = Int((systemUptime - lastFrameUptime) * 1000)` (Session +0x1E0 is written
   by the encoder loop), clamped >= 0;
6. `packetizer.packets(timestamp: UInt32(elapsedMs), nals: units)` -> `Data?`;
   nil -> requestKeyframe = 1 and return;
7. if frame was keyframe -> `requestKeyframe = 0`;
8. `framesSinceKeyframe += 1`; first frame after a keyframe records `firstFrameUptime`
   (Session +0xB8) and flags video started; `totalFramesSent += 1`;
9. send the whole Data on the video connection (one `.defaultMessage` write).

`sendTime()` @ `0x1000a3b4c`: (see §5) builds `timeMessage(epochSeconds:timeZoneHours:)`
and sends it on the **data** connection. Called from `dataStateChanged` when the data
connection becomes `.ready`, and then once per 60 s from the data `DispatchSourceTimer`.

`startWatchdog()` @ `0x1000a0fb8` ([P] setup, [I] thresholds): starts a
`DispatchSourceTimer` on the session queue with `deadline: now + 1 s`,
`repeating: 1.0 s`, leeway ≈ 200 (`mov w8,#0xc8` -> leeway value 200; unit **[U]**,
most likely ms). Handler (called every ~1 s) checks connection/activity state and triggers
the same `videoLost`/reconnect path. Exact numeric thresholds were **not** fully decoded
([U]); treat 1 s period as proven and the timeout values as unknown.

Cancellation: `Session.cancel()` @ `0x10009fe80` sets the `cancelled` bit at Session +0xD8,
cancels work items/timers, cancels both `NWConnection`s. `reconnectNow` @ `0x10009fc94`
calls `openVideo()` and `openData()` again (async-after wrapper).

Session field map used above (mangled ivar/offset evidence in `/tmp` scripts; [P] where used):

```
+0x18  String  host address           +0x148 NWConnection video
+0x38  Int     default fps            +0x150 Bool videoReady
+0x40  Int     default bitrate        +0x151 Bool parametersApplied
+0x48  String  address for status     +0x158 [UInt8] receive accumulator
+0x78  closure link/state callback    +0x160 DispatchWorkItem handshake fallback
+0x88  fn+ctx parameters-applied cb   +0x168 Int  (reset on applyParameters)
+0xB8  Double  firstFrameUptime       +0x178 ZxDashPacketizer
+0xC0  Bool    video started          +0x199 Bool requestKeyframe / needsReconnect
+0xC8  DispatchQueue                  +0x1A0 Double videoReadyUptime
+0xD0  NSLock                         +0x1A8 NWConnection data
+0xD8  UInt8 flags, bit0=cancelled    +0x1C0..0x1D8 applied w,h,fps,bitrate (Int)
+0x130 Int64 framesSinceKeyframe      +0x1E0 Double lastFrameUptime
+0x1E8 Int64 totalFramesSent         +0x1F8 H264Encoder
```

Two connections are kept open simultaneously: video 11111 (frames + handshake/reply) and
data 11113 (time sync).

---

## 9. EylinkProfile defaults / settings

`EylinkProfile` struct (field descriptor @ `0x10023a004`):
`width Int, height Int, fps Int, bitrate Int, label String, highProfile Bool,
keyframeInterval Double` (size 64).

**[P]**

- `defaultAddress` = **`"192.168.21.1"`** (getter `0x10009e310`; literal `0x1001f5c90`).
- `baselineDefaultsKey` = **`"eylinkBaseline"`** (getter `0x10009e31c`; literal `0x1001f5ca0`).
- `zxmoto500rrFromSettings` @ `0x10009e328` builds the default profile:
  - `width = 800`, `height = 400` (constants `0x1001f5c60 = {800,400}`)
  - `fps = 30`, `bitrate = 2_000_000` (constants `0x1001f5c70 = {30, 2000000}`)
  - `keyframeInterval = 2.0` (seconds; `0x4000000000000000` at +0x38)
  - `label`: 12 UTF-8 bytes
    `E5 BC A0 E9 9B AA 20 35 30 30 52 52` = the Chinese brand name + `500RR`
    (stored as an inline Swift String; the literal in this build has marker byte `0xAC`
    at the end instead of the usual `0xE0|12 = 0xEC` — **[U]** Swift-version artifact,
    does not affect the ASCII bytes).
  - `highProfile = !UserDefaults.standard.bool(forKey: "eylinkBaseline")`
    (selectors proven: `standardUserDefaults` @ rebase of `0x100270040` ->
    `0x10022502f`; `boolForKey:` @ `0x100270258` -> `0x1002211d1`; key literal
    "eylinkBaseline" built inline; result XOR 1). So the settings toggle named
    "Baseline" makes `highProfile = false`.
  - `sourceWidth`: if `height <= 479` then `(width * 480 / height) & ~1`, else width.
  - `sourceHeight`: `max(height, 480)`.
  - `encodeWidth` (getter `0x1000989f8`): width rounded down to even.
  - `encodeHeight` (getter `0x100098a18`): height rounded up to even.
  - `profileName` (getter `0x10009e464`): `highProfile ? "High" : "Baseline"`.

UI strings (proven, `__cstring`) confirm the transport and defaults:
`"TCP 11111"`, `"TCP 11113"`, `"800x400 H.264 30 FPS"`, `"192.168.21.1"`,
`"800 x 400 (H.264 Baseline)"`, `"张雪 500RR"` label.

---

## 10. Reference implementation sketch (Swift)

```swift
// ZxDashPacket
enum ZxDashPacket {
  static let videoPort: UInt16 = 11111   // 0x2B67
  static let dataPort:  UInt16 = 11113   // 0x2B69

  static func frame(type: UInt32, flag: UInt8, payload: Data) -> Data {
    var d = Data([0xAA, 0xBB, 0xCC])
    d.appendLE32(type); d.append(flag); d.appendLE32(UInt32(payload.count)); d.append(payload)
    return d
  }
  static func hello() -> Data { frame(type: 4, flag: 0, payload: Data([0xC4,0x04,0xEE,0x09])) }
  static func video(timestamp: UInt32, nal: Data) -> Data {
    var p = Data(); p.appendLE32(timestamp); p.append(contentsOf: [0,0,0,1]); p.append(nal)
    return frame(type: 0, flag: 0, payload: p)
  }
  static func dataMessage(_ json: String) -> Data {
    var d = Data([0x45,0x59]); d.appendBE32(UInt32(json.utf8.count)); d.appendBE32(0)
    d.append(contentsOf: json.utf8); return d
  }
  static func timeMessage(epochSeconds: Int, timeZoneHours: Int) -> Data {
    dataMessage(#"{"data":{"timeZone":"\#(timeZoneHours)","timestamp":"\#(epochSeconds)"},"fun":"time"}"#)
  }
}
// struct Parameters { width,height,width2,height2,fps,kbps: Int }
// parseReply: count>=13 && b[0]==0x4F && b[1]==0x4B -> Parameters(...)
//             else nil
```

Packetizer: keep `sps`, `pps`, `configSent`; logic in §6. Session: per §8 with
`receiveReply` re-arming `receive(min:1,max:4096)`.

---

## 11. Uncertain / needs verification

1. **Flag semantics**: flag byte is 0 for every emitted frame in this binary; whether the
   dash expects a non-zero flag for anything (e.g. keyframe) is unknown.
2. **Hello payload `C4 04 EE 09`**: no decoder; sent verbatim. IDR marker payload
   `EE 09 C4 04` likewise (looks like a byte-swapped variant of the hello payload; could be
   a little-endian magic — unknown).
3. **Reply field widths**: proven reads are LE16, LE16, LE16, LE16, u8, LE16 at the
   13-byte reply. Semantics of `width2/height2` (e.g. coded vs display size) unknown;
   `applyParameters` only uses `width, height, fps, kbps`, so `width2/height2` occupy
   the parse slots but are ignored downstream.
4. **Bitrate heuristic**: reply value `< 308` treated as already-bps; `>= 308` treated as
   kbps and multiplied by 1000. The exact intent (kbps field) is inferred from the
   default profile's 2,000,000 bps.
5. **Watchdog thresholds**: 1 s timer period is proven; the timeout(s) that trigger
   `videoLost`/reconnect and the exact backoff schedule (`DashReconnectBackoff`) were not
   fully decoded.
6. **Chunking**: no explicit app-level chunking was found — `packets()` returns one
   `Data` and it is sent in one `NWConnection.send`. If the dash needs max-size chunks,
   that bound is not visible in this binary.
7. **Data-channel inbound**: only outbound time JSON was traced; whether the dash sends
   anything back on 11113 is unknown (no parser other than `parseReply` was found).
8. **Timestamp unit**: computed as milliseconds from `(systemUptime delta) * 1000`; first
   frames may carry 0. Dash may interpret as ms.
9. **`label` marker byte 0xAC** in `zxmoto500rrFromSettings` (see §9) — Swift inline-string
   encoding oddity, no protocol impact.
10. **Hello/reply order**: hello is sent from the video state handler on `.ready`, then the
    app starts receiving; the 3 s default fallback (applyParameters(nil)) is proven as a
    scheduled work item but its exact cancellation/branch conditions are partially
    inferred.
