import AppKit
import SwiftUI

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            LocationAuthorization.shared.refreshAuthorization()
        }
    }
}

@main
struct Insta360SyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var core: SyncCore

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        let core = SyncCore(settings: settings)
        _core = State(initialValue: core)
        Task { @MainActor in
            if settings.autoStartOnLaunch {
                await core.start()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(core: core, settings: settings)
        } label: {
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)

        Window("Insta360 Sync 設定", id: "settings") {
            SettingsView(settings: settings, core: core)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 540, height: 620)
    }

    private var iconName: String {
        switch core.appStatus {
        case .running: "camera.fill"
        case .stopped: "camera"
        case .error: "exclamationmark.triangle"
        }
    }
}
