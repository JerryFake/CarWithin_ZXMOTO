# EYMirror protocol - ZXMOTO iOS ReplayKit broadcast extension (reverse-engineering report)

Status: reverse-engineered 2026-11-28 by static analysis of the official iOS app
`com.zxjc` 1.4.5 (ZXMOTO / HBuilder.app) and its broadcast upload extension
`com.zxjc.mirror` (`MotorMirror.appex`), cross-checked against the official Android
app of the same vendor (`com.eryanet.ite`, decompiled in `jadxout/`), which contains
the same wire protocol written in Java and is fully readable.

Companion document: `docs/ZXMOTO-EYLINK-PROTOCOL.md` documents the dash-facing
"EYLink" wire protocol recovered from the Android app (that is the protocol a
CarWithin clone must speak to a real 500RR / 820R dash today). This document adds
the iOS-extension side: what the official iPhone app actually does, what is known
for certain, what is inferred, and the exact constants / byte layouts / evidence.

All facts below are tagged:

- `[PROVEN-ANDROID]` - read directly from official Android Java source (authoritative
  for the dash wire behaviour; the dash is the same physical device for both phones).
- `[PROVEN-IOS-META]` - recovered from plaintext Mach-O metadata of the iOS binaries
  (symbol names, Swift field names, types, class lists, entitlements).
- `[INFERRED]` - reasoned from the above, NOT byte-verified (iOS machine code and
  all string literals inside `__TEXT` are FairPlay-encrypted; see method section).

---------------------------------------------------------------------------

## 1. Executive summary

1. The dash is a Wi-Fi access point. The phone joins it, then the phone pushes
   screen video to the dash. Dash IPv4 is `192.168.43.1` `[PROVEN-ANDROID]`.
2. Dash hotspot SSID starts with `ZXMOTO-` on the iOS app
   `[PROVEN-IOS-META, main-app JS string "...connect ZXMOTO- prefixed WIFI..."]`;
   the Android app uses `iteAP` / `iteAP-xxxx` `[PROVEN-ANDROID]`. Both prefixes
   must be accepted by a clone.
3. The dash-facing "EYLink" framing is a 12-byte header:
   `AA BB CC <func> 00 00 00 00 <LE32 length>`, payload from offset 12.
   All multi-byte integers are LITTLE-endian `[PROVEN-ANDROID]`.
4. Mirror data uses port 11111 (UDP primary / TCP fallback), control+JSON channel
   uses TCP 11113, car-OTA uses TCP 11112 `[PROVEN-ANDROID]`.
5. Handshake: phone repeatedly sends `MIRROR_START` (func=4); dash answers with a
   13-byte `OK` packet carrying portrait/landscape W/H, fps and bitrate(kbps);
   then the phone streams H.264 Annex-B frames as func=0 with a LE32 ms timestamp
   `[PROVEN-ANDROID]`.
6. The dash keeps the phone's clock in sync by sending `ACK` (func=0x0F) frames
   whose JSON payload contains `ver` (heartbeat), `ack`, or
   `timestamp` (dash playback clock in ms) `[PROVEN-ANDROID]`.
7. The iOS side is NOT the same binary layout as Android: the extension module
   `EryaMirrorExtensionKit` defines a newer header scheme with agreement version,
   socket type, data type, video flag and video angle, a UDP header that
   advertises dynamic TCP ports, and JSON control messages mapped with
   ObjectMapper (`EYMirrorConfiguration`, `EYMirrorCommand`, `EYMirrorState`)
   `[PROVEN-IOS-META]`.
8. The iOS extension acts as a TCP **server** on dynamically-chosen ports
   (`bindServerPortInRange`, `randomInRange`, `socket:didAcceptNewSocket:`) and
   never dials out itself; the iOS app side additionally has a matching client
   (`connectToCommandPort(and:)`, `didConnectToHost:port:`) `[PROVEN-IOS-META]`.
9. The extension has NO app-group, NO NSUserDefaults and NO hotspot entitlement
   (its only entitlements are team-id and application-identifier), while the main
   app owns `com.apple.developer.networking.HotspotConfiguration` and all
   hotspot/BLE code `[PROVEN-IOS-META]`. Therefore the extension cannot read app
   settings and cannot join Wi-Fi itself.
10. The iOS H.264 encoder is `EYNH264VideoEncoder` (Objective-C, 59 methods,
    VideoToolbox-based, derived from LFLiveKit `LFHardwareVideoEncoder` /
    `LFLiveVideoConfiguration`) `[PROVEN-IOS-META]`. JSON configuration keys are
    exactly `portraitWidth, portraitHeight, landscapeWidth, landscapeHeight,
    frameRate, bitRate` `[PROVEN-IOS-META]`.
11. For a CarWithin clone targeting a real dash, implement the EYLink v1 protocol
    (sections 5 and 9). The iOS EYMirror v2 header/JSON layers (section 6) only
    matter if a firmware is found that expects them.

---------------------------------------------------------------------------

## 2. Binaries analysed and the encryption limitation

### 2.1 Extension binary

Path:
`_analyze_zxmoto/Payload/HBuilder.app/PlugIns/MotorMirror.appex/MotorMirror`

- 729,952 bytes, thin arm64 Mach-O, `LC_ENCRYPTION_INFO_64`:
  `cryptoff=0x4000`, `cryptsize=0x84000`, `cryptid=1`.
- `__TEXT` segment: vmaddr `0x100000000`, vsize `0x88000`, fileoff 0,
  filesize `0x88000`. The encrypted range `0x4000..0x88000` therefore covers
  **the complete `__TEXT` segment**, i.e. `__text`, `__stubs`, `__objc_stubs`,
  `__cstring`, `__objc_classname`, `__objc_methname`, all `__swift5_*` metadata
  and `__unwind_info`/`__eh_frame` are FairPlay ciphertext (per-page entropy
  ~7.95-7.99). Consequence: **no instruction disassembly, no literal strings, no
  selector names, no Swift field-descriptor records can be recovered statically.**
- Plaintext remains: `__DATA*` (fileoff >= 0x88000) and `__LINKEDIT`
  (fileoff 0x98000, filesize 0x1a360), which contain the symbol table, the dyld
  bind info and - critically - the **dyld export trie** with full Swift mangled
  names (see 2.3).
- Bundle Info.plist: `CFBundleIdentifier=com.zxjc.mirror`,
  `NSExtensionPointIdentifier=com.apple.broadcast-services-upload`,
  `NSExtensionPrincipalClass=SampleHandler`,
  `RPBroadcastProcessMode=RPBroadcastProcessModeSampleBuffer`,
  `MinimumOSVersion=12.1`, `DTSDKName=iphoneos26.2`, `DTXcode=2630`,
  `CFBundleShortVersionString=1.4.5`, `CFBundleVersion=10045`.
- Embedded entitlements (plaintext plist inside `__LINKEDIT`):
  `com.apple.developer.team-identifier = 3Z8W7XAD6M`,
  `application-identifier = 3Z8W7XAD6M.com.zxjc.mirror`. Nothing else - no
  `application-groups`, no `com.apple.developer.networking.HotspotConfiguration`,
  no keychain groups.

### 2.2 Main app binary

Path: `_analyze_zxmoto/Payload/HBuilder.app/HBuilder` (96,607,136 bytes, arm64).

- Same FairPlay scheme (`cryptid=1`, `__TEXT` vmaddr 0x100000000 vsize 0x4bf4000,
  encrypted from 0x4000 to ~0x4bf4000); `__DATA_CONST` (off 0x4bf4000),
  `__DATA` (off 0x4e8c000) and `__LINKEDIT` (off 0x55d0000, size 0x651ba0) are
  plaintext.
- Its `__LINKEDIT` export/name pool (dyld export blob at file offset 0x5664488,
  size 0x2a9078) is a **plaintext pool of Swift mangled name fragments**, even
  though the code is encrypted. This is where the app-side EYLink/EYMirror class
  names and field/property getter names below come from. The pool is not a
  normal dyld trie and standard trie parsers only recover ~992 C++/ObjC exports;
  the Swift names were harvested as printable ASCII runs
  (`tmp/hb_ascii.py` -> `tmp/hb_ascii.txt`, 80,940 runs).
- Main app entitlements/strings found in that pool: universal link
  `applinks:zxjc.cqzxmoto.com`, `com.apple.developer.networking.HotspotConfiguration`,
  app group `group.com.zxjc.widget`, display name `ZXMOTO`.

### 2.3 How the extension's Swift symbol set was recovered

`tmp/zx_trie.py` parses the plaintext export trie at `__LINKEDIT+0x5daa0`
(file offset `0x9daa0`, size `0x58d8`) - a classic ULEB128 dyld trie - and
recovers **838 exported symbols** with their image offsets
(`tmp/zx_exports.txt`, `<vmaddr> <flags> <mangled-name>`). The module prefix on
all of them is `_$s22EryaMirrorExtensionKit`. Image base is 0x100000000, so
`vmaddr = 0x100000000 + trie-offset`. Examples (addresses are the real
functions/thunks in the encrypted `__text`; only the address + name are
readable):

```
0x10005000c  ...19EYSampleLinkManagerC21bindServerPortInRange33_7808561477FFDF4CA66862F50A95B147LL_6socket10retryCountSiSnySiG_So14GCDAsyncSocketCSgSitF
0x1000509ac  ...19EYSampleLinkManagerC13randomInRange33_7808561477FFDF4CA66862F50A95B147LL5rangeSiSnySiG_tF
0x1000510b4  ...19EYSampleLinkManagerC20parsingTcpHeaderData33_7808561477FFDF4CA66862F50A95B147LLySi10Foundation0K0VF
0x100051bb4  ...19EYSampleLinkManagerC6socket_18didAcceptNewSocketySo08GCDAsyncL0C_AGtF
0x10005...   ...19EYSampleLinkManagerC... (see tmp/zx_exports.txt)
0x10006c66c  ...15EYSampleManagerC12startServiceyyF
0x10006cb84  ...15EYSampleManagerC11stopServiceyyF
0x10006cc58  ...15EYSampleManagerC18uploadSampleBufferyySo08CMSampleI3RefaF
0x10006cff8  ...15EYSampleManagerC17parsingReadHeader33_5F2F8AB3...LL_4datayAA21EYMirrorTCPHeaderDataVSg_10Foundation0T0VtF
0x10006d1f0  ...15EYSampleManagerC15handleHeartbeat33_5F2F8AB3...LLyyF
0x10006d204  ...15EYSampleManagerC24parsingConfigurationData33_5F2F8AB3...LLyy10Foundation0I0VF
0x10006d878  ...15EYSampleManagerC16setConfiguration33_5F2F8AB3...LLyyF
0x10006e578  ...15EYSampleManagerC18parsingCommandData33_5F2F8AB3...LLyy10Foundation0I0VF
0x10006f534  ...15EYSampleManagerC13sendStateInfo33_5F2F8AB3...LLyyF
0x10006fd20  ...15EYSampleManagerC13sendVideoData33_5F2F8AB3...LL_5isKeyy10Foundation0I0V_SbtF
0x100070384  ...15EYSampleManagerC23angleWithScreenRotation33_5F2F8AB3...LLySiSo26CGImagePropertyOrientationVF
0x1000708d8  ...15EYSampleManagerC12videoEncoder_28didCompleteWithParameterDataySo012EYNH264VideoH0C_10Foundation0M0VSgtF
0x100070b64  ...15EYSampleManagerC12videoEncoder_15didCompleteWith10isKeyFrameySo012EYNH264VideoH0C_10Foundation4DataVSgSbtF
0x100046514  ...21EYMirrorSampleManagerC16broadcastStarted12finishHandleyySo7NSErrorCc_tFZ
0x1000468c8  ...21EYMirrorSampleManagerC17broadcastFinishedyyFZ
0x100053974  ...21EYMirrorUDPHeaderDataV11commandPort04dataI011payloadSizeACSays5UInt8VG_A2ItcfC
0x10006a1f8  ...21EYMirrorTCPHeaderDataV10socketType04dataI011payloadSizeACSays5UInt8VG_A2ItcfC
```

Class inventory from `__DATA.__objc_classlist` (22 entries, `tmp/appex_meta2.py`)
with method-list counts (methods are Objective-C only; Swift classes expose no
`@objc` methods here):

| class | kind | #objc methods |
|---|---|---|
| `SampleHandler` | ObjC, `RPBroadcastSampleHandler` subclass | 5 |
| `LFLiveVideoConfiguration` | ObjC (LFLiveKit) | 35 |
| `GCDAsyncSocket` | ObjC (CocoaAsyncSocket) | 168 |
| `GCDAsyncUdpSocket` | ObjC (CocoaAsyncSocket) | 152 |
| `EYNH264VideoEncoder` | ObjC | 59 |
| `EYNImageFilterManager` | ObjC | 16 |
| `LFHardwareVideoEncoder` | ObjC (LFLiveKit) | 24 |
| `LFMirrorFrame` / `LFVideoFrame` | ObjC (frame containers) | 7 / 7 |
| `_TtC22EryaMirrorExtensionKit21EYMirrorSampleManager` | Swift class | - |
| `_TtC22EryaMirrorExtensionKit19EYSampleLinkManager` | Swift class | - |
| `_TtC22EryaMirrorExtensionKit15EYSampleManager` | Swift class | - |
| (plus GCDAsync* helper packet classes) | ObjC | - |

---------------------------------------------------------------------------

## 3. iOS component model (proven metadata, inferred wiring)

### 3.1 Roles

`[PROVEN-IOS-META]` from the Swift metadata (full field/method lists are in
`tmp/zx_exports.txt`, grouped in `tmp/zx_types.txt`):

- `EYMirrorSampleManager` (Swift, called from `SampleHandler`):
  `processSampleBuffer(_:with:)`, `broadcastStarted(finishHandler:)`,
  `broadcastFinished()`. Translation layer between ReplayKit and the service.
- `EYSampleManager` (Swift, the service):
  fields `linkManager: EYSampleLinkManager`, `configuration: EYMirrorConfiguration`,
  `state: Int`, `screenAngle: Int`, `portrait: Int`, `videoEncoder: EYNH264VideoEncoder?`;
  methods `startService()`, `stopService()`, `setConfiguration()`,
  `parsingConfigurationData(_:)`, `parsingCommandData(_:)`, `sendStateInfo()`,
  `uploadSampleBuffer(_:)`, `sendVideoData(_:isKey:)`, `handleHeartbeat()`,
  `angleWithScreenRotation(_:) -> Int`,
  `videoEncoder(_:didCompleteWith:isKeyFrame:)`,
  `videoEncoder(_:didCompleteWithParameterData:)`, `stopBroadcast: String?`.
- `EYSampleLinkManager` (Swift, the socket layer):
  fields `dataSocket: GCDAsyncSocket?`, `commandSocket: GCDAsyncSocket?`,
  `dataServerSocket: GCDAsyncSocket?`, `commandServerSocket: GCDAsyncSocket?`,
  `udpSocket: GCDAsyncUdpSocket?`, `commandPort: Int`, `dataPort: Int`,
  `localHost: String`, `headerTag: Int`, `payloadTag: Int`,
  `headerDataCount: Int`, `tcpHeader: EYMirrorTCPHeaderData?`,
  `dataDelegateQueue/commandDelegateQueue/udpDelegateQueue: DispatchQueue`,
  `dataHandler: ((EYMirrorTCPHeaderData?, Data) -> Void)?`,
  `stateHandler: ((Int, Error?) -> Void)?`;
  methods `start()`, `stop()`, `sendVideoData(Data)`, `sendCommandData(Data)`,
  `headerData(...)`, `randomInRange(range: Range<Int>)`,
  `bindServerPortInRange(_ range: Range<Int>, socket: GCDAsyncSocket, retryCount: Int) -> Int`,
  `parsingTcpHeaderData(Data) -> Int`, and GCDAsync delegates
  `socket(_:didAcceptNewSocket:)`, `socket(_:didWriteDataWithTag:)`,
  `socket(_:didRead:withTag:)`, `socketDidDisconnect(_:withError:)`,
  `udpSocket(_:didSendDataWithTag:)`, `udpSocket(_:didNotSendDataWithTag:dueToError:)`.
  Note two decisive negative facts (no such symbols are exported by the
  extension): there is **no** `didConnectToHost:` (it never dials out, it only
  accepts), and there is **no** UDP `didReceiveData:fromAddress:withFilterContext:`
  (its UDP socket is send-only). So the extension binds random TCP server ports
  and pushes a UDP announcement to the peer; the peer is expected to dial back
  with TCP. Port binding is randomized inside a range with retry
  (`randomInRange` uses `arc4random_uniform`, imported).
- `SampleHandler` (ObjC) - the ReplayKit principal class, calls into
  `EYMirrorSampleManager`.

`[PROVEN-IOS-META]` the extension imports (symtab undefined symbols):
`RPBroadcastSampleHandler`, `NSJSONSerialization`, `UIScreen`, `NSLock`,
`NSNotificationCenter`, `AVCaptureDevice*`/`AVCaptureSession` (from LFLiveKit),
`CIContext`/`CIImage`, `GCDAsyncSocket`, `GCDAsyncUdpSocket`, C sockets
(`socket/bind/listen/accept/connect/send/sendto/recvfrom/setsockopt`),
`getifaddrs`/`freeifaddrs`/`if_nametoindex`, `arc4random_uniform`, `dispatch_*`,
VideoToolbox/CoreMedia/CoreVideo C APIs, `CFReadStream*`/`CFWriteStream*`
(legacy socket helper code), and ObjectMapper (statically linked; symbols under
the same Swift module name). No `NSUserDefaults`, no `CFPreferences`, no
`NEHotspotConfiguration`, no `CoreLocation`, no `CNCopyCurrentNetworkInfo`.

### 3.2 Wiring hypothesis

The entitlement + symbol evidence supports this picture `[INFERRED, high confidence]`:

- The **main app** is the only component allowed to join Wi-Fi
  (`NEHotspotConfiguration` entitlement + `NEHotspotConfigurationManager` usage)
  and it owns the BLE pairing/hotspot provisioning code
  (`HotspotConnector`, `hasHotspot/useHotspot/hotspotInfo/saveHotspotInfo/applyHotspotConfiguration`,
  `EYBlueHotspot`, `EYPeripheralDevice`, `connectPeripheralWithNameHasPrefix`,
  `targetPrefix`, `connectToNavigationServer`).
- The **extension** only captures and encodes. It cannot read app defaults
  (no app group) so it starts a local TCP command/data server on random free
  ports and announces those ports in a UDP header to the dash (dash = the Wi-Fi
  AP and therefore knows the phone's IP after the first datagram; the extension
  never needs to know 192.168.43.1). The dash then dials back the two TCP ports,
  sends JSON configuration (the OK-equivalent), receives JSON state, and
  receives the H.264 stream on the data socket.
- The main app links a copy of the same `EryaMirrorExtensionKit` classes plus
  the client-side delegates (`connectToCommandPort(and:)`,
  `didConnectToHost:port:`, `beginReceiveUDPData`, `udpSocket:didReceiveData:...`),
  which lets the app talk the same header/JSON protocol. It is also the app that
  contains the dash-facing EYLink classes (`EYLinkClient`, `EYLinkUpdate`,
  `EYMirrorManager`, `EYMirrorLinkState`, `sendMirrorCommand(_:portrait:)`,
  `parsingVideoData(_:isKeyFrame:screenAngle:)`, `parsingMirrorStateData(_:)`,
  `startMirrorConnection/stopMirrorConnection/resumeMirrorConnection`,
  `handleHeartbeat`, `waitForKeyFrame`, `mirrorBufferPool`, `mirrorCacheLock`).

Alternative wiring (app relays extension frames to the dash over loopback)
cannot be ruled out from static evidence alone but is less consistent with
ReplayKit behaviour (the containing app is suspended while a broadcast runs,
whereas the extension keeps running). Both must be distinguished by sniffing.

Because everything above the metadata level is encrypted, byte-exact v2 header
sizes cannot be proven statically. Section 6 gives the candidate layout and how
to verify it.

---------------------------------------------------------------------------

## 4. Data model recovered from Swift metadata

All structures below are `[PROVEN-IOS-META]`: stored property names, order,
types and initialiser labels were recovered from the plaintext Swift mangled
names and from the matching field/init fragments found in the main app's
plaintext name pool.

### 4.1 `EYMirrorConfiguration` (struct, ObjectMapper `Mappable`/`BaseMappable`)

```swift
struct EYMirrorConfiguration {
    var portraitWidth: Int
    var portraitHeight: Int
    var landscapeWidth: Int
    var landscapeHeight: Int
    var frameRate: Int
    var bitRate: Int
    init(portraitWidth:portraitHeight:landscapeWidth:landscapeHeight:frameRate:bitRate:)
    init(map: Map)                        // JSON -> struct
    func mapping(map: Map)                // JSON keys == property names
}
```

Symbols: `...21EYMirrorConfigurationV13portraitWidthSivg`
(getters/setters/mutable-addressors per field), init mangled
`...13portraitWidth0G6Height09landscapeH00jI09frameRate03bitL0ACSi_S5itcfC`
(6 labels, each `Int`), conformances `2ObjectMapper8Mappable`,
`...12BaseMappable`. JSON keys: `portraitWidth, portraitHeight,
landscapeWidth, landscapeHeight, frameRate, bitRate` (ObjectMapper default
mapping = property name). This is byte-for-byte the field set of the Android
`RecordParams` class and of the 13-byte OK packet:

| Android `RecordParams` / OK packet field | iOS JSON key |
|---|---|
| portraitWidth / OK[2..3] | `portraitWidth` |
| portraitHeight / OK[4..5] | `portraitHeight` |
| landscapeWidth / OK[6..7] | `landscapeWidth` |
| landscapeHeight / OK[8..9] | `landscapeHeight` |
| frameRate / OK[10] | `frameRate` |
| bitRate (kbps) / OK[11..12] | `bitRate` |

`[INFERRED]` The extension receives exactly these six integers (via JSON instead
of the binary OK packet) from whoever owns the dash connection, then configures
`EYNH264VideoEncoder` with them: width/height by orientation
(`portrait` flag from `EYMirrorCommand.portrait`), fps and bitRate*1000.

### 4.2 `EYMirrorCommand` (struct, Mappable)

```swift
struct EYMirrorCommand { var command: Int; var portrait: Int }
```

`[INFERRED]` `command` = start/stop/rotate opcode understood by the extension;
`portrait` = 1 for portrait / 0 for landscape; JSON `{"command":N,"portrait":N}`.

Note: the original hypothesis mentioned a `MirrorCommand` enum, but the
recovered metadata shows a Swift **struct** `EYMirrorCommand {command: Int,
portrait: Int}` (and `EYMirrorState {state: Int}`), not an enum. The only real
enum in the picture is the app-side `EYLinkState` / `EYMirrorLinkState` state
enum and the Android `Parser.Func` byte enum (`EYFunc`, section 5.3). So the
dash-facing opcodes are the video/audio/start/stop/wh/ack bytes of EYLink v1;
the iOS v2 control plane uses these JSON structs instead.

### 4.3 `EYMirrorState` (struct, Mappable)

```swift
struct EYMirrorState { var state: Int }
```

`[INFERRED]` extension -> peer state notification, JSON `{"state":N}`. Values
are not recoverable statically; the app exposes `EYMirrorLinkState` /
`EYLinkState` enums and `mirrorStatus:error:` callbacks.

### 4.4 `EYMirrorTCPHeaderData` (struct) - per-message header for the TCP channels

Stored properties, in metadata order:

| # | property | type | meaning `[INFERRED]` |
|---|---|---|---|
| 1 | `prefix` | `[UInt8]` | magic/start bytes (compare Android `AA BB CC`) |
| 2 | `agreementVersion` | `[UInt8]` | protocol/agreement version |
| 3 | `socketType` | `[UInt8]` | channel id (command vs data socket) |
| 4 | `dataType` | `[UInt8]` | payload kind (JSON state/config/command vs video) |
| 5 | `isVideo` | `[UInt8]` | 1 = video payload |
| 6 | `videoAngle` | `[UInt8]` | screen rotation angle delivered to the dash |
| 7 | `reserved` | `[UInt8]` | reserved / padding |
| 8 | `payloadSize` | `[UInt8]` | payload length (multi-byte, see 4.6) |

Computed: `videoDataType` (derived from socketType/dataType/isVideo),
`header: Data` (serialises the struct).
Inits: `init(data: Data)` (parse incoming header),
`init(socketType:dataType:payloadSize:)` (build outgoing header; mangled
`...10socketType04dataI011payloadSizeACSays5UInt8VG_A2ItcfC`).

### 4.5 `EYMirrorUDPHeaderData` (struct) - datagram header used for discovery

| # | property | type | meaning `[INFERRED]` |
|---|---|---|---|
| 1 | `prefix` | `[UInt8]` | magic |
| 2 | `agreementVersion` | `[UInt8]` | version |
| 3 | `commandPort` | `[UInt8]` | TCP command port (announced so peer can connect) |
| 4 | `dataPort` | `[UInt8]` | TCP data/video port |
| 5 | `payloadSize` | `[UInt8]` | payload length (0 for pure announcement) |
| 6 | `reserved` | `[UInt8]` | reserved |

Computed `header: Data`; init `init(commandPort:dataPort:payloadSize:)`
(mangled `...11commandPort04dataI011payloadSizeACSays5UInt8VG_A2ItcfC`),
init `init(data:)`.

This is the key discovery mechanism: a datagram that says "connect to my TCP
ports X (command) and Y (data)". The ports are `Int` properties of
`EYSampleLinkManager`, chosen by `bindServerPortInRange`/`randomInRange`.

### 4.6 `EYHexTransformer` (class) - endianness helper

```swift
final class EYHexTransformer {
    class func bigEndianBytesWithSize(_ size: Int, bytesCount: Int) -> [UInt8]?
    class func sizeWithBigEndianBytes(_ bytes: [UInt8]) -> Int
    class func littleEndianBytesWithSize(_ size: Int, bytesCount: Int) -> [UInt8]?
    class func sizeWithLittleEndianBytes(_ bytes: [UInt8]) -> Int
}
```

`[PROVEN-IOS-META]` Both endian helpers exist. `[INFERRED]` the v2 headers pad
multi-byte fields big-endian (the class is named big-endian first and the
main-app usage names it for size fields). NOTE: this is the **iOS v2 header**
layer; the dash-facing EYLink v1 protocol is little-endian (section 5). Do not
mix the two.

### 4.7 Candidate byte layout for the v2 headers `[INFERRED]`

No header size literal is readable. The most consistent layout with the field
list and with the Android 12-byte header (3-byte prefix + 1 type byte + 4-byte
reserved + 4-byte length) is a 16-byte TCP header and a 16-byte UDP header:

```
TCP (16 bytes):
off 0..2   prefix           3 bytes   (candidate: AA BB CC)
off 3      agreementVersion 1 byte
off 4      socketType       1 byte
off 5      dataType         1 byte
off 6      isVideo          1 byte    (1 = video payload)
off 7      videoAngle       1 byte    (0/90/180/270 style integer)
off 8..11  reserved         4 bytes
off 12..15 payloadSize      4 bytes   (byte count of payload; BE per EYHexTransformer)
off 16..   payload

UDP (16 bytes):
off 0..2   prefix           3 bytes
off 3      agreementVersion 1 byte
off 4..5   commandPort      2 bytes
off 6..7   dataPort         2 bytes
off 8..11  reserved         4 bytes
off 12..15 payloadSize      4 bytes
off 16..   payload
```

Every element of this layout is a guess about array lengths (`[UInt8]` allows
0..N bytes); it is listed so an implementer knows what to look for on the wire.
Verify with a packet capture (section 7) before coding against it.

---------------------------------------------------------------------------

## 5. EYLink v1 - the dash wire protocol `[PROVEN-ANDROID]`

This is the protocol the dash actually speaks today; it is fully readable in
`jadxout/sources/com/eryanet/ite/` (`socket/Parser.java`,
`socket/ClientSocket.java`, `socket/ServerSocket.java`,
`socket/ClientDataHandler.java`, `socket/ServerDataHandler.java`,
`socket/ByteUtil.java`, `Constants.java`, `model/RecordParams.java`,
`fragment/link/main/LinkFragment.java`, `R2.java`).

### 5.1 Network constants

| item | value | evidence |
|---|---|---|
| dash IP | `192.168.43.1` | `Constants.SERVER_IP` |
| dash hotspot SSID (Android app) | `iteAP`, `iteAP-xxxx` | docs/manual text in Android app |
| dash hotspot SSID (iOS app) | prefix `ZXMOTO-` | main-app JS string, offset 0x66360 in `app-view.js` pool |
| mirror data port | **11111** | `R2.id.bnav_enlarge_bottom_shadow = 11111`; `LinkFragment.port1` |
| message/JSON port | **11113** | `Constants.TCP_PORT_MESSAGE`; `LinkFragment.port2` |
| car-OTA port | **11112** | `Constants.TCP_PORT`; `update/car/CarUpgrade.java` |
| phone local UDP bind | 11111 (same as remote port) | `new DatagramSocket(port)` in `ClientSocket` |
| socket buffers | SO_SNDBUF/SO_RCVBUF 524288, or `tempBufferLength` preference | `ClientSocket` |
| connect timeout | 3000 ms | `ClientSocket` |
| heartbeat timeout | 12000 ms | `TIMEOUT_INTERVAL`, `checkTimeout` |
| lag threshold | 2000 ms | `MIRROR_LAG_THRESHOLD` |
| max MIRROR_START size | 2560 (long edge cap) | `ClientSocket.sendMirrorStart` |

### 5.2 Packet header (12 bytes)

```
offset size field
0      1    0xAA  magic0
1      1    0xBB  magic1
2      1    0xCC  magic2
3      1    func  function/opcode (table 5.3)
4      4    0x00  reserved (never used)
8      4    length payload length, unsigned LITTLE-endian 32-bit
12     ...  payload
```

`ServerSocket.isPackage()` validates bytes 0..2 == `AA BB CC` and computes
`len = ByteUtil.byte4ToInt(buf[8..11])` where
`byte4ToInt = b0 | b1<<8 | b2<<16 | b3<<24` (little-endian).
`ByteUtil.intTo4Bytes`/`intTo2Bytes` are likewise little-endian; `byte2ToInt`
is little-endian; `getBytes`/`getChars` are US-ASCII; `bigIntTo4Bytes` is
big-endian and is used only by the JSON control channel (5.6).

### 5.3 Function bytes

| func | name | payload |
|---|---|---|
| 0x00 | VIDEO_DATA | `LE32 timestamp_ms` + Annex-B H.264 byte stream |
| 0x01 | AUDIO_DATA | not used by the mirror feature |
| 0x02 | WIFI_SSID | Wi-Fi provisioning (phone->dash, other feature) |
| 0x03 | WIFI_PASSWORD | Wi-Fi provisioning |
| 0x04 | MIRROR_START | `LE16 min(w,h)` + `LE16 max(w,h)` |
| 0x05 | MIRROR_STOP | empty |
| 0x06 | WIDTH_HEIGHT | `LE16 w` + `LE16 h` |
| 0x0F | ACK | ASCII JSON, 0 < len < 50 |

### 5.4 Dash reply to MIRROR_START: the 13-byte `OK` packet

```
offset size field
0      2    ASCII 'O','K'            (0x4F, 0x4B)
2      2    portraitWidth   LE16
4      2    portraitHeight  LE16
6      2    landscapeWidth  LE16
8      2    landscapeHeight LE16
10     1    frameRate       uint8
11     2    bitRate         LE16 (kbps)
```

`ClientDataHandler`: any value that is odd is rounded UP (+1) before use.
`startRecord(RecordParams(portraitW, portraitH, landscapeW, landscapeH,
frameRate, bitRate))`. The dash picks and returns these; the phone should use
them verbatim (the phone's own requested size only seeds MIRROR_START).

`ServerDataHandler` (dash side) builds defaults for a clientless case:
`RecordParams(w, h, h, w, 60, 10000)` -> fps 60, bitrate 10000 kbps, i.e. the
vendor default profile is 60 fps / 10 Mbps before negotiation.

### 5.5 VIDEO_DATA payload

```
offset size field
0      4    timestamp ms, LE32, = now - startTime (reset on every MIRROR_START send)
4      ...  Annex-B H.264 access unit (start codes 00 00 00 01 / 00 00 01)
```

Receiver strips the first 16 bytes (12 header + 4 timestamp) and feeds the rest
to the decoder. Keyframe test used by the vendor client: scan for start code
`00 00 00 01` and check `(byte & 0x1F) == 5` (IDR). Vendor sends SPS/PPS as
separate Annex-B frames before/at stream start and on format change.

### 5.6 ACK (func 0x0F) JSON on the mirror channel

Frame: 12-byte header with func 0x0F, LE32 JSON length in bytes 8..11, then
UTF-8 JSON (length must satisfy 0 < len < 50 for the vendor client to consume
it):

- payload contains `"ver"` -> heartbeat; reset 12 s timeout;
- payload contains `"ack"` -> ACK;
- payload contains `"timestamp"` -> `{"timestamp":"<milliseconds>"}`: the dash
  playback clock used for A/V catch-up (see 5.8).

Also tolerated on this channel: a legacy 15-byte `'T','P' + 13 bytes` packet
(read and ignored by the vendor client), and the 13-byte `OK`.

### 5.7 Control/JSON channel TCP 11113

Frame format (10-byte header):

```
offset size field
0      1    'E' (0x45)
1      1    'Y' (0x59)
2      4    jsonLength   BE32
6      4    extraLength  BE32
10     n    JSON (UTF-8)
10+n   m    extra bytes (may contain a JSON byte array)
```

`[PROVEN-ANDROID]` known JSON messages: dash->phone `fun` = `mirrorControl`
(`type=="0"` = dash asks to stop mirroring), `closeHeart`, `funSwitch`,
`active`, plus weather/navigation payloads; phone->dash `{"fun":"mirror",
"type":"0"}` to stop mirroring. The mirror feature itself does NOT require this
channel (the vendor app connects it opportunistically; failures are ignored).

### 5.8 Session state machine (dash-facing, from `ClientSocket`)

```
IDLE
  -> (Wi-Fi joined; local IP on same /24 as 192.168.43.1)
CONNECTING
  TCP connect 192.168.43.1:11111 (3000 ms timeout)
  [fallback transport: UDP, see 5.9]
  -> connected
NEGOTIATING
  every 500..1000 ms send MIRROR_START(min,max)      (resets startTime each send)
  retry up to ~15..30 attempts
  -> receive 13-byte OK -> apply RecordParams, start encoder, stop retry timer
STREAMING
  send VIDEO_DATA frames with LE32 (now-startTime)
  every ACK JSON: heartbeat ok / timestamp -> carTime
  if |(now-startTime) - carTime| > 2000 ms:
      waitingForKeyFrameAfterLag = true (drop non-keyframes, ask encoder for IDR)
      leave when a keyframe goes out; when lag <= 2000 and still waiting, request
      one extra keyframe ("setIF")
  every >12 s without heartbeat JSON: declare timeout, report disconnected
  periodically send WIDTH_HEIGHT while the display size is changing (the vendor
  sends it ~every 2 s)
STOPPING
  send MIRROR_STOP (12-byte packet, empty payload), close sockets
```

Backpressure/queueing rules used by the vendor (worth copying): if pending UDP
frames > 30 -> enter "wait for keyframe" mode and drop until the next IDR; when
the 60-frame temporary buffer fills, the measured byte sum * 3 is persisted as
`tempBufferLength` and used as socket buffer size for the TCP fallback.

### 5.9 Transports (dash-facing)

- Primary: **TCP 11111** (`startTCPMirrorClient(11111)`), keepAlive=true,
  tcpNoDelay=true; bind the local socket to the Wi-Fi/p2p interface whose IPv4
  is in the same /24 as `192.168.43.1` (`getP2pLocalIp`, interface names
  `p2p*` or `wlan*`).
- Alternative used by the vendor for old Bluetooth-provisioned units:
  **UDP** - `DatagramSocket(11111)` (bind LOCAL port 11111), SO_SNDBUF/RCVBUF
  524288, send datagrams to `192.168.43.1:11111`, receive dash replies on the
  same socket (`startUDPMirrorClient`). Each datagram is one complete EYLink
  packet.
- Control: TCP 11113 (`startTCPClient(11113)`), same local-interface binding.

### 5.10 Screen size catalogue (vendor whitelist)

`ScreenConstants.SupportWidHeight` (strings, `W*H`):
`800*352, 800*576, 1024*600, 800*356, 800*480, 800*600, 624*480, 480*560,
1024*470`. `ScreenConstants.SupportCarAppId` = 9 md5 hex ids (car-app
allowlist). The phone sends its own window size capped at long edge 2560 in
MIRROR_START and then obeys the OK reply.

### 5.11 Encoder settings used by the vendor client `[PROVEN-ANDROID]`

`video/avc`, CBR (`bitrate-mode=2`), bitrate = OK bitRate(kbps) * 1000,
frame-rate = OK fps, i-frame-interval = 2 s, input Surface, resolution = OK
portrait or landscape size, SPS/PPS sent separately at start / on format change.

---------------------------------------------------------------------------

## 6. EYMirror v2 - iOS extension protocol `[PROVEN-IOS-META fields + INFERRED wire]`

The extension module defines a header/JSON scheme that differs from EYLink v1.
It is fair to call it "EYMirror v2": it adds `agreementVersion` (negotiable
protocol version), explicit `socketType`/`dataType` multiplexing, `isVideo`
and `videoAngle`, and dynamic TCP server ports announced over UDP.

### 6.1 Control-plane messages (JSON, ObjectMapper)

`EYMirrorConfiguration` (6 ints, keys in 4.1) - sent to the extension who
parses it in `parsingConfigurationData(_:)` and installs it in
`setConfiguration()`.

`EYMirrorCommand` `{"command":Int,"portrait":Int}` - parsed by
`parsingCommandData(_:)`. `[INFERRED]` command values: start / stop / rotate;
portrait selects which width/height pair to use.

`EYMirrorState` `{"state":Int}` - emitted by `sendStateInfo()`; the main app
consumes it in `parsingMirrorStateData(_:)`. This maps to the app-visible
`EYMirrorLinkState` / `EYLinkState` enum (`mirrorStatus:EYLinkState`,
`mirrorLinkState:error:` callbacks, `LinkStateDidChangeNotification`).

`[INFERRED]` heartbeat: `handleHeartbeat()` in the extension + Android `ACK`
semantics suggests a periodic JSON message carrying `"ver"` and/or
`"timestamp"` fields is accepted/emitted; the extension also exposes a
`stopBroadcast: String?` property (a message/instruction that terminates the
broadcast session).

### 6.2 Video-plane framing

Encoded frames are handed to `sendVideoData(_:isKey:)`; the link manager wraps
them with `EYMirrorTCPHeaderData(socketType:dataType:payloadSize:)`, setting
`isVideo = 1`, `videoAngle` from `angleWithScreenRotation(_:)`
(`CGImagePropertyOrientation` -> int angle), and sends on the data socket.
JSON messages go through `sendCommandData(_:)` on the command socket with the
JSON dataType. Candidate bytes in 4.7.

### 6.3 Discovery / connection

`EYSampleLinkManager.start()` `[INFERRED]`:
1. resolve `localHost` (local Wi-Fi IPv4 via `getifaddrs`),
2. `randomInRange(range)` + `bindServerPortInRange(range:socket:retryCount:)`
   to bind the command server socket and the data server socket on free TCP
   ports,
3. open `udpSocket` (send-only: `didSendDataWithTag:`/
   `didNotSendDataWithTag:dueToError:` exist, `didReceiveData:...` does not) and
   send `EYMirrorUDPHeaderData(commandPort:dataPort:payloadSize:)` to the peer
   (dash) so it can dial back; `dataHandler`/`stateHandler` report accepted
   sockets and decoded messages,
4. on `socket:didAcceptNewSocket:` start reading `EYMirrorTCPHeaderData` via
   `parsingTcpHeaderData(_:)` (returns bytes consumed), tag-based reads then
   deliver `(tcpHeader, payload)` to the handler; `sendVideoData`/`sendCommandData`
   write back.

Open items that cannot be resolved without the encrypted code or a capture:
the port range constant, the dash UDP destination port/address used for the
announcement, the `prefix` bytes, the exact header sizes, and the numeric enum
values of `command`/`state`/`socketType`/`dataType`.

---------------------------------------------------------------------------

## 7. How to verify the remaining unknowns (recommended next step)

1. Capture on a real iPhone while running the official ZXMOTO app + broadcast:
   `rvictl -s <UDID>` then Wireshark on the `rvi0` interface; filter
   `tcp.port == 11111 || tcp.port == 11113 || udp.port == 11111 || udp` and
   also `ip.addr == 192.168.43.1`.
2. Look for the first datagram sent right after the user starts the broadcast:
   its payload identifies the real v2 `prefix`, header size and announced TCP
   ports. Then find the TCP handshake to those ports.
3. Dump the first TCP payloads (command channel): they are the JSON
   configuration/command/state strings described in 6.1.
4. Confirm H.264 framing on the data channel: 16-byte header candidate +
   payload; check whether payload starts with `00 00 00 01` + SPS NAL (0x67)
   for the first packet.
5. If the capture matches EYLink v1 (12-byte `AA BB CC`), use section 5 only.

---------------------------------------------------------------------------

## 8. What a CarWithin clone must send/receive

CarWithin is an app (screen input already available as H.264/Annex-B or
CVPixelBuffer from its own capture pipeline; it is NOT a ReplayKit extension).
The most reliable target is the dash-facing EYLink v1 protocol of section 5,
because it is the protocol of the physical 500RR / 820R dash.

### 8.1 Prerequisites

```
1. Join the dash hotspot:
   SSID matches prefix "ZXMOTO-" (iOS app) or "iteAP" (Android app)
   via NEHotspotConfigurationManager (requires the
   com.apple.developer.networking.HotspotConfiguration entitlement).
   The dash runs the DHCP server; phone IPv4 is in 192.168.43.0/24,
   gateway/dash = 192.168.43.1.
2. Find the local Wi-Fi IPv4 (getifaddrs, en0/utun; keep the one in the
   192.168.43.0/24 subnet); bind sockets to it (do NOT bind 0.0.0.0 for UDP,
   the dash replies to the source port).
```

### 8.2 Session pseudocode

```swift
// Constants
let dashIP = "192.168.43.1"
let mirrorPort = 11111
let messagePort = 11113
let okMagic: [UInt8] = [0x4F, 0x4B]          // "OK"
let eylinkMagic: [UInt8] = [0xAA, 0xBB, 0xCC]

enum EYFunc: UInt8 { case video = 0, audio = 1, wifiSsid = 2, wifiPassword = 3,
                     mirrorStart = 4, mirrorStop = 5, widthHeight = 6, ack = 15 }

// Little-endian helpers - EYLink v1 is LITTLE-endian everywhere
func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                     UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
func le16read(_ b: ArraySlice<UInt8>, _ i: Int) -> Int {
    Int(b[b.startIndex + i]) | Int(b[b.startIndex + i + 1]) << 8
}
func le32read(_ b: ArraySlice<UInt8>, _ i: Int) -> Int {
    Int(b[b.startIndex + i]) | Int(b[b.startIndex + i + 1]) << 8
    | Int(b[b.startIndex + i + 2]) << 16 | Int(b[b.startIndex + i + 3]) << 24
}

func packet(_ f: EYFunc, _ payload: [UInt8]) -> [UInt8] {
    [0xAA, 0xBB, 0xCC, f.rawValue, 0, 0, 0, 0] + le32(payload.count) + payload
}

// MIRROR_START: phone's current screen size, long edge capped at 2560
func mirrorStart(_ w: Int, _ h: Int) -> [UInt8] {
    packet(.mirrorStart, le16(min(w, h)) + le16(min(max(w, h), 2560)))
}
func mirrorStop() -> [UInt8] { packet(.mirrorStop, []) }
func widthHeight(_ w: Int, _ h: Int) -> [UInt8] {
    packet(.widthHeight, le16(w) + le16(h))
}
func videoFrame(_ tsMS: Int, _ annexB: [UInt8]) -> [UInt8] {
    packet(.video, le32(tsMS) + annexB)
}

// ---- 1. mirror channel: TCP 11111 (UDP 11111 fallback) ----
// TCP: connect 192.168.43.1:11111 (timeout 3 s, tcpNoDelay, keepAlive,
//      bind local 192.168.43.x:0)
// UDP: bind local 192.168.43.x:11111, send datagrams to 192.168.43.1:11111,
//      each datagram is one complete packet; receive dash replies on that socket.
var startTime = DispatchTime.now()
var attempts = 0
var configured = false
var carTimeMS: Int? = nil
var waitingForKeyFrame = false

startTimer(interval: 0.5) {                     // retry MIRROR_START until OK
    if configured { cancelTimer(); return }
    attempts += 1
    if attempts > 15 {
        if transportIsUDP { switchMirrorTransportToTCP(); resetAttempts() }
        else { report("dash did not answer MIRROR_START") ; return }
    }
    startTime = DispatchTime.now()              // reset timestamp basis on EVERY send
    waitingForKeyFrame = false
    send(mirrorStart(screenW, screenH))
}

// ---- 2. incoming packets on the mirror channel (stream parser for TCP) ----
func onMirrorBytes(_ buf: inout [UInt8]) {
    while true {
        if buf.count >= 2 && buf[0] == 0x4F && buf[1] == 0x4B {          // "OK"
            guard buf.count >= 13 else { return }                        // wait
            let p = buf[0..<13]; buf.removeFirst(13)
            onOK(p)
        } else if buf.count >= 2 && buf[0] == 0x54 && buf[1] == 0x50 {   // "TP" legacy
            guard buf.count >= 15 else { return }; buf.removeFirst(15)   // ignore
        } else if buf.count >= 12 && buf[0] == 0xAA && buf[1] == 0xBB && buf[2] == 0xCC {
            let len = le32read(buf[0..<12], 8)
            guard len >= 0 && len <= 65535 && buf.count >= 12 + len else { return }
            let f = EYFunc(rawValue: buf[3]) ?? .audio
            let payload = Array(buf[12..<(12 + len)])
            buf.removeFirst(12 + len)
            if f == .ack { onAckJSON(payload) }          // heartbeats / timestamp
        } else {
            buf.removeFirst(1)                           // resync
        }
    }
}

func onOK(_ b: ArraySlice<UInt8>) {
    guard !configured else { return }
    func even(_ v: Int) -> Int { v % 2 == 0 ? v : v + 1 }   // vendor rounds up
    let pW = even(le16read(b, 2)),  pH = even(le16read(b, 4))
    let lW = even(le16read(b, 6)),  lH = even(le16read(b, 8))
    let fps = Int(b[b.startIndex + 10])
    let bitrateKbps = le16read(b, 11)
    let (w, h) = (lW > 0 && lH > 0 && isLandscape) ? (lW, lH) : (pW, pH)
    guard w >= 160, h >= 160, fps > 0 else { return }      // sanity
    configured = true                                      // stop retry timer
    let bitrate = bitrateKbps > 0 ? bitrateKbps * 1000 : 4_000_000
    configureEncoder(width: w, height: h, fps: min(fps, 60), bitrate: bitrate,
                     keyframeIntervalSeconds: 2)
    requestKeyframe()
    report("dash ready \(w)x\(h) @\(fps)fps")
}

// ---- 3. ACK (func 0x0F) JSON ----
func onAckJSON(_ payload: [UInt8]) {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
    else { return }
    lastHeartbeat = now()
    if obj["ver"] != nil { /* heartbeat */ }
    if obj["ack"] != nil { /* ack */ }
    if let t = obj["timestamp"] {
        carTimeMS = Int("\(t)")               // dash clock, milliseconds
    }
}

// ---- 4. video send with lag / heartbeat handling ----
func sendVideo(_ annexB: [UInt8], isKey: Bool) {
    if configured == false { return }
    if now() - lastHeartbeat > 12.0 { report("dash heartbeat timeout"); teardown(); return }
    let ts = Int((now() - startTime) * 1000)
    if let car = carTimeMS {
        let lag = abs(ts - car)
        if lag > 2000 { waitingForKeyFrame = true }
    }
    if waitingForKeyFrame && !isKey { requestKeyframe(); return }   // drop non-IDR
    if waitingForKeyFrame && isKey { waitingForKeyFrame = false }
    if !isKey && inFlight > 10 { return }                            // backpressure
    inFlight += 1
    send(videoFrame(ts, annexB)) { inFlight -= 1 }
    if waitingForKeyFrame { /* none */ }
}

// ---- 5. teardown ----
func cancel() {
    send(mirrorStop())
    closeMirrorChannel()
    closeMessageChannel()
}
```

### 8.3 What must be received / accepted

| direction | message | action |
|---|---|---|
| dash -> phone | 13-byte `OK` | apply encoder W/H/fps/bitrate, stop MIRROR_START retries |
| dash -> phone | `AA BB CC 0F <len> <json>` | heartbeat (`ver`), ack (`ack`), dash clock (`timestamp`) |
| dash -> phone | `'T','P'` + 13 bytes | ignore (legacy) |
| dash -> phone | (TCP 11113) `'E','Y' + BE32 jsonLen + BE32 extraLen + JSON` | optional: handle `fun=mirrorControl&type=0` as "stop mirroring" |
| phone -> dash | `MIRROR_START`, `VIDEO_DATA`, `WIDTH_HEIGHT`, `MIRROR_STOP` | as in 8.2 |

### 8.4 Gotchas

- Endianness: EYLink v1 is little-endian for the length field, the OK size
  fields, the video timestamp and MIRROR_START dimensions. A big-endian client
  (such as the earlier CarWithin experiment) will not be understood.
- Timestamps: reset the timestamp basis every time MIRROR_START is sent; the
  dash compares the timestamp with its own clock and permanently drops to
  keyframe-only mode if the axes differ.
- UDP mirror requires binding the LOCAL port 11111 on the Wi-Fi interface; if
  the OS refuses (address in use), fall back to TCP 11111 first (the vendor
  uses TCP by default and UDP only on the Bluetooth-provisioned path).
- The dash tolerates a missing control channel: do not block mirroring on
  11113.
- Hotspot SSID may carry a suffix (`ZXMOTO-xxxx`); match by prefix. iOS also
  needs the HotspotConfiguration entitlement and the user's approval prompt.
- Do not send H.264 as AVCC/length-prefixed: the dash expects Annex-B start
  codes. Send SPS/PPS separately at stream start and after every format change.
- Keyframe interval 2 s, CBR, `dash-frameRate` / `dash-bitrate*1000`; never
  exceed the negotiated size, and prefer the negotiated even values.

### 8.5 Where the iOS app-specific extra knowledge helps

If a firmware/app build is found that speaks EYMirror v2 instead of EYLink v1
(agreement version + JSON), the same Java-free Swift contract applies: parse
the JSON keys of section 4.1, use a header of the candidate shape of 4.7 with
big-endian size fields, and expect dynamic server ports to be announced over
UDP (section 4.5). This is exactly the layer the official iOS extension speaks
internally.

---------------------------------------------------------------------------

## 9. Evidence appendix

### 9.1 Mach-O facts (extension)

| item | value |
|---|---|
| file | `_analyze_zxmoto/Payload/HBuilder.app/PlugIns/MotorMirror.appex/MotorMirror` |
| size | 729,952 bytes |
| slices | arm64 thin (`0xFEEDFACF`) |
| LC_ENCRYPTION_INFO_64 | cryptoff 0x4000, cryptsize 0x84000, cryptid 1 |
| __TEXT | vm 0x100000000, vsize 0x88000, off 0, filesize 0x88000 |
| __DATA.__objc_classlist | 0x10008c3a8 (0xb0 = 22 entries) |
| __DATA.__objc_const | 0x10008c4a8, size 0x68b0 |
| __DATA.__objc_data | 0x100094040, size 0x1148 |
| __DATA.__const | 0x100089108, size 0x1660 |
| __DATA.__cfstring | 0x10008a768, size 0x1c40 (226 entries, 32 B each: isa, flags 0x7c8, cstr ptr into encrypted __cstring, length) |
| __LINKEDIT | off 0x98000, filesize 0x1a360 |
| SYMTAB | symoff 0xa3d68, nsyms 428 (1 local, 68 extdef, 359 undef) |
| EXPORT TRIE | off 0x9daa0, size 0x58d8, 838 symbols recovered |
| BIND | off 0x98510 size 0x1ed8; LAZY_BIND off 0x9a400 size 0x36a0 |
| FUNCTION_STARTS | 0xa3378 size 0x9f0 |
| CODE_SIGNATURE | 0xa9320 size 0x9040 (entitlements plist inside) |
| Entitlements | team 3Z8W7XAD6M; application-identifier 3Z8W7XAD6M.com.zxjc.mirror; no groups |
| Info.plist | com.zxjc.mirror, broadcast-services-upload, SampleHandler, RPBroadcastProcessModeSampleBuffer, MinimumOSVersion 12.1, SDK iphoneos26.2, Xcode 2630, version 1.4.5 (10045) |

### 9.2 Swift symbols (extension; from `tmp/zx_exports.txt`)

- `_$s22EryaMirrorExtensionKit21EYMirrorConfigurationV...` - 6 Int stored props,
  init with 6 labels, ObjectMapper conformances.
- `_$s22EryaMirrorExtensionKit21EYMirrorTCPHeaderDataV...` - 8 stored array
  props + computed `videoDataType`/`header`, 2 inits.
- `_$s22EryaMirrorExtensionKit21EYMirrorUDPHeaderDataV...` - 6 stored array
  props + computed `header`, 2 inits.
- `_$s22EryaMirrorExtensionKit15EYMirrorCommandV` (mangled name length prefix
  15 = "EYMirrorCommand"), `_$s22EryaMirrorExtensionKit13EYMirrorStateV`
  (prefix 13 = "EYMirrorState"), both `Mappable`/`BaseMappable` and both
  export `mapping(map:)`; e.g. `...15EYMirrorCommandV8portraitSivs`,
  `...13EYMirrorStateV5stateSivg`.
- `_$s22EryaMirrorExtensionKit16EYHexTransformerC...` -
  `bigEndianBytesWithSize`, `sizeWithBigEndianBytes`,
  `littleEndianBytesWithSize`, `sizeWithLittleEndianBytes`.
- `_$s22EryaMirrorExtensionKit19EYSampleLinkManagerC...` - sockets, ports,
  `localHost`, delegate callbacks, `bindServerPortInRange`, `randomInRange`,
  `parsingTcpHeaderData`.
- `_$s22EryaMirrorExtensionKit15EYSampleManagerC...` - `startService`,
  `stopService`, `parsingReadHeader(header:data:)`,
  `parsingConfigurationData`, `parsingCommandData`, `setConfiguration`,
  `sendStateInfo`, `sendVideoData(_:isKey:)`, `handleHeartbeat`,
  `angleWithScreenRotation`, encoder callbacks, `stopBroadcast`.
- `_$s22EryaMirrorExtensionKit21EYMirrorSampleManagerC...` - ReplayKit bridge
  (`broadcastStarted`, `broadcastFinished`, `processSampleBuffer`).

### 9.3 Main app evidence (`_analyze_zxmoto/Payload/HBuilder.app/HBuilder`)

Plaintext name-pool hits (absolute file offsets; found by `tmp/hb_find2.py`):

| identifier | offset |
|---|---|
| `sendMirrorCommand`, labels `_8portrait` | 0x5679475 |
| `parsingReadHeader` (private hash D657D90B...) | 0x5679405 |
| `handleHeartbeat` | 0x56791fe |
| `waitForKeyFrame` | 0x5679292 |
| `parsingVideoData` | 0x567937d |
| `parsingMirrorStateData` | 0x56795e5 |
| `resumeMirrorConnection` | 0x5679637 |
| `stopMirrorConnection` | 0x5679698 |
| `startMirrorConnection` | 0x56796b6 |
| `couldSendMirrorData` | 0x567957e |
| `mirrorBufferPool` | 0x5679352 |
| `mirrorCacheLock` | 0x5679239 |
| `mirrorStatus: EYLinkState` | 0x567951f |
| `EYLinkClient` | 0x56e190f |
| `EYLinkUpdate` | 0x56e2653 |
| `EYMirrorConfiguration` | 0x56c9e04, 0x56d44c9 |
| `HotspotStatus` | 0x56dbd4a, 0x56e3816 |
| `EYNH264VideoEncoder` | 0x56ca17d |
| `commandPort` | 0x56a43df, 0x56b1b8c |
| `dataPort` | 0x56a4cf6, 0x56b1d05 |
| `agreementVersion` | 0x56b1890, 0x56b1c06 |
| `socketType` | 0x56b17b4 |
| `portraitWidth` | 0x56b14cb |
| `bitRate` | 0x56b1543 |
| `frameRate` | 0x56b13b5, 0x56b1621, 0x567986c |
| `HotspotConfiguration` entitlement | 0x5ab5dce |
| app group `group.com.zxjc.widget` | 0x5ab5cc8, 0x5ab5ea1 |
| `applinks:zxjc.cqzxmoto.com` | 0x5ab5c65 |
| hotspot SSID hint `ZXMOTO-` (JS string) | `www/app-view.js` (offset in bundle 0x66360) |

Main app additional classes/APIs of interest: `EYMirrorManager`,
`MirrorManagerDelegate`, `EYMirrorLinkState`, `EYNMirrorButton`, `MirrorTimer`,
`EYHotspotInfo`, `HotspotConnector`, `EYBlueHotspot`, `EYPeripheralDevice`,
`connectPeripheralWithNameHasPrefix(_:)`, `targetPrefix[Array]`,
`getDevicePrefixList`, `connectToNavigationServer`, `applyHotspotConfiguration`,
`checkoutHotspotConfiguration`, `hotspotStatusHandler`, `LinkStateDidChangeNotification`.

### 9.4 Android evidence files

`jadxout/sources/com/eryanet/ite/`: `socket/Parser.java`,
`socket/ClientSocket.java` (825 lines), `socket/ServerSocket.java`,
`socket/ClientDataHandler.java`, `socket/ServerDataHandler.java`,
`socket/ByteUtil.java`, `Constants.java`, `ScreenConstants.java`,
`model/RecordParams.java`, `fragment/link/main/LinkFragment.java`
(`port1=11111`, `port2=11113`), `R2.java` (`11111/11112/11113`, buffer 1472),
`recorder/ScreenRecorder.java`, `wifi/WifiServer.java`,
`update/car/CarUpgrade.java` (11112 = car OTA).

### 9.5 Reproduction scripts (all under `tmp/`)

| script | purpose |
|---|---|
| `zx_macho.py` | arm64 Mach-O parser (sections, segments, symtab, addr->off) |
| `zx_trie.py` | parses the extension's dyld export trie -> `zx_exports.txt` (838 Swift symbols) |
| `zx_exports_view.py` / `zx_types.txt` | groups exported symbols per type |
| `ey_members.py` | extracts member identifier names per type |
| `appex_meta2.py` | extension symtab (imports/exports) + ObjC classlist with method counts -> `appex_meta2_out.txt` |
| `scan_appex_data.py` | scans plaintext `__DATA`/`__LINKEDIT` of the extension for ints/strings/CFStrings |
| `appex_entitle.py` | extracts entitlements + Info.plist keys -> `appex_entitle_out.txt` |
| `hb_sym.py` | main app header/symtab -> `hb_syms_kw.txt`, `hb_syms_swift.txt` |
| `hb_ascii.py` | main app plaintext ASCII harvest -> `hb_ascii.txt` (80,940 runs) |
| `hb_find2.py` | absolute offsets of EYLink/EYMirror identifiers in the main app |
| `hb_ctx.py` | dumps raw windows around app-side Swift metadata fragments |
| `scan_hbuilder.py` | keyword scan of the app bundle tree -> `hb_hits.txt` |

---------------------------------------------------------------------------

## 10. Open questions (ranked)

1. Does the iOS extension talk directly to the dash, or to the main app over
   loopback? Static evidence (extension = TCP server only, UDP send-only, no
   app group, no hotspot entitlement; main app = matching client + dash EYLink
   stack) favours a direct dash connection with UDP-announced dynamic ports,
   but a loopback-relay design is not fully excluded. Resolve by capture.
2. Exact v2 header sizes/prefix bytes and JSON message opcodes (`command`,
   `state`, `socketType`, `dataType` values) - not recoverable while `__TEXT`
   is encrypted; resolve by capture.
3. Default `EYMirrorConfiguration` values shipped in the extension (e.g. a
   fallback 800x480 / 30 fps / 4 Mbps) - the constants live in encrypted code.
   The dash always supplies real values in `OK`; Android server-side fallback is
   60 fps / 10 Mbps.
4. 820R panel resolution: still assume the dashboard's `OK` reply, not a fixed
   profile; 500RR and 820R supported-size strings are in `ScreenConstants`.
5. Whether any firmware expects the v2 `EYMirrorTCPHeaderData` framing instead
   of the v1 `AA BB CC` framing; until proven, implement v1 for the dash and
   keep the v2 contract documented for future adapters.
