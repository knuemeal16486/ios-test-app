import CoreGraphics
import Foundation

/// iPad 해상도에 맞춘 HiDPI 가상 디스플레이. 인스턴스 해제 시 디스플레이도 사라진다.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let maxPixelSide: Int

    var displayID: CGDirectDisplayID { display.displayID }

    init?(name: String, maxPixelSide: Int, sizeInMillimeters: CGSize) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        // 회전(가로/세로)과 '더 넓게' 배율을 모두 수용하도록 정사각 최대치로 잡는다.
        descriptor.maxPixelsWide = UInt32(maxPixelSide)
        descriptor.maxPixelsHigh = UInt32(maxPixelSide)
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.vendorID = 0x1A2B
        descriptor.productID = 0x0D13
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in }

        display = CGVirtualDisplay(descriptor: descriptor)
        self.maxPixelSide = maxPixelSide
        if display.displayID == 0 { return nil }
    }

    /// pointWidth × pointHeight 논리 해상도, 백킹 픽셀은 2배(HiDPI).
    @discardableResult
    func apply(pointWidth: Int, pointHeight: Int, refreshRate: Double) -> Bool {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt(pointWidth), height: UInt(pointHeight), refreshRate: refreshRate)]
        return display.apply(settings)
    }
}

enum DisplayArranger {
    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func waitUntilOnline(_ id: CGDirectDisplayID) async {
        for _ in 0..<30 {
            if onlineDisplays().contains(id), CGDisplayIsActive(id) != 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 주 디스플레이 = 전역 좌표 원점(0,0)에 놓인 디스플레이.
    /// 모든 디스플레이를 같은 오프셋만큼 이동해 기존 배치를 유지한 채 대상만 원점으로 옮긴다.
    @discardableResult
    static func makeMain(_ id: CGDirectDisplayID) -> Bool {
        guard CGMainDisplayID() != id else { return true }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        let target = CGDisplayBounds(id).origin
        for display in onlineDisplays() where CGDisplayMirrorsDisplay(display) == 0 {
            let origin = CGDisplayBounds(display).origin
            CGConfigureDisplayOrigin(config, display, Int32(origin.x - target.x), Int32(origin.y - target.y))
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
