import Foundation

struct CameraProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var ssid: String
    var wifiPassword: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        ssid: String,
        wifiPassword: String = Insta360Defaults.defaultWiFiPassword,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.ssid = ssid
        self.wifiPassword = wifiPassword
        self.isEnabled = isEnabled
    }

    var folderSlug: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ssid.replacingOccurrences(of: " ", with: "-")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = trimmed
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return slug.isEmpty ? id.uuidString.prefix(8).description : slug
    }
}

enum FolderStructureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserveOriginal
    case byDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .preserveOriginal: "オリジナル構造"
        case .byDate: "日付別"
        }
    }
}

enum Insta360Defaults {
    static let cameraHost = "192.168.42.1"
    static let cameraTCPPort: UInt16 = 6666
    static let cameraHTTPPort: UInt16 = 80
    static let defaultWiFiPassword = "88888888"
    static let httpsPort: UInt16 = 9443
    static let scanIntervalSeconds: TimeInterval = 30
}

enum AppStatus: Equatable, Sendable {
    case stopped
    case running
    case error(String)
}

struct BackupProgress: Equatable, Codable, Sendable {
    var cameraName: String
    var completed: Int
    var total: Int
    var currentFile: String?
    var phase: String
}

struct PendingBackup: Codable, Identifiable, Sendable {
    var id: UUID
    var cameraID: UUID
    var cameraName: String
    var ssid: String
    var detectedAt: Date
    var status: PendingStatus

    enum PendingStatus: String, Codable, Sendable {
        case pending
        case approved
        case skipped
        case running
        case completed
        case failed
    }
}

struct BackupHistoryEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var cameraName: String
    var startedAt: Date
    var finishedAt: Date?
    var copiedCount: Int
    var skippedCount: Int
    var failedCount: Int
    var message: String?
}
