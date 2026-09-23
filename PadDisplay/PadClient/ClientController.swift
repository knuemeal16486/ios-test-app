import Network
import SwiftUI
import UIKit

struct DiscoveredHost: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

@MainActor
final class ClientController: ObservableObject, RemoteInputSink {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case streaming(String)
        case reconnecting(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var stats = ""
    @Published private(set) var lastError: String?
    @Published var showHUD = false
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Keys.autoConnect) }
    }
    @Published var manualAddress: String {
        didSet { UserDefaults.standard.set(manualAddress, forKey: Keys.manualAddress) }
    }

    let renderer = VideoRenderer()

    private enum Keys {
        static let autoConnect = "autoConnect"
        static let manualAddress = "manualAddress"
        static let lastHostName = "lastHostName"
    }

    private var browser: NWBrowser?
    private var usbListener: NWListener?
    private var link: StreamLink?
    /// 마지막 연결이 USB였는지 (복귀 시 Wi-Fi보다 USB 재접속을 먼저 기다림)
    private var preferWired = false
    private var target: (endpoint: NWEndpoint, name: String)?
    private var serverInfo: ServerInfo?
    private var userDisconnected = false
    private var suspended = false
    private var viewPixelSize = CGSize.zero
    private var viewPointSize = CGSize.zero
    private var sentPixelSize = CGSize.zero
    private var reconnectTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var statsTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        autoConnect = defaults.object(forKey: Keys.autoConnect) as? Bool ?? true
        manualAddress = defaults.string(forKey: Keys.manualAddress) ?? ""
        startBrowsing()
        startUsbListener()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var isStreaming: Bool {
        if case .streaming = phase { return true }
        return false
    }

    var statusText: String {
        switch phase {
        case .idle: return suspended ? "일시 정지됨" : "연결할 Mac을 선택하세요"
        case .connecting(let name): return "\(name)에 연결 중…"
        case .streaming(let name): return "\(name) 스트리밍 중\(link?.isWired == true ? " · USB" : " · Wi-Fi")"
        case .reconnecting(let name): return "\(name) 재연결 중…"
        }
    }

    // MARK: - Connection

    func connect(to host: DiscoveredHost) {
        userDisconnected = false
        UserDefaults.standard.set(host.name, forKey: Keys.lastHostName)
        open(endpoint: host.endpoint, name: host.name)
    }

    func connectManual() {
        let address = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        var host = address
        var port = PadDisplayConstants.defaultPort
        if let colon = address.lastIndex(of: ":"), !address.contains("]"),
           address.filter({ $0 == ":" }).count == 1, let parsed = UInt16(address[address.index(after: colon)...]) {
            host = String(address[..<colon])
            port = parsed
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        userDisconnected = false
        open(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort), name: host)
    }

    func disconnect() {
        userDisconnected = true
        target = nil
        reconnectTask?.cancel()
        closeLink()
        showHUD = false
        phase = .idle
    }

    private func open(endpoint: NWEndpoint, name: String) {
        reconnectTask?.cancel()
        closeLink()
        renderer.reset()
        target = (endpoint, name)
        serverInfo = nil
        lastError = nil
        if case .reconnecting = phase {} else { phase = .connecting(name) }

        attach(StreamLink(endpoint: endpoint, renderer: renderer), name: name)
    }

    private func attach(_ link: StreamLink, name: String) {
        link.onReady = { [weak self, weak link] in
            Task { @MainActor in
                guard let self, let link, link === self.link else { return }
                self.sentPixelSize = self.currentPixelSize()
                link.sendHello(self.makeHello(), isResize: false)
            }
        }
        link.onServerInfo = { [weak self, weak link] info in
            Task { @MainActor in
                guard let self, let link, link === self.link else { return }
                self.serverInfo = info
                self.preferWired = link.isWired
                self.phase = .streaming(link.isWired ? info.hostName : name)
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        link.onClosed = { [weak self, weak link] error in
            Task { @MainActor in
                guard let self, let link else { return }
                self.linkClosed(link, error: error)
            }
        }
        self.link = link
        link.start()
    }

    private func closeLink() {
        link?.close()
        link = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func linkClosed(_ closed: StreamLink, error: Error?) {
        guard closed === link else { return }
        link = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if let error { lastError = error.localizedDescription }
        if closed.isWired {
            // 케이블 분리 등 → Wi-Fi로 폴백 (Mac이 USB 재접속하면 다시 USB로 전환됨)
            preferWired = false
            phase = .idle
            if let target, !suspended, !userDisconnected {
                phase = .reconnecting(target.name)
                reconnectTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, self.link == nil, let target = self.target else { return }
                    self.open(endpoint: target.endpoint, name: target.name)
                }
            } else {
                autoConnectIfNeeded()
            }
            return
        }
        guard let target, !suspended, !userDisconnected else {
            phase = .idle
            return
        }
        phase = .reconnecting(target.name)
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, self.link == nil, let target = self.target else { return }
            self.open(endpoint: target.endpoint, name: target.name)
        }
    }

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            // iOS가 백그라운드에서 소켓을 끊기 전에 정리 → Mac 인코딩도 즉시 중단
            suspended = true
            reconnectTask?.cancel()
            closeLink()
            phase = .idle
        case .active:
            guard suspended else { return }
            suspended = false
            if usbListener == nil { startUsbListener() }
            // USB였다면 Mac이 2초 주기로 터널을 재시도하므로 잠시 기다렸다가 Wi-Fi로 폴백
            let delay: UInt64 = preferWired ? 3_000_000_000 : 0
            reconnectTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, self.link == nil, !self.suspended else { return }
                if let target = self.target {
                    self.open(endpoint: target.endpoint, name: target.name)
                } else {
                    self.autoConnectIfNeeded()
                }
            }
        default:
            break
        }
    }

    // MARK: - USB (usbmuxd 터널 수신)

    private func startUsbListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .loopback // usbmuxd가 기기 내부 루프백으로 접속
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: PadDisplayConstants.usbPort),
              let listener = try? NWListener(using: params, on: port) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.acceptWired(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.usbListener?.cancel()
                    self?.usbListener = nil
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self?.usbListener == nil { self?.startUsbListener() }
                }
            }
        }
        listener.start(queue: .main)
        usbListener = listener
    }

    /// USB가 항상 우선: 기존 Wi-Fi 연결을 대체한다. Wi-Fi 대상(target)은 폴백용으로 유지.
    private func acceptWired(_ connection: NWConnection) {
        guard !suspended else { connection.cancel(); return }
        reconnectTask?.cancel()
        closeLink()
        renderer.reset()
        serverInfo = nil
        lastError = nil
        userDisconnected = false
        phase = .connecting("USB")
        attach(StreamLink(connection: connection, renderer: renderer, isWired: true), name: "USB")
    }

    // MARK: - Discovery

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: PadDisplayConstants.serviceType, domain: nil), using: .padDisplay())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.updateHosts(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in
                    self?.lastError = "검색 실패: \(error.localizedDescription)"
                    self?.browser?.cancel()
                    self?.browser = nil
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.startBrowsing()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func updateHosts(_ results: Set<NWBrowser.Result>) {
        hosts = results.compactMap { result in
            if case let .service(name, _, _, _) = result.endpoint {
                return DiscoveredHost(name: name, endpoint: result.endpoint)
            }
            return nil
        }
        .sorted { $0.name < $1.name }
        autoConnectIfNeeded()
    }

    private func autoConnectIfNeeded() {
        guard autoConnect, !userDisconnected, !suspended, link == nil, target == nil else { return }
        let lastName = UserDefaults.standard.string(forKey: Keys.lastHostName)
        if let host = hosts.first(where: { $0.name == lastName }) ?? (hosts.count == 1 ? hosts.first : nil) {
            connect(to: host)
        }
    }

    // MARK: - RemoteInputSink

    var pointScale: CGFloat {
        guard let info = serverInfo, viewPointSize.width > 0 else { return 1 }
        return CGFloat(info.displayPointWidth) / viewPointSize.width
    }

    func send(_ event: InputEvent) {
        guard isStreaming else { return }
        link?.send(event)
    }

    func toggleHUD() {
        guard isStreaming else { return }
        showHUD.toggle()
    }

    func viewSizeChanged(pixels: CGSize, points: CGSize) {
        viewPointSize = points
        let rounded = CGSize(width: pixels.width.rounded(), height: pixels.height.rounded())
        guard rounded != viewPixelSize, rounded.width > 0, rounded.height > 0 else { return }
        viewPixelSize = rounded
        guard link != nil else { return }
        // 회전 애니메이션 중 중간 크기가 여러 번 오므로 디바운스
        resizeTask?.cancel()
        resizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let link = self.link, self.viewPixelSize != self.sentPixelSize else { return }
            self.sentPixelSize = self.viewPixelSize
            link.sendHello(self.makeHello(), isResize: true)
        }
    }

    // MARK: - Helpers

    private func makeHello() -> ClientHello {
        let size = currentPixelSize()
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        return ClientHello(deviceName: UIDevice.current.name,
                           pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                           pixelsPerInch: PadDisplayConstants.iPadProPixelsPerInch,
                           maxFPS: screen?.maximumFramesPerSecond ?? 60)
    }

    private func currentPixelSize() -> CGSize {
        if viewPixelSize.width > 0 { return viewPixelSize }
        if let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen {
            return CGSize(width: screen.bounds.width * screen.scale, height: screen.bounds.height * screen.scale)
        }
        return CGSize(width: 2752, height: 2064) // iPad Pro 13" (M4) 가로
    }

    private func tick() {
        guard let link else {
            stats = ""
            return
        }
        let (frames, bytes, rtt) = link.takeStats()
        stats = String(format: "%d fps · %.1f Mbps · RTT %.1f ms", frames, Double(bytes) * 8 / 1_000_000, rtt)
    }
}
