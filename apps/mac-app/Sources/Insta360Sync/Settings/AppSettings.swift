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
        static let duplicateFileBehavior = "duplicateFileBehavior"
        static let scanIntervalSeconds = "scanIntervalSeconds"
        static let httpsPort = "httpsPort"
        static let apiToken = "apiToken"
        static let vapidPublicKey = "vapidPublicKey"
        static let vapidPrivateKey = "vapidPrivateKey"
        static let vapidSubject = "vapidSubject"
        static let publicHostname = "publicHostname"
        static let tlsCertificatePath = "tlsCertificatePath"
        static let tlsPrivateKeyPath = "tlsPrivateKeyPath"
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

    var duplicateFileBehavior: DuplicateFileBehavior {
        didSet { defaults.set(duplicateFileBehavior.rawValue, forKey: Keys.duplicateFileBehavior) }
    }

    var scanIntervalSeconds: TimeInterval {
        didSet { defaults.set(scanIntervalSeconds, forKey: Keys.scanIntervalSeconds) }
    }

    var httpsPort: UInt16 {
        didSet { defaults.set(Int(httpsPort), forKey: Keys.httpsPort) }
    }

    /// PWA / メニューバー表示用の公開ホスト名（例: sync.example.internal）。空なら自己署名 CN を使う。
    var publicHostname: String {
        didSet { defaults.set(publicHostname, forKey: Keys.publicHostname) }
    }

    /// Let's Encrypt 等の証明書 PEM（fullchain 推奨）。空なら自己署名。
    var tlsCertificatePath: String {
        didSet { defaults.set(tlsCertificatePath, forKey: Keys.tlsCertificatePath) }
    }

    /// 証明書に対応する秘密鍵 PEM。空なら自己署名。
    var tlsPrivateKeyPath: String {
        didSet { defaults.set(tlsPrivateKeyPath, forKey: Keys.tlsPrivateKeyPath) }
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

    /// VAPID JWT の `sub` クレーム。Apple は `.local` / `@localhost` 等を BadJwtToken で拒否する。
    var vapidSubject: String {
        didSet { defaults.set(vapidSubject, forKey: Keys.vapidSubject) }
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

        if let raw = defaults.string(forKey: Keys.duplicateFileBehavior),
           let behavior = DuplicateFileBehavior(rawValue: raw) {
            self.duplicateFileBehavior = behavior
        } else {
            self.duplicateFileBehavior = .skip
        }

        self.scanIntervalSeconds = defaults.object(forKey: Keys.scanIntervalSeconds) as? TimeInterval
            ?? Insta360Defaults.scanIntervalSeconds

        let port = defaults.object(forKey: Keys.httpsPort) as? Int ?? Int(Insta360Defaults.httpsPort)
        self.httpsPort = UInt16(clamping: port)

        self.publicHostname = defaults.string(forKey: Keys.publicHostname) ?? ""
        self.tlsCertificatePath = defaults.string(forKey: Keys.tlsCertificatePath) ?? ""
        self.tlsPrivateKeyPath = defaults.string(forKey: Keys.tlsPrivateKeyPath) ?? ""

        if let token = defaults.string(forKey: Keys.apiToken), !token.isEmpty {
            self.apiToken = token
        } else {
            self.apiToken = UUID().uuidString
        }

        self.vapidPublicKey = defaults.string(forKey: Keys.vapidPublicKey) ?? ""
        self.vapidPrivateKey = defaults.string(forKey: Keys.vapidPrivateKey) ?? ""
        self.vapidSubject = defaults.string(forKey: Keys.vapidSubject) ?? VAPIDKeys.defaultSubject
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

    /// カスタム証明書（証明書 PEM + 秘密鍵 PEM）が揃っているか。
    var usesCustomTLSCertificate: Bool {
        !tlsCertificatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !tlsPrivateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resolvedPublicHost: String {
        let custom = publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if usesCustomTLSCertificate {
            return "localhost"
        }
        return TLSCertificateEndpoints.current().commonName
    }

    var pwaURL: URL {
        URL(string: "https://\(resolvedPublicHost):\(httpsPort)/")!
    }

    /// iPhone からアクセスするときの URL 例（ホスト名は環境により異なる）。
    var pwaAccessURLDescription: String {
        "https://\(resolvedPublicHost):\(httpsPort)/"
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

struct PushSubscriptionRecord: Codable, Hashable, Sendable, Identifiable {
    var endpoint: String
    var p256dh: String
    var auth: String
    var createdAt: Date

    var id: String { endpoint }

    var endpointHost: String {
        guard let host = URL(string: endpoint)?.host else { return endpoint }
        return host
    }

    var endpointSuffix: String {
        String(endpoint.suffix(24))
    }
}
