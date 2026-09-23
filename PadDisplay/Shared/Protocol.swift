import Foundation

enum PadDisplayConstants {
    static let serviceType = "_paddisplay._tcp"
    static let defaultPort: UInt16 = 52100
    static let protocolVersion = 1
    static let maxMessageSize = 32 * 1024 * 1024
    /// iPad Pro (M4) 13" 패널 밀도
    static let iPadProPixelsPerInch = 264.0
}

/// 와이어 포맷: [type: UInt8][length: UInt32 BE][payload]
enum MessageType: UInt8 {
    case hello = 0x01            // iPad → Mac  JSON(ClientHello)
    case serverInfo = 0x02       // Mac → iPad  JSON(ServerInfo)
    case resize = 0x03           // iPad → Mac  JSON(ClientHello)
    case videoFormat = 0x10      // Mac → iPad  binary(VideoFormatMessage)
    case videoFrame = 0x11       // Mac → iPad  binary(VideoFrameMessage)
    case requestKeyframe = 0x12  // iPad → Mac  empty
    case input = 0x20            // iPad → Mac  JSON(InputEvent)
    case ping = 0x30             // iPad → Mac  UInt64 timestamp
    case pong = 0x31             // Mac → iPad  echo
}

struct ClientHello: Codable, Equatable {
    var protocolVersion = PadDisplayConstants.protocolVersion
    var deviceName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var pixelsPerInch: Double
    var maxFPS: Int
}

struct ServerInfo: Codable, Equatable {
    var hostName: String
    var codec: String
    var fps: Int
    var bitrateMbps: Int
    var displayPointWidth: Int
    var displayPointHeight: Int
}

enum MouseButton: Int, Codable, Hashable {
    case left, right, middle
}

enum ScrollPhase: Int, Codable {
    case began, changed, ended, momentumBegan, momentum, momentumEnded
}

/// 좌표(x, y)는 스트리밍 영상 기준 0...1 정규화 값. 스크롤 델타는 Mac 포인트 단위.
enum InputEvent: Codable {
    case move(x: Double, y: Double)
    case button(button: MouseButton, down: Bool, x: Double, y: Double)
    case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    /// usage: USB HID Keyboard page(0x07) usage ID
    case key(usage: Int, down: Bool)
    case releaseAll
}

struct VideoFormatMessage {
    var width: Int
    var height: Int
    /// HEVC VPS/SPS/PPS (start code 없음)
    var parameterSets: [Data]

    func encoded() -> Data {
        var w = ByteWriter()
        w.u32(UInt32(width))
        w.u32(UInt32(height))
        w.u8(UInt8(parameterSets.count))
        for set in parameterSets {
            w.u16(UInt16(set.count))
            w.bytes(set)
        }
        return w.data
    }

    static func decode(_ data: Data) -> VideoFormatMessage? {
        var r = ByteReader(data)
        guard let width = r.u32(), let height = r.u32(), let count = r.u8() else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let len = r.u16(), let set = r.bytes(Int(len)) else { return nil }
            sets.append(set)
        }
        return VideoFormatMessage(width: Int(width), height: Int(height), parameterSets: sets)
    }
}

struct VideoFrameMessage {
    var isKeyframe: Bool
    var ptsMicros: Int64
    /// AVCC 형식(4바이트 길이 prefix) NAL 유닛들
    var payload: Data

    func encoded() -> Data {
        var w = ByteWriter()
        w.u8(isKeyframe ? 1 : 0)
        w.u64(UInt64(bitPattern: ptsMicros))
        w.bytes(payload)
        return w.data
    }

    static func decode(_ data: Data) -> VideoFrameMessage? {
        var r = ByteReader(data)
        guard let flags = r.u8(), let pts = r.u64() else { return nil }
        return VideoFrameMessage(isKeyframe: flags & 1 != 0, ptsMicros: Int64(bitPattern: pts), payload: r.rest())
    }
}

extension Encodable {
    func jsonData() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() -> UInt8? { uint(UInt8.self) }
    mutating func u16() -> UInt16? { uint(UInt16.self) }
    mutating func u32() -> UInt32? { uint(UInt32.self) }
    mutating func u64() -> UInt64? { uint(UInt64.self) }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }

    mutating func rest() -> Data { bytes(remaining) ?? Data() }

    private mutating func uint<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) -> T? {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { return nil }
        var v: T = 0
        for b in data[offset..<(offset + n)] { v = (v << 8) | T(b) }
        offset += n
        return v
    }
}
