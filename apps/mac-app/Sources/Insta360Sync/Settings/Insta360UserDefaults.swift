import Foundation

enum Insta360UserDefaults: @unchecked Sendable {
    private static let suiteName = "com.oboenikui.insta360-sync"

    private static let migrationKeys = [
        "cameras",
        "destinationRoot",
        "folderStructureMode",
        "scanIntervalSeconds",
        "httpsPort",
        "apiToken",
        "vapidPublicKey",
        "vapidPrivateKey",
        "autoStartOnLaunch",
        "pushSubscriptions",
    ]

    static func store() -> UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func migrateLegacySettingsIfNeeded() {
        let shared = store()
        guard shared.string(forKey: "apiToken") == nil else { return }
        guard let token = UserDefaults.standard.string(forKey: "apiToken"), !token.isEmpty else { return }

        for key in migrationKeys {
            guard shared.object(forKey: key) == nil, let value = UserDefaults.standard.object(forKey: key) else { continue }
            shared.set(value, forKey: key)
        }
    }
}
