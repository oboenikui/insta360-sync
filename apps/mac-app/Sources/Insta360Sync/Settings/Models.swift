import Foundation

struct CameraProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var ssid: String
    var wifiPassword: String
    var isEnabled: Bool
    /// バックアップ保存先の絶対パス。空文字は未設定。
    var destinationRootPath: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case ssid
        case wifiPassword
        case isEnabled
        case destinationRootPath
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        ssid: String,
        wifiPassword: String = "",
        isEnabled: Bool = true,
        destinationRootPath: String
    ) {
        self.id = id
        self.displayName = displayName
        self.ssid = ssid
        self.wifiPassword = wifiPassword
        self.isEnabled = isEnabled
        self.destinationRootPath = destinationRootPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        ssid = try container.decode(String.self, forKey: .ssid)
        wifiPassword = try container.decodeIfPresent(String.self, forKey: .wifiPassword) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        destinationRootPath = try container.decodeIfPresent(String.self, forKey: .destinationRootPath) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(ssid, forKey: .ssid)
        try container.encode(wifiPassword, forKey: .wifiPassword)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(destinationRootPath, forKey: .destinationRootPath)
    }

    /// 設定済みの保存先。未設定のときは `nil`。
    var destinationRoot: URL? {
        let trimmed = destinationRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    var hasDestination: Bool { destinationRoot != nil }

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

enum DuplicateFileBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case addNumericSuffix
    case overwrite
    case skip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .addNumericSuffix: "番号サフィックスを付けて保存（_1, _2 …）"
        case .overwrite: "上書き"
        case .skip: "何もしない（スキップ）"
        }
    }
}

enum Insta360Defaults {
    static let cameraHost = "192.168.42.1"
    static let cameraTCPPort: UInt16 = 6666
    static let cameraHTTPPort: UInt16 = 80
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

struct BackupFailure: Codable, Equatable, Sendable {
    var path: String
    var error: String
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
    var failures: [BackupFailure] = []
}
