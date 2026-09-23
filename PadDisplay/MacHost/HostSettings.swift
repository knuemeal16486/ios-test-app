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

    private static let key = "hostSettings"

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
