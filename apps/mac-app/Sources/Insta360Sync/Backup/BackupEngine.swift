import Foundation

struct BackupResult: Sendable {
    var copiedCount: Int
    var skippedCount: Int
    var failedCount: Int
    var protocolKind: CameraProtocolKind
}

final class BackupEngine: @unchecked Sendable {
    private let downloader = FileDownloader()

    func runBackup(
        camera: CameraProfile,
        settings: AppSettings,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> BackupResult {
        try FileManager.default.createDirectory(at: settings.destinationRoot, withIntermediateDirectories: true)

        let session = try await CameraSession.connect()
        defer { session.close() }

        progress(
            BackupProgress(
                cameraName: camera.displayName,
                completed: 0,
                total: 0,
                currentFile: nil,
                phase: "Listing files (\(session.kind.rawValue))"
            )
        )

        let files = try await session.listAllFiles()
        var copied = 0
        var skipped = 0
        var failed = 0

        for (index, file) in files.enumerated() {
            progress(
                BackupProgress(
                    cameraName: camera.displayName,
                    completed: index,
                    total: files.count,
                    currentFile: (file.sourcePath as NSString).lastPathComponent,
                    phase: "Downloading"
                )
            )

            var destination = BackupPathResolver.destinationURL(for: file, camera: camera, settings: settings)
            destination = BackupPathResolver.resolveCollisionURL(
                proposed: destination,
                camera: camera,
                expectedSize: file.size
            )

            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                let existingSize = fm.fileSize(at: destination)
                if let expected = file.size, let existingSize, existingSize == expected {
                    skipped += 1
                    continue
                }
                if file.size == nil, existingSize != nil {
                    skipped += 1
                    continue
                }
                if existingSize != nil, file.size != nil, existingSize != file.size {
                    AppLogger.shared.warning("Size mismatch for \(destination.lastPathComponent), skipping")
                    skipped += 1
                    continue
                }
                if existingSize != nil {
                    skipped += 1
                    continue
                }
            }

            do {
                _ = try await downloader.download(
                    file: file,
                    to: destination,
                    protocolKind: session.kind
                )
                copied += 1
            } catch {
                failed += 1
                AppLogger.shared.error("Download failed for \(file.sourcePath): \(error.localizedDescription)")
            }
        }

        progress(
            BackupProgress(
                cameraName: camera.displayName,
                completed: files.count,
                total: files.count,
                currentFile: nil,
                phase: "Completed"
            )
        )

        progress(
            BackupProgress(
                cameraName: camera.displayName,
                completed: files.count,
                total: files.count,
                currentFile: nil,
                phase: "Disconnecting"
            )
        )

        return BackupResult(
            copiedCount: copied,
            skippedCount: skipped,
            failedCount: failed,
            protocolKind: session.kind
        )
    }
}
