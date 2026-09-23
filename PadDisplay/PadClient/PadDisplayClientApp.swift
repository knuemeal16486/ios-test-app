import SwiftUI

@main
struct PadDisplayClientApp: App {
    @StateObject private var controller = ClientController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var controller: ClientController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            RemoteDisplayRepresentable(controller: controller)
                .ignoresSafeArea()

            if !controller.isStreaming {
                Color.black.opacity(0.6).ignoresSafeArea()
                ConnectPanel()
            } else if controller.showHUD {
                VStack {
                    HUDView()
                    Spacer()
                }
                .padding(.top, 24)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onChange(of: scenePhase) { _, newPhase in
            controller.scenePhaseChanged(newPhase)
        }
    }
}

struct RemoteDisplayRepresentable: UIViewControllerRepresentable {
    let controller: ClientController

    func makeUIViewController(context: Context) -> RemoteDisplayViewController {
        let renderer = controller.renderer
        return RemoteDisplayViewController(displayLayer: renderer.layer, sink: controller,
                                           videoSize: { renderer.videoSize })
    }

    func updateUIViewController(_ viewController: RemoteDisplayViewController, context: Context) {}
}

struct ConnectPanel: View {
    @EnvironmentObject private var controller: ClientController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Label("PadDisplay", systemImage: "display").font(.largeTitle.bold())
                Text(controller.statusText).foregroundStyle(.secondary)
            }

            GroupBox("주변의 Mac") {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.hosts.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Mac에서 PadDisplay 호스트 앱을 실행하세요").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(controller.hosts) { host in
                        Button {
                            controller.connect(to: host)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(host.name)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("IP로 직접 연결") {
                HStack {
                    TextField("예: 192.168.0.10", text: $controller.manualAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .onSubmit { controller.connectManual() }
                    Button("연결") { controller.connectManual() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Toggle("실행 시 마지막 Mac에 자동 연결", isOn: $controller.autoConnect)

            if let error = controller.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(28)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding()
    }
}

struct HUDView: View {
    @EnvironmentObject private var controller: ClientController

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.statusText).font(.headline)
                Text(controller.stats).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("연결 끊기", role: .destructive) { controller.disconnect() }
                .buttonStyle(.bordered)
            Button {
                controller.showHUD = false
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
