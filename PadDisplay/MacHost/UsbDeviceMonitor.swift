import Foundation
import Network

/// usbmuxd(/var/run/usbmuxd)를 통해 USB로 연결된 iPad의 루프백 포트에 TCP 터널을 연다.
/// Xcode·Finder와 같은 경로이므로 iPad에서 "이 컴퓨터 신뢰"만 되어 있으면 된다.
///
/// usbmux 패킷: [length u32][version u32 = 1][type u32 = 8 (plist)][tag u32] (리틀엔디언) + XML plist
final class UsbDeviceMonitor {
    /// 터널 준비 완료. connection은 `queue`에서 이미 start되어 ready 상태이며 이후 원시 스트림이다.
    var onTunnel: (@Sendable (_ connection: NWConnection, _ queue: DispatchQueue, _ deviceID: Int) -> Void)?
    var onDevicesChanged: (@Sendable (_ count: Int) -> Void)?

    private static let socketPath = "/var/run/usbmuxd"
    private let queue = DispatchQueue(label: "paddisplay.usbmux")
    private var listenConnection: NWConnection?
    private var attached = Set<Int>()
    private var busy = Set<Int>()   // 연결 시도 중 또는 터널 사용 중
    private var enabled = false

    func setEnabled(_ enabled: Bool) {
        queue.async {
            guard self.enabled != enabled else { return }
            self.enabled = enabled
            if enabled {
                self.startListening()
            } else {
                self.listenConnection?.cancel()
                self.listenConnection = nil
                self.attached.removeAll()
                self.onDevicesChanged?(0)
            }
        }
    }

    /// 세션 종료 시 호출 → iPad 앱이 다시 열리면 재접속되도록 재시도
    func tunnelClosed(deviceID: Int) {
        queue.async {
            self.busy.remove(deviceID)
            self.scheduleConnect(deviceID, after: 2)
        }
    }

    // MARK: - Listen (장치 연결/해제 이벤트)

    private func startListening() {
        guard enabled else { return }
        let connection = NWConnection(to: .unix(path: Self.socketPath), using: .tcp)
        listenConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.send(["MessageType": "Listen"], on: connection)
                self.readLoop(connection)
            case .failed, .cancelled:
                guard self.listenConnection === connection else { return }
                self.listenConnection = nil
                self.attached.removeAll()
                self.onDevicesChanged?(0)
                self.queue.asyncAfter(deadline: .now() + 3) { self.startListening() }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func readLoop(_ connection: NWConnection) {
        receivePacket(on: connection) { [weak self] message in
            guard let self else { return }
            guard let message else { connection.cancel(); return }
            self.handleListenMessage(message)
            self.readLoop(connection)
        }
    }

    private func handleListenMessage(_ message: [String: Any]) {
        switch message["MessageType"] as? String {
        case "Attached":
            guard let id = message["DeviceID"] as? Int,
                  let properties = message["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB"
            else { return }
            attached.insert(id)
            onDevicesChanged?(attached.count)
            scheduleConnect(id, after: 0.5)
        case "Detached":
            guard let id = message["DeviceID"] as? Int else { return }
            attached.remove(id)
            onDevicesChanged?(attached.count)
        default:
            break
        }
    }

    // MARK: - Connect (터널 생성)

    private func scheduleConnect(_ id: Int, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.enabled, self.attached.contains(id), !self.busy.contains(id) else { return }
            self.connect(id)
        }
    }

    private func connect(_ id: Int) {
        busy.insert(id)
        let tunnelQueue = DispatchQueue(label: "paddisplay.usb.\(id)", qos: .userInteractive)
        let connection = NWConnection(to: .unix(path: Self.socketPath), using: .tcp)
        var finished = false

        func fail() {
            self.queue.async {
                guard !finished else { return }
                finished = true
                connection.cancel()
                self.busy.remove(id)
                self.scheduleConnect(id, after: 2) // iPad 앱이 아직 실행되지 않았을 수 있음
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = PadDisplayConstants.usbPort
                self.send(["MessageType": "Connect",
                           "DeviceID": id,
                           "PortNumber": Int(port.bigEndian)], // 네트워크 바이트 순서
                          on: connection)
                self.receivePacket(on: connection) { message in
                    guard (message?["Number"] as? Int) == 0 else { fail(); return }
                    self.queue.async {
                        guard !finished else { return }
                        finished = true
                        // 이후 상태 변화는 FramedConnection이 처리
                        connection.stateUpdateHandler = nil
                        self.onTunnel?(connection, tunnelQueue, id)
                    }
                }
            case .failed, .cancelled:
                fail()
            default:
                break
            }
        }
        connection.start(queue: tunnelQueue)
    }

    // MARK: - Packet I/O

    private func send(_ message: [String: Any], on connection: NWConnection) {
        var dict = message
        dict["ClientVersionString"] = "PadDisplay-1"
        dict["ProgName"] = "PadDisplay"
        guard let body = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(body)
        connection.send(content: packet, completion: .idempotent)
    }

    private func receivePacket(on connection: NWConnection, completion: @escaping ([String: Any]?) -> Void) {
        connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { header, _, _, error in
            guard error == nil, let header, header.count == 16 else { completion(nil); return }
            let bytes = [UInt8](header)
            let length = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
            let bodyLength = length - 16
            guard bodyLength > 0, bodyLength < 1 << 20 else { completion(nil); return }
            connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, _, _, error in
                guard error == nil, let body, body.count == bodyLength,
                      let plist = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil),
                      let message = plist as? [String: Any]
                else { completion(nil); return }
                completion(message)
            }
        }
    }
}
