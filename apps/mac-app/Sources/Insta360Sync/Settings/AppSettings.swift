import Foundation
import Network
import Observation

@Observable
final class AppSettings: @unchecked Sendable {
    private var defaults: UserDefaults { Insta360UserDefaults.store() }

    private enum Keys {
        static let cameras = "cameras"
        static let destinationRoot = "destinationRoot"
        static let folderStructureMode = "folderStructureMode"
        static let scanIntervalSeconds = "scanIntervalSeconds"
        static let httpsPort = "httpsPort"
        static let apiToken = "apiToken"
        static let vapidPublicKey = "vapidPublicKey"
        static let vapidPrivateKey = "vapidPrivateKey"
        static let autoStartOnLaunch = "autoStartOnLaunch"
        static let pushSubscriptions = "pushSubscriptions"
    }

    var cameras: [CameraProfile] {
        didSet { persistCameras() }
    }

    var destinationRoot: URL {
        didSet { defaults.set(destinationRoot.path, forKey: Keys.destinationRoot) }
    }

    var folderStructureMode: FolderStructureMode {
        didSet { defaults.set(folderStructureMode.rawValue, forKey: Keys.folderStructureMode) }
    }

    var scanIntervalSeconds: TimeInterval {
        didSet { defaults.set(scanIntervalSeconds, forKey: Keys.scanIntervalSeconds) }
    }

    var httpsPort: UInt16 {
        didSet { defaults.set(Int(httpsPort), forKey: Keys.httpsPort) }
    }

    var apiToken: String {
        didSet { defaults.set(apiToken, forKey: Keys.apiToken) }
    }

    var vapidPublicKey: String {
        didSet { defaults.set(vapidPublicKey, forKey: Keys.vapidPublicKey) }
    }

    var vapidPrivateKey: String {
        didSet { defaults.set(vapidPrivateKey, forKey: Keys.vapidPrivateKey) }
    }

    var autoStartOnLaunch: Bool {
        didSet { defaults.set(autoStartOnLaunch, forKey: Keys.autoStartOnLaunch) }
    }

    var pushSubscriptions: [PushSubscriptionRecord] {
        didSet { persistPushSubscriptions() }
    }

    init() {
        Insta360UserDefaults.migrateLegacySettingsIfNeeded()
        let defaults = Insta360UserDefaults.store()
        if let data = defaults.data(forKey: Keys.cameras),
           let decoded = try? JSONDecoder().decode([CameraProfile].self, from: data) {
            self.cameras = decoded
        } else {
            self.cameras = []
        }

        if let path = defaults.string(forKey: Keys.destinationRoot) {
            self.destinationRoot = URL(fileURLWithPath: path)
        } else {
            self.destinationRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/Insta360Backup", isDirectory: true)
        }

        if let raw = defaults.string(forKey: Keys.folderStructureMode),
           let mode = FolderStructureMode(rawValue: raw) {
            self.folderStructureMode = mode
        } else {
            self.folderStructureMode = .preserveOriginal
        }

        self.scanIntervalSeconds = defaults.object(forKey: Keys.scanIntervalSeconds) as? TimeInterval
            ?? Insta360Defaults.scanIntervalSeconds

        let port = defaults.object(forKey: Keys.httpsPort) as? Int ?? Int(Insta360Defaults.httpsPort)
        self.httpsPort = UInt16(clamping: port)

        if let token = defaults.string(forKey: Keys.apiToken), !token.isEmpty {
            self.apiToken = token
        } else {
            self.apiToken = UUID().uuidString
        }

        self.vapidPublicKey = defaults.string(forKey: Keys.vapidPublicKey) ?? ""
        self.vapidPrivateKey = defaults.string(forKey: Keys.vapidPrivateKey) ?? ""
        self.autoStartOnLaunch = defaults.object(forKey: Keys.autoStartOnLaunch) as? Bool ?? true

        if let data = defaults.data(forKey: Keys.pushSubscriptions),
           let decoded = try? JSONDecoder().decode([PushSubscriptionRecord].self, from: data) {
            self.pushSubscriptions = decoded
        } else {
            self.pushSubscriptions = []
        }

        if self.apiToken.isEmpty || defaults.string(forKey: Keys.apiToken) == nil {
            defaults.set(self.apiToken, forKey: Keys.apiToken)
        }

        if vapidPublicKey.isEmpty || vapidPrivateKey.isEmpty {
            let keys = VAPIDKeys.generate()
            self.vapidPublicKey = keys.publicKeyBase64URL
            self.vapidPrivateKey = keys.privateKeyBase64URL
        }
    }

    func camera(for id: UUID) -> CameraProfile? {
        cameras.first { $0.id == id }
    }

    func enabledCameras() -> [CameraProfile] {
        cameras.filter(\.isEnabled)
    }

    var pwaURL: URL {
        URL(string: "https://localhost:\(httpsPort)/")!
    }

    /// iPhone からアクセスするときの URL 例（ホスト名は環境により異なる）。
    var pwaAccessURLDescription: String {
        let host = TLSCertificateEndpoints.current().commonName
        return "https://\(host):\(httpsPort)/"
    }

    private func persistCameras() {
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        defaults.set(data, forKey: Keys.cameras)
    }

    private func persistPushSubscriptions() {
        guard let data = try? JSONEncoder().encode(pushSubscriptions) else { return }
        defaults.set(data, forKey: Keys.pushSubscriptions)
    }
}

struct PushSubscriptionRecord: Codable, Hashable, Sendable {
    var endpoint: String
    var p256dh: String
    var auth: String
    var createdAt: Date
}
