import Foundation
import Observation

@MainActor
@Observable
final class SyncCore {
    let settings: AppSettings
    let pendingStore = PendingBackupStore()

    private(set) var appStatus: AppStatus = .stopped
    private(set) var currentProgress: BackupProgress?
    private(set) var history: [BackupHistoryEntry] = []

    private let wifiMonitor = WiFiMonitor()
    private let backupEngine = BackupEngine()
    private let webPush = WebPushService()
    private var httpsServer: HTTPServer?
    private var backupTask: Task<Void, Never>?

    var appStatusLabel: String {
        switch appStatus {
        case .stopped: "stopped"
        case .running: "running"
        case .error: "error"
        }
    }

    var pwaURL: URL { settings.pwaURL }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() async {
        guard case .stopped = appStatus else { return }
        LocationAuthorization.shared.requestIfNeeded()

        let staticRoot = Self.resolveStaticRoot()
        let server = HTTPServer(port: settings.httpsPort, staticRoot: staticRoot, core: self)
        do {
            try server.start()
            httpsServer = server
            appStatus = .running
        } catch {
            appStatus = .error(error.localizedDescription)
            AppLogger.shared.error(
                "Failed to start HTTPS server: \(error.localizedDescription)",
                category: .server
            )
            return
        }

        wifiMonitor.start(
            interval: settings.scanIntervalSeconds,
            camerasProvider: { [settings] in settings.enabledCameras() },
            onDetected: { [weak self] detected in
                Task { @MainActor [weak self] in
                    await self?.handleDetectedCamera(detected.profile)
                }
            }
        )
        AppLogger.shared.info("Insta360 Sync started")
    }

    func stop() async {
        wifiMonitor.stop()
        httpsServer?.stop()
        httpsServer = nil
        backupTask?.cancel()
        backupTask = nil
        appStatus = .stopped
    }

    func restart() async {
        await stop()
        await start()
    }

    func registerPushSubscription(_ subscription: PushSubscriptionRecord) {
        if !settings.pushSubscriptions.contains(where: { $0.endpoint == subscription.endpoint }) {
            settings.pushSubscriptions.append(subscription)
            AppLogger.shared.info(
                "Push subscription registered (\(settings.pushSubscriptions.count) total)",
                category: .push
            )
        }
    }

    func handleDetectedCamera(_ camera: CameraProfile) async {
        guard case .running = appStatus else { return }
        guard let pending = pendingStore.createPending(for: camera) else { return }
        AppLogger.shared.info(
            "Camera detected, sending push for \(camera.displayName) (\(settings.pushSubscriptions.count) subscriptions)",
            category: .push
        )
        let pushSettings = settings
        await webPush.notifyBackupPending(settings: pushSettings, pending: pending)
    }

    func approveBackup(id: UUID) async {
        guard let pending = pendingStore.item(id: id), pending.status == .pending else { return }
        guard let camera = settings.camera(for: pending.cameraID) else { return }
        pendingStore.update(id, status: .approved)
        backupTask?.cancel()
        backupTask = Task {
            await runBackup(for: camera, pendingID: id)
        }
    }

    func skipBackup(id: UUID) {
        pendingStore.update(id, status: .skipped)
    }

    func runManualBackup(cameraID: UUID) async {
        guard let camera = settings.camera(for: cameraID) else { return }
        let pending = PendingBackup(
            id: UUID(),
            cameraID: camera.id,
            cameraName: camera.displayName,
            ssid: camera.ssid,
            detectedAt: Date(),
            status: .approved
        )
        pendingStore.addManualPending(pending)
        backupTask?.cancel()
        backupTask = Task {
            await runBackup(for: camera, pendingID: pending.id)
        }
    }

    private func runBackup(for camera: CameraProfile, pendingID: UUID) async {
        pendingStore.update(pendingID, status: .running)
        let previousSSID = wifiMonitor.currentSSID()
        if let previousSSID, previousSSID != camera.ssid {
            wifiMonitor.rememberNonCameraNetwork(previousSSID)
        }

        let startedAt = Date()
        var result: BackupResult?
        var failureMessage: String?
        let backupSettings = settings

        do {
            try await wifiMonitor.connectIfNeeded(to: camera)
            result = try await backupEngine.runBackup(camera: camera, settings: backupSettings) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.currentProgress = progress
                }
            }
        } catch {
            failureMessage = error.localizedDescription
            AppLogger.shared.error("Backup failed: \(error.localizedDescription)")
        }

        await wifiMonitor.finishCameraSession(previousSSID: previousSSID, cameraSSID: camera.ssid)
        currentProgress = nil

        if let result {
            pendingStore.update(pendingID, status: .completed)
            history.insert(
                BackupHistoryEntry(
                    id: UUID(),
                    cameraName: camera.displayName,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    copiedCount: result.copiedCount,
                    skippedCount: result.skippedCount,
                    failedCount: result.failedCount,
                    message: "protocol=\(result.protocolKind.rawValue)",
                    failures: result.failures
                ),
                at: 0
            )
            await webPush.notifyBackupFinished(
                settings: backupSettings,
                cameraName: camera.displayName,
                copied: result.copiedCount,
                skipped: result.skippedCount
            )
        } else {
            pendingStore.update(pendingID, status: .failed)
            history.insert(
                BackupHistoryEntry(
                    id: UUID(),
                    cameraName: camera.displayName,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    copiedCount: 0,
                    skippedCount: 0,
                    failedCount: 0,
                    message: failureMessage
                ),
                at: 0
            )
        }
    }

    private static func resolveStaticRoot() -> URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("public", isDirectory: true),
           FileManager.default.fileExists(atPath: resource.appendingPathComponent("index.html").path) {
            return resource
        }
        if let resource = Bundle.module.resourceURL?.appendingPathComponent("public", isDirectory: true),
           FileManager.default.fileExists(atPath: resource.appendingPathComponent("index.html").path) {
            return resource
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let devPath = cwd.appendingPathComponent("apps/pwa/dist")
        if FileManager.default.fileExists(atPath: devPath.appendingPathComponent("index.html").path) {
            return devPath
        }
        return Bundle.module.resourceURL?.appendingPathComponent("public", isDirectory: true)
            ?? cwd.appendingPathComponent("Resources/public")
    }
}
