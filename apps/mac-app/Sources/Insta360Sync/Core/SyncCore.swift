import Foundation
import Observation

@MainActor
@Observable
final class SyncCore {
    private enum HistoryDefaults {
        static let key = "backupHistory"
        static let maxEntries = 50
    }

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
        self.history = Self.loadHistory()
    }

    func start() async {
        guard case .stopped = appStatus else { return }
        LocationAuthorization.shared.requestIfNeeded()

        let staticRoot = Self.resolveStaticRoot()
        let certPath = settings.usesCustomTLSCertificate ? settings.tlsCertificatePath : nil
        let keyPath = settings.usesCustomTLSCertificate ? settings.tlsPrivateKeyPath : nil
        let server = HTTPServer(
            port: settings.httpsPort,
            staticRoot: staticRoot,
            core: self,
            tlsCertificatePath: certPath,
            tlsPrivateKeyPath: keyPath
        )
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
            onScanResult: { [weak self] result in
                Task { @MainActor [weak self] in
                    await self?.handleScanResult(result)
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
        if let index = settings.pushSubscriptions.firstIndex(where: { $0.endpoint == subscription.endpoint }) {
            settings.pushSubscriptions[index] = subscription
            AppLogger.shared.info(
                "Push subscription updated for \(subscription.endpointHost) …\(subscription.endpointSuffix)",
                category: .push
            )
        } else {
            settings.pushSubscriptions.append(subscription)
            AppLogger.shared.info(
                "Push subscription registered for \(subscription.endpointHost) …\(subscription.endpointSuffix) (\(settings.pushSubscriptions.count) total)",
                category: .push
            )
        }
    }

    func removePushSubscription(endpoint: String) {
        let before = settings.pushSubscriptions.count
        settings.pushSubscriptions.removeAll { $0.endpoint == endpoint }
        if settings.pushSubscriptions.count < before {
            let host = URL(string: endpoint)?.host ?? endpoint
            AppLogger.shared.info("Removed push subscription for \(host)", category: .push)
        }
    }

    func removeAllPushSubscriptions() {
        let count = settings.pushSubscriptions.count
        settings.pushSubscriptions = []
        if count > 0 {
            AppLogger.shared.info("Removed all \(count) push subscription(s)", category: .push)
        }
    }

    func sendTestPush(toEndpoint endpoint: String? = nil) async -> [PushDeliveryResult] {
        let targets: [PushSubscriptionRecord]?
        if let endpoint {
            let matches = settings.pushSubscriptions.filter { $0.endpoint == endpoint }
            if matches.isEmpty {
                AppLogger.shared.warning(
                    "Test push skipped: endpoint not found …\(String(endpoint.suffix(24)))",
                    category: .push
                )
                return [
                    PushDeliveryResult(
                        endpoint: endpoint,
                        endpointHost: URL(string: endpoint)?.host ?? endpoint,
                        ok: false,
                        statusCode: nil,
                        error: "Mac 側にこの endpoint の購読がありません。Push 通知を有効化してください。",
                        apnsID: nil,
                        reason: nil,
                        responseBody: nil,
                        responseHeaders: [:],
                        payloadBytes: nil
                    ),
                ]
            }
            targets = matches
        } else {
            targets = nil
        }
        let results = await webPush.sendTest(settings: settings, subscriptions: targets)
        applyPushDeliveryResults(results)
        return results
    }

    private func applyPushDeliveryResults(_ results: [PushDeliveryResult]) {
        let expired = Set(results.filter(\.isExpired).map(\.endpoint))
        guard !expired.isEmpty else { return }
        let before = settings.pushSubscriptions.count
        settings.pushSubscriptions.removeAll { expired.contains($0.endpoint) }
        let removed = before - settings.pushSubscriptions.count
        AppLogger.shared.info("Removed \(removed) expired push subscription(s)", category: .push)
    }

    private func handleScanResult(_ result: WiFiMonitor.ScanResult) async {
        guard case .running = appStatus else { return }

        // バックアップ中はカメラ AP 占有でスキャン結果が不安定になりうるため、承認待ちの掃除だけ行わない。
        if !pendingStore.hasActiveBackup {
            pendingStore.clearPending(forAbsentCameraIDs: Set(result.absent.map(\.id)))
        }

        for camera in result.visible {
            await handleDetectedCamera(camera)
        }
    }

    func handleDetectedCamera(_ camera: CameraProfile) async {
        guard case .running = appStatus else { return }
        guard camera.hasDestination else {
            AppLogger.shared.warning(
                "Skipping detection for \(camera.displayName): destination is not configured"
            )
            return
        }
        // バックアップ中はカメラ AP を占有するため、他デバイス含む全端末へ検知 Push を送らない。
        if pendingStore.hasActiveBackup {
            AppLogger.shared.info(
                "Skipping detection push while backup is in progress (\(camera.displayName))",
                category: .push
            )
            return
        }
        guard let pending = pendingStore.createPending(for: camera) else { return }
        AppLogger.shared.info(
            "Camera detected, sending push for \(camera.displayName) (\(settings.pushSubscriptions.count) subscriptions)",
            category: .push
        )
        let pushSettings = settings
        let results = await webPush.notifyBackupPending(settings: pushSettings, pending: pending)
        applyPushDeliveryResults(results)
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
        guard camera.hasDestination else {
            AppLogger.shared.warning(
                "Manual backup skipped for \(camera.displayName): destination is not configured"
            )
            prependHistory(
                BackupHistoryEntry(
                    id: UUID(),
                    cameraName: camera.displayName,
                    startedAt: Date(),
                    finishedAt: Date(),
                    copiedCount: 0,
                    skippedCount: 0,
                    failedCount: 0,
                    message: BackupEngineError.destinationNotConfigured.localizedDescription
                )
            )
            return
        }
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
        // 同期直後はカメラ AP がまだ見えることがあるため、検知 Push のクールダウンを延長する。
        pendingStore.suppressDetection(for: camera.id)

        if let result {
            pendingStore.update(pendingID, status: .completed)
            prependHistory(
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
                )
            )
            let finishResults = await webPush.notifyBackupFinished(
                settings: backupSettings,
                cameraName: camera.displayName,
                copied: result.copiedCount,
                skipped: result.skippedCount
            )
            applyPushDeliveryResults(finishResults)
        } else {
            pendingStore.update(pendingID, status: .failed)
            prependHistory(
                BackupHistoryEntry(
                    id: UUID(),
                    cameraName: camera.displayName,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    copiedCount: 0,
                    skippedCount: 0,
                    failedCount: 0,
                    message: failureMessage
                )
            )
        }
    }

    private func prependHistory(_ entry: BackupHistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > HistoryDefaults.maxEntries {
            history = Array(history.prefix(HistoryDefaults.maxEntries))
        }
        Self.saveHistory(history)
    }

    private static func loadHistory() -> [BackupHistoryEntry] {
        let defaults = Insta360UserDefaults.store()
        guard let data = defaults.data(forKey: HistoryDefaults.key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([BackupHistoryEntry].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(HistoryDefaults.maxEntries))
    }

    private static func saveHistory(_ history: [BackupHistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        Insta360UserDefaults.store().set(data, forKey: HistoryDefaults.key)
    }

    private static func resolveStaticRoot() -> URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("public", isDirectory: true),
           FileManager.default.fileExists(atPath: resource.appendingPathComponent("index.html").path) {
            return resource
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let devPath = cwd.appendingPathComponent("apps/pwa/dist")
        if FileManager.default.fileExists(atPath: devPath.appendingPathComponent("index.html").path) {
            return devPath
        }
        return cwd.appendingPathComponent("Resources/public")
    }
}
