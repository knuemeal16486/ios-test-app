import Foundation
import Network
import QuartzCore

/// Mac 호스트와의 단일 연결. 영상은 네트워크 큐에서 바로 렌더러로 전달(메인 스레드 우회).
final class StreamLink {
    let connection: FramedConnection

    var onReady: (@Sendable () -> Void)?
    var onServerInfo: (@Sendable (ServerInfo) -> Void)?
    var onClosed: (@Sendable (Error?) -> Void)?

    private let renderer: VideoRenderer
    private var pingTimer: DispatchSourceTimer?
    private var lastKeyframeRequest: CFTimeInterval = 0

    private let statsLock = NSLock()
    private var frames = 0
    private var bytes = 0
    private var rttMillis: Double = 0

    let isWired: Bool

    convenience init(endpoint: NWEndpoint, renderer: VideoRenderer) {
        self.init(connection: NWConnection(to: endpoint, using: .padDisplay()), renderer: renderer, isWired: false)
    }

    /// USB 터널로 들어온(아직 start 안 된) 연결에도 사용
    init(connection nwConnection: NWConnection, renderer: VideoRenderer, isWired: Bool) {
        self.renderer = renderer
        self.isWired = isWired
        connection = FramedConnection(connection: nwConnection)
        connection.onReady = { [weak self] in
            self?.startPing()
            self?.onReady?()
        }
        connection.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        connection.onClose = { [weak self] error in
            self?.stopPing()
            self?.onClosed?(error)
        }
    }

    func start() { connection.start() }

    func close() {
        onClosed = nil
        connection.send(.input, InputEvent.releaseAll.jsonData())
        connection.close()
    }

    func sendHello(_ hello: ClientHello, isResize: Bool) {
        connection.send(isResize ? .resize : .hello, hello.jsonData())
    }

    func send(_ event: InputEvent) {
        connection.send(.input, event.jsonData())
    }

    func takeStats() -> (frames: Int, bytes: Int, rtt: Double) {
        statsLock.lock(); defer { statsLock.unlock() }
        let result = (frames, bytes, rttMillis)
        frames = 0
        bytes = 0
        return result
    }

    // MARK: - Private (connection.queue)

    private func handle(_ type: MessageType, _ payload: Data) {
        switch type {
        case .videoFormat:
            if let format = VideoFormatMessage.decode(payload) { renderer.setFormat(format) }
        case .videoFrame:
            guard let frame = VideoFrameMessage.decode(payload) else { return }
            statsLock.lock()
            frames += 1
            bytes += payload.count
            statsLock.unlock()
            if !renderer.enqueue(frame) { requestKeyframe() }
        case .serverInfo:
            if let info = try? JSONDecoder().decode(ServerInfo.self, from: payload) { onServerInfo?(info) }
        case .pong:
            var reader = ByteReader(payload)
            if let sent = reader.u64() {
                let rtt = Double(Self.nowMicros() &- sent) / 1000
                statsLock.lock()
                rttMillis = rtt
                statsLock.unlock()
            }
        default:
            break
        }
    }

    private func requestKeyframe() {
        let now = CACurrentMediaTime()
        guard now - lastKeyframeRequest > 0.5 else { return }
        lastKeyframeRequest = now
        connection.send(.requestKeyframe)
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: connection.queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1)
        timer.setEventHandler { [weak self] in
            var writer = ByteWriter()
            writer.u64(Self.nowMicros())
            self?.connection.send(.ping, writer.data)
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private static func nowMicros() -> UInt64 { UInt64(CACurrentMediaTime() * 1_000_000) }
}
