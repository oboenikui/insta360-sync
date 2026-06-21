import AppKit
import SwiftUI

struct MenuBarView: View {
    var core: SyncCore
    var settings: AppSettings

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusSection
            Divider()
            controlsSection
            if let progress = core.currentProgress {
                Divider()
                progressSection(progress)
            }
            Divider()
            Button("設定…") { openSettingsWindow() }
            Button("PWA を開く") { openPWA() }
            Button("終了") {
                Task {
                    await core.stop()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .task {
            if settings.autoStartOnLaunch, case .stopped = core.appStatus {
                await core.start()
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insta360 Sync")
                .font(.headline)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            LocationPermissionBanner()
        }
    }

    private var controlsSection: some View {
        Group {
            switch core.appStatus {
            case .running:
                Button("停止") { Task { await core.stop() } }
            case .stopped, .error:
                Button("開始") { Task { await core.start() } }
            }
        }
    }

    private func progressSection(_ progress: BackupProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(progress.cameraName): \(progress.phase)")
                .font(.caption)
            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                Text("\(progress.completed)/\(progress.total)")
                    .font(.caption2)
            }
            if let file = progress.currentFile {
                Text(file)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }

    private var statusText: String {
        switch core.appStatus {
        case .stopped: "停止中"
        case .running: "実行中 · \(settings.pwaAccessURLDescription)"
        case .error(let message): "エラー: \(message)"
        }
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func openPWA() {
        NSWorkspace.shared.open(core.pwaURL)
    }
}
