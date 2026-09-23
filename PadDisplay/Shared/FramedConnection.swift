import Foundation
import Network

extension NWParameters {
    /// 저지연 TCP + AWDL(peer-to-peer Wi-Fi) 허용
    static func padDisplay() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        return params
    }
}

/// 길이 prefix 프레이밍 위의 메시지 송수신. 콜백은 모두 `queue`에서 호출된다.
final class FramedConnection {
    let connection: NWConnection
    let queue: DispatchQueue

    var onReady: (() -> Void)?
    var onMessage: ((MessageType, Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let lock = NSLock()
    private var pending = 0
    private var closed = false
    private let alreadyStarted: Bool

    /// - Parameter alreadyStarted: 이미 `queue`에서 start되어 ready 상태인 연결(USB 터널 등)
    init(connection: NWConnection,
         queue: DispatchQueue = DispatchQueue(label: "paddisplay.connection", qos: .userInteractive),
         alreadyStarted: Bool = false) {
        self.connection = connection
        self.queue = queue
        self.alreadyStarted = alreadyStarted
    }

    /// 전송 대기 중인 바이트 수 (혼잡 제어용)
    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?()
            case .failed(let error), .waiting(let error): self.close(error)
            case .cancelled: self.close(nil)
            default: break
            }
        }
        if alreadyStarted {
            queue.async { [weak self] in self?.onReady?() }
        } else {
            connection.start(queue: queue)
        }
        readHeader()
    }

    func send(_ type: MessageType, _ payload: Data = Data()) {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        let size = frame.count

        lock.lock()
        if closed { lock.unlock(); return }
        pending += size
        lock.unlock()

        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.pending -= size
            self.lock.unlock()
            if let error { self.close(error) }
        })
    }

    func close(_ error: Error? = nil) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        connection.cancel()
        let handler = onClose
        onClose = nil
        onMessage = nil
        onReady = nil
        handler?(error)
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.close(error); return }
            guard let data, data.count == 5 else {
                if isComplete || data != nil { self.close(nil) } else { self.readHeader() }
                return
            }
            let b = [UInt8](data)
            let length = Int(UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4]))
            guard length <= PadDisplayConstants.maxMessageSize else { self.close(nil); return }
            if length == 0 {
                self.deliver(b[0], Data())
                self.readHeader()
            } else {
                self.readBody(type: b[0], length: length)
            }
        }
    }

    private func readBody(type: UInt8, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { self.close(error); return }
            guard let data, data.count == length else { self.close(nil); return }
            self.deliver(type, data)
            self.readHeader()
        }
    }

    private func deliver(_ raw: UInt8, _ payload: Data) {
        guard let type = MessageType(rawValue: raw) else { return } // 알 수 없는 타입은 무시 (상위 호환)
        onMessage?(type, payload)
    }
}
