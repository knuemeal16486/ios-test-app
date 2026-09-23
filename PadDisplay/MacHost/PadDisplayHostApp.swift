import SwiftUI

@main
struct PadDisplayHostApp: App {
    @StateObject private var controller = HostController()

    var body: some Scene {
        MenuBarExtra("PadDisplay", systemImage: "ipad.landscape") {
            HostMenuView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}

struct HostMenuView: View {
    @EnvironmentObject private var controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "ipad.landscape")
                    .font(.title2)
                    .foregroundStyle(controller.clientName == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading) {
                    Text(controller.clientName ?? "연결된 iPad 없음").font(.headline)
                    Text(controller.status).font(.caption).foregroundStyle(.secondary)
                    if !controller.stats.isEmpty {
                        Text(controller.stats).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            permissionRow("화면 기록", granted: controller.screenRecordingGranted,
                          action: controller.requestScreenRecording)
            permissionRow("손쉬운 사용 (입력 제어)", granted: controller.accessibilityGranted,
                          action: controller.requestAccessibility)

            Divider()

            Picker("주사율", selection: $controller.settings.fps) {
                Text("30Hz").tag(30)
                Text("60Hz").tag(60)
                Text("120Hz").tag(120)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 2) {
                Text("비트레이트: \(controller.settings.bitrateMbps) Mbps").font(.caption)
                Slider(value: Binding(get: { Double(controller.settings.bitrateMbps) },
                                      set: { controller.settings.bitrateMbps = Int($0) }),
                       in: 10...150, step: 5)
            }

            Picker("해상도", selection: $controller.settings.scaleMode) {
                ForEach(ScaleMode.allCases) { mode in Text(mode.title).tag(mode) }
            }

            Toggle("iPad를 주 디스플레이로 설정", isOn: $controller.settings.makeMain)
            Toggle("연결 해제 후에도 가상 디스플레이 유지", isOn: $controller.settings.keepDisplayOnDisconnect)
            Toggle("로그인 시 자동 실행", isOn: Binding(get: { controller.launchAtLogin },
                                                  set: { controller.setLaunchAtLogin($0) }))

            Divider()

            HStack {
                Button("가상 디스플레이 제거") { controller.removeVirtualDisplay() }
                    .disabled(!controller.hasVirtualDisplay)
                Spacer()
                Button("종료") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear { controller.refreshPermissions() }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted { Button("허용", action: action) }
        }
    }
}
