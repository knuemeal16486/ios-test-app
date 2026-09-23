import Foundation

enum ScaleMode: String, Codable, CaseIterable, Identifiable {
    case retina
    case moreSpace

    var id: String { rawValue }

    /// iPad 기본 포인트 해상도 대비 배율
    var factor: Double {
        switch self {
        case .retina: return 1.0
        case .moreSpace: return 1.25
        }
    }

    var title: String {
        switch self {
        case .retina: return "기본 (1376×1032)"
        case .moreSpace: return "더 넓게 (1720×1290)"
        }
    }
}

struct HostSettings: Codable, Equatable {
    var fps = 60
    var bitrateMbps = 40
    var scaleMode = ScaleMode.retina
    var makeMain = true
    var keepDisplayOnDisconnect = true
    var usbEnabled = true

    private static let key = "hostSettings"

    init() {}

    /// 누락된 키는 기본값 유지 (설정 항목이 늘어나도 기존 설정 보존)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HostSettings()
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps
        scaleMode = try c.decodeIfPresent(ScaleMode.self, forKey: .scaleMode) ?? d.scaleMode
        makeMain = try c.decodeIfPresent(Bool.self, forKey: .makeMain) ?? d.makeMain
        keepDisplayOnDisconnect = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayOnDisconnect) ?? d.keepDisplayOnDisconnect
        usbEnabled = try c.decodeIfPresent(Bool.self, forKey: .usbEnabled) ?? d.usbEnabled
    }

    static func load() -> HostSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(HostSettings.self, from: data)
        else { return HostSettings() }
        return settings
    }

    func save() {
        UserDefaults.standard.set(jsonData(), forKey: Self.key)
    }
}
