import ApplicationServices
import CoreGraphics
import Foundation
import Network
import ServiceManagement

@MainActor
final class HostController: ObservableObject {
    @Published var settings: HostSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if !settings.keepDisplayOnDisconnect, session == nil { virtualDisplay = nil }
            usb.setEnabled(settings.usbEnabled)
            let streamChanged = settings.fps != oldValue.fps || settings.bitrateMbps != oldValue.bitrateMbps
                || settings.scaleMode != oldValue.scaleMode || settings.makeMain != oldValue.makeMain
            if streamChanged, let hello = lastHello, session != nil { scheduleReconfigure(hello) }
        }
    }
    @Published private(set) var status = "iPad 연결 대기 중"
    @Published private(set) var clientName: String?
    @Published private(set) var stats = ""
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var hasVirtualDisplay = false
    /// 현재 세션이 USB 유선인지 (nil = 연결 없음)
    @Published private(set) var isWired: Bool?
    @Published private(set) var usbDeviceCount = 0

    private var listener: NWListener?
    private let usb = UsbDeviceMonitor()
    private var session: StreamSession?
    private var sessionDeviceID: Int?
    private var virtualDisplay: VirtualDisplay? {
        didSet { hasVirtualDisplay = virtualDisplay != nil }
    }
    private var lastHello: ClientHello?
    private var configureChain: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var statsTimer: Timer?

    private let hostName = Host.current().localizedName ?? "Mac"

    init() {
        settings = HostSettings.load()
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startListener()
        usb.onTunnel = { [weak self] connection, queue, deviceID in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.accept(connection, queue: queue, usbDeviceID: deviceID)
            }
        }
        usb.onDevicesChanged = { [weak self] count in
            Task { @MainActor in self?.usbDeviceCount = count }
        }
        usb.setEnabled(settings.usbEnabled)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Permissions / Login item

    func refreshPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "로그인 항목 설정 실패: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func removeVirtualDisplay() {
        session?.close()
        virtualDisplay = nil
    }

    // MARK: - Networking

    private func startListener() {
        do {
            let listener = try NWListener(using: .padDisplay(),
                                          on: NWEndpoint.Port(rawValue: PadDisplayConstants.defaultPort)!)
            listener.service = NWListener.Service(name: hostName, type: PadDisplayConstants.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, queue: nil, usbDeviceID: nil) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerStateChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = "리스너 시작 실패: \(error.localizedDescription)"
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if session == nil { status = "iPad 연결 대기 중 (포트 \(PadDisplayConstants.defaultPort))" }
        case .failed(let error):
            status = "리스너 오류: \(error.localizedDescription) — 재시작합니다"
            listener?.cancel()
            listener = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.startListener()
            }
        default:
            break
        }
    }

    /// 단일 클라이언트: 새 연결이 기존 연결을 대체. 단, USB 세션 중에는 Wi-Fi 연결을 받지 않는다.
    private func accept(_ nwConnection: NWConnection, queue: DispatchQueue?, usbDeviceID: Int?) {
        if usbDeviceID == nil, isWired == true {
            nwConnection.cancel()
            return
        }
        if let old = session {
            if let oldID = sessionDeviceID { usb.tunnelClosed(deviceID: oldID) }
            old.onClosed = nil
            old.close()
            Task { await old.stopStreaming() }
        }
        let framed: FramedConnection
        if let queue {
            framed = FramedConnection(connection: nwConnection, queue: queue, alreadyStarted: true)
        } else {
            framed = FramedConnection(connection: nwConnection)
        }
        let session = StreamSession(connection: framed)
        session.onHello = { [weak self, weak session] hello in
            Task { @MainActor in
                guard let self, let session, session === self.session else { return }
                self.enqueueConfigure(hello)
            }
        }
        session.onClosed = { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                self.sessionClosed(session)
            }
        }
        session.onCaptureError = { [weak self] error in
            Task { @MainActor in self?.status = "캡처 중단: \(error.localizedDescription)" }
        }
        self.session = session
        sessionDeviceID = usbDeviceID
        isWired = usbDeviceID != nil
        status = usbDeviceID != nil ? "iPad 연결 중… (USB)" : "iPad 연결 중… (Wi-Fi)"
        session.start()
    }

    private func sessionClosed(_ closed: StreamSession) {
        Task { await closed.stopStreaming() }
        guard closed === session else { return }
        if let id = sessionDeviceID { usb.tunnelClosed(deviceID: id) }
        session = nil
        sessionDeviceID = nil
        isWired = nil
        clientName = nil
        stats = ""
        status = "iPad 연결 대기 중"
        if !settings.keepDisplayOnDisconnect { virtualDisplay = nil }
    }

    // MARK: - Configuration

    private func scheduleReconfigure(_ hello: ClientHello) {
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.enqueueConfigure(hello)
        }
    }

    /// 설정 작업을 직렬화 (회전 등으로 hello가 연달아 와도 순서 보장)
    private func enqueueConfigure(_ hello: ClientHello) {
        let previous = configureChain
        configureChain = Task { @MainActor in
            await previous?.value
            await self.configure(hello)
        }
    }

    private func configure(_ hello: ClientHello) async {
        guard let session else { return }
        lastHello = hello
        clientName = hello.deviceName

        let pixelWidth = Self.even(hello.pixelWidth)
        let pixelHeight = Self.even(hello.pixelHeight)
        guard (320...8192).contains(pixelWidth), (240...8192).contains(pixelHeight) else {
            status = "잘못된 해상도: \(pixelWidth)×\(pixelHeight)"
            return
        }
        let factor = settings.scaleMode.factor
        let pointWidth = Self.even(Int((Double(pixelWidth) / 2 * factor).rounded()))
        let pointHeight = Self.even(Int((Double(pixelHeight) / 2 * factor).rounded()))
        let fps = max(15, min(settings.fps, hello.maxFPS))

        await session.stopStreaming()
        guard session === self.session else { return }

        let requiredSide = max(pointWidth, pointHeight) * 2
        if let display = virtualDisplay, display.maxPixelSide < requiredSide { virtualDisplay = nil }
        if virtualDisplay == nil {
            let maxSide = max(requiredSide, Self.even(Int(Double(max(pixelWidth, pixelHeight)) * 1.25)))
            let ppi = hello.pixelsPerInch > 0 ? hello.pixelsPerInch : PadDisplayConstants.iPadProPixelsPerInch
            let size = CGSize(width: Double(max(pixelWidth, pixelHeight)) / ppi * 25.4,
                              height: Double(min(pixelWidth, pixelHeight)) / ppi * 25.4)
            virtualDisplay = VirtualDisplay(name: "\(hello.deviceName) (PadDisplay)", maxPixelSide: maxSide,
                                            sizeInMillimeters: size)
        }
        guard let display = virtualDisplay else {
            status = "가상 디스플레이 생성 실패"
            return
        }
        guard display.apply(pointWidth: pointWidth, pointHeight: pointHeight, refreshRate: Double(fps)) else {
            status = "디스플레이 모드 적용 실패 (\(pointWidth)×\(pointHeight))"
            return
        }
        await DisplayArranger.waitUntilOnline(display.displayID)
        if settings.makeMain { DisplayArranger.makeMain(display.displayID) }

        do {
            try await session.startStreaming(displayID: display.displayID, pixelWidth: pixelWidth,
                                             pixelHeight: pixelHeight, fps: fps,
                                             bitrate: settings.bitrateMbps * 1_000_000)
            session.send(ServerInfo(hostName: hostName, codec: "hevc", fps: fps, bitrateMbps: settings.bitrateMbps,
                                    displayPointWidth: pointWidth, displayPointHeight: pointHeight))
            status = "스트리밍 중 (\(isWired == true ? "USB" : "Wi-Fi")) · \(pointWidth)×\(pointHeight)pt @\(fps)Hz"
        } catch {
            refreshPermissions()
            status = "캡처 시작 실패: \(error.localizedDescription)"
        }
    }

    private func tick() {
        guard let session else { return }
        let (frames, bytes) = session.takeStats()
        stats = String(format: "%d fps · %.1f Mbps", frames, Double(bytes) * 8 / 1_000_000)
    }

    private static func even(_ value: Int) -> Int { value & ~1 }
}
