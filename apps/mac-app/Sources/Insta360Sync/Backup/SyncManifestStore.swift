import Foundation

struct SyncedFileRecord: Codable, Equatable, Sendable {
    var name: String
    var storage: String
    var size: Int64?
    var captureTime: Int64?
    var syncedAt: Date

    func matches(file: Insta360CameraFile) -> Bool {
        guard name == file.name, storage == file.storage else { return false }
        if let expected = size, let actual = file.size, expected != actual { return false }
        if let expected = captureTime, let actual = file.captureTime, expected != actual { return false }
        return true
    }
}

struct SyncManifest: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var files: [String: SyncedFileRecord]

    static func empty() -> SyncManifest {
        SyncManifest(version: currentVersion, files: [:])
    }
}

enum SyncManifestStore {
    private static let directoryName = ".insta360-sync"
    private static let fileName = "manifest.json"

    static func manifestURL(destinationRoot: URL, cameraID: UUID) -> URL {
        destinationRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(cameraID.uuidString).json", isDirectory: false)
    }

    static func load(destinationRoot: URL, cameraID: UUID) -> SyncManifest {
        let url = manifestURL(destinationRoot: destinationRoot, cameraID: cameraID)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder.iso8601.decode(SyncManifest.self, from: data),
              manifest.version == SyncManifest.currentVersion else {
            return .empty()
        }
        return manifest
    }

    static func save(_ manifest: SyncManifest, destinationRoot: URL, cameraID: UUID) throws {
        let url = manifestURL(destinationRoot: destinationRoot, cameraID: cameraID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.iso8601.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    static func isSynced(_ file: Insta360CameraFile, manifest: SyncManifest) -> Bool {
        guard let record = manifest.files[file.sourcePath] else { return false }
        return record.matches(file: file)
    }

    static func markSynced(_ file: Insta360CameraFile, manifest: inout SyncManifest) {
        manifest.version = SyncManifest.currentVersion
        manifest.files[file.sourcePath] = SyncedFileRecord(
            name: file.name,
            storage: file.storage,
            size: file.size,
            captureTime: file.captureTime,
            syncedAt: Date()
        )
    }
}

private let manifestFlushInterval: Duration = .seconds(5)

actor SyncManifestFlushScheduler {
    private var manifest: SyncManifest
    private let destinationRoot: URL
    private let cameraID: UUID
    private var dirty = false
    private var flushTask: Task<Void, Never>?

    init(manifest: SyncManifest, destinationRoot: URL, cameraID: UUID) {
        self.manifest = manifest
        self.destinationRoot = destinationRoot
        self.cameraID = cameraID
    }

    func markSynced(_ file: Insta360CameraFile) {
        SyncManifestStore.markSynced(file, manifest: &manifest)
        dirty = true
        startFlushLoopIfNeeded()
    }

    func finish() {
        flushTask?.cancel()
        flushTask = nil
        flushIfNeeded()
    }

    private func startFlushLoopIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: manifestFlushInterval)
                guard !Task.isCancelled else { break }
                flushIfNeeded()
            }
        }
    }

    private func flushIfNeeded() {
        guard dirty else { return }
        try? SyncManifestStore.save(manifest, destinationRoot: destinationRoot, cameraID: cameraID)
        dirty = false
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
