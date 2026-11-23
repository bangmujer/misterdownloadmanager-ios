import SwiftUI

@main
struct MDMApp: App {
    @StateObject private var store = DownloadStore()
    @StateObject private var musicPlayer = MusicPlayer()
    @State private var remote = RemoteServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(musicPlayer)
                .preferredColorScheme(colorScheme(for: store.settings.themeName))
                .tint(accent(for: store.settings.themeName))
                .environment(\.mdmScale, store.settings.interfaceScale)
                .onAppear {
                    RemoteSnapshot.shared.refresh(from: store.items)
                    if store.settings.remoteControlEnabled {
                        remote.start(store: store, port: UInt16(store.settings.remotePort))
                    }
                }
                .onReceive(store.$items.dropFirst()) { _ in
                    RemoteSnapshot.shared.refresh(from: store.items)
                    store.save()
                }
                .onChange(of: store.settings.remoteControlEnabled) { enabled in
                    if enabled { remote.start(store: store, port: UInt16(store.settings.remotePort)) }
                    else { remote.stop() }
                }
                .onOpenURL { url in
                    // mdm://add?url=… — from Shortcuts / other apps.
                    if url.scheme == "mdm", url.host == "add",
                       let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let value = comps.queryItems?.first(where: { $0.name == "url" })?.value {
                        _ = store.addItem(urlString: value)
                    }
                }
        }
    }

    private func colorScheme(for theme: String) -> ColorScheme? {
        switch theme {
        case "dark", "metro", "breeze": return .dark
        case "light", "classic", "luna", "aero", "aqua", "adwaita": return .light
        case "highContrast": return .dark
        default: return nil
        }
    }
    private func accent(for theme: String) -> Color {
        switch theme {
        case "classic": return .blue
        case "metro": return .teal
        case "adwaita": return .orange
        case "breeze": return .cyan
        case "luna": return .green
        case "aero": return .indigo
        case "aqua": return .mint
        case "highContrast": return .yellow
        default: return .blue
        }
    }
}

private struct ScaleKey: EnvironmentKey { static let defaultValue: Double = 1.0 }
extension EnvironmentValues { var mdmScale: Double { get { self[ScaleKey.self] } set { self[ScaleKey.self] = newValue } } }
