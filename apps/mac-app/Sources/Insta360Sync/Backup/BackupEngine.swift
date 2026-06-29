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

        var manifest = SyncManifestStore.load(destinationRoot: settings.destinationRoot, cameraID: camera.id)
        let listedFiles = try await session.listAllFiles()
        let files = listedFiles.map { file in
            var updated = file
            updated.isSynced = SyncManifestStore.isSynced(file, manifest: manifest)
            return updated
        }

        var copied = 0
        var skipped = 0
        var failed = 0

        for (index, file) in files.enumerated() {
            progress(
                BackupProgress(
                    cameraName: camera.displayName,
                    completed: index,
                    total: files.count,
                    currentFile: file.name,
                    phase: "Downloading"
                )
            )

            if file.isSynced {
                skipped += 1
                continue
            }

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
                    SyncManifestStore.markSynced(file, manifest: &manifest)
                    skipped += 1
                    continue
                }
                if file.size == nil, existingSize != nil {
                    SyncManifestStore.markSynced(file, manifest: &manifest)
                    skipped += 1
                    continue
                }
                if existingSize != nil, file.size != nil, existingSize != file.size {
                    AppLogger.shared.warning("Size mismatch for \(destination.lastPathComponent), skipping")
                    skipped += 1
                    continue
                }
                if existingSize != nil {
                    SyncManifestStore.markSynced(file, manifest: &manifest)
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
                SyncManifestStore.markSynced(file, manifest: &manifest)
                copied += 1

                if file.storage == "sd",
                   file.name.lowercased().hasSuffix(".jpg"),
                   let rawPath = Insta360Paths.companionRawPath(for: file.sourcePath),
                   !files.contains(where: { $0.sourcePath == rawPath && $0.isSynced }) {
                    let rawName = (rawPath as NSString).lastPathComponent
                    let rawFile = Insta360CameraFile(
                        sourcePath: rawPath,
                        downloadURL: Insta360Paths.buildDownloadURL(
                            host: Insta360Defaults.cameraHost,
                            httpPort: Insta360Defaults.cameraHTTPPort,
                            sourcePath: rawPath
                        ),
                        createdAt: file.createdAt,
                        name: rawName,
                        storage: "sd",
                        captureTime: file.captureTime
                    )
                    var rawDestination = BackupPathResolver.destinationURL(
                        for: rawFile,
                        camera: camera,
                        settings: settings
                    )
                    rawDestination = BackupPathResolver.resolveCollisionURL(
                        proposed: rawDestination,
                        camera: camera,
                        expectedSize: nil
                    )
                    if !fm.fileExists(atPath: rawDestination.path) {
                        do {
                            _ = try await downloader.download(
                                file: rawFile,
                                to: rawDestination,
                                protocolKind: session.kind
                            )
                            SyncManifestStore.markSynced(rawFile, manifest: &manifest)
                            copied += 1
                        } catch {
                            AppLogger.shared.warning(
                                "Companion DNG skipped for \(rawName): \(error.localizedDescription)"
                            )
                        }
                    }
                }
            } catch {
                failed += 1
                AppLogger.shared.error("Download failed for \(file.sourcePath): \(error.localizedDescription)")
            }
        }

        try? SyncManifestStore.save(manifest, destinationRoot: settings.destinationRoot, cameraID: camera.id)

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
