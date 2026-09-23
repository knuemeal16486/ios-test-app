import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// iPad 1대와의 스트리밍 세션: 캡처 → 인코딩 → 전송, 입력 수신 → 주입.
final class StreamSession {
    let connection: FramedConnection

    var onHello: (@Sendable (ClientHello) -> Void)?
    var onClosed: (@Sendable () -> Void)?
    var onCaptureError: (@Sendable (Error) -> Void)?

    private let capturer = ScreenCapturer()
    private let injector: InputInjector

    // capturer.queue 전용
    private var encoder: VideoEncoder?
    private var lastPixelBuffer: CVPixelBuffer?

    private let stateLock = NSLock()
    private var droppingUntilKeyframe = false
    private var congestionLimit = 1 << 20
    private var statFrames = 0
    private var statBytes = 0

    init(connection: FramedConnection) {
        self.connection = connection
        self.injector = InputInjector(queue: connection.queue)

        connection.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        connection.onClose = { [weak self] _ in
            guard let self else { return }
            self.injector.releaseAll()
            self.onClosed?()
        }
        capturer.onFrame = { [weak self] pixelBuffer in self?.encode(pixelBuffer) }
        capturer.onError = { [weak self] error in self?.onCaptureError?(error) }
    }

    func start() { connection.start() }
    func close() { connection.close() }

    func send(_ info: ServerInfo) { connection.send(.serverInfo, info.jsonData()) }

    func startStreaming(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int,
                        fps: Int, bitrate: Int) async throws {
        injector.setDisplay(displayID)
        let encoder = try VideoEncoder(width: pixelWidth, height: pixelHeight, fps: fps, bitrate: bitrate)
        encoder.onEncoded = { [weak self, weak encoder] frame in self?.deliver(frame, from: encoder) }

        stateLock.lock()
        // 약 150ms 분량 이상 전송이 밀리면 혼잡으로 판단
        congestionLimit = max(512 * 1024, bitrate / 8 * 15 / 100)
        droppingUntilKeyframe = false
        stateLock.unlock()

        capturer.queue.sync {
            self.encoder = encoder
            self.lastPixelBuffer = nil
        }
        try await capturer.start(displayID: displayID, width: pixelWidth, height: pixelHeight, fps: fps)
    }

    func stopStreaming() async {
        await capturer.stop()
        capturer.queue.sync {
            encoder?.invalidate()
            encoder = nil
            lastPixelBuffer = nil
        }
    }

    /// 키프레임 강제. 화면이 정지해 있어도 마지막 프레임을 재인코딩해 즉시 보낸다.
    func requestKeyframe(after delay: TimeInterval = 0) {
        capturer.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let encoder = self.encoder else { return }
            encoder.forceKeyframe()
            if let pixelBuffer = self.lastPixelBuffer { self.encode(pixelBuffer) }
        }
    }

    /// (frames, bytes) — 호출 시 초기화
    func takeStats() -> (frames: Int, bytes: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        let result = (statFrames, statBytes)
        statFrames = 0
        statBytes = 0
        return result
    }

    // MARK: - Private

    private func handle(_ type: MessageType, _ payload: Data) {
        switch type {
        case .hello, .resize:
            if let hello = try? JSONDecoder().decode(ClientHello.self, from: payload) { onHello?(hello) }
        case .input:
            if let event = try? JSONDecoder().decode(InputEvent.self, from: payload) { injector.handle(event) }
        case .requestKeyframe:
            requestKeyframe()
        case .ping:
            connection.send(.pong, payload)
        default:
            break
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer) {
        lastPixelBuffer = pixelBuffer
        // 재인코딩 프레임도 단조 증가해야 하므로 SCStream PTS 대신 호스트 클럭 사용
        encoder?.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private func deliver(_ frame: VideoEncoder.EncodedFrame, from encoder: VideoEncoder?) {
        stateLock.lock()
        let congested = connection.pendingBytes > congestionLimit
        if congested {
            // 참조 체인이 끊기므로 다음 키프레임까지 전부 버린다.
            droppingUntilKeyframe = true
        }
        let drop = congested || (droppingUntilKeyframe && !frame.isKeyframe)
        if !drop { droppingUntilKeyframe = false }
        stateLock.unlock()

        if drop {
            if congested { requestKeyframe(after: 0.1) }
            return
        }

        if frame.isKeyframe, !frame.parameterSets.isEmpty {
            let format = VideoFormatMessage(width: frame.width, height: frame.height, parameterSets: frame.parameterSets)
            connection.send(.videoFormat, format.encoded())
        }
        let message = VideoFrameMessage(isKeyframe: frame.isKeyframe, ptsMicros: frame.ptsMicros, payload: frame.data)
        connection.send(.videoFrame, message.encoded())

        stateLock.lock()
        statFrames += 1
        statBytes += frame.data.count
        stateLock.unlock()
    }
}
