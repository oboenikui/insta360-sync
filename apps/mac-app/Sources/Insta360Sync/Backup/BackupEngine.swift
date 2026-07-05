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

        let manifest = SyncManifestStore.load(destinationRoot: settings.destinationRoot, cameraID: camera.id)
        let manifestScheduler = SyncManifestFlushScheduler(
            manifest: manifest,
            destinationRoot: settings.destinationRoot,
            cameraID: camera.id
        )

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

            let proposed = BackupPathResolver.destinationURL(for: file, camera: camera, settings: settings)
            let resolution = BackupPathResolver.resolveDuplicateDestination(
                proposed: proposed,
                behavior: settings.duplicateFileBehavior,
                expectedSize: file.size
            )

            switch resolution {
            case .skipAlreadyPresent:
                await manifestScheduler.markSynced(file)
                skipped += 1
                continue
            case let .download(destination, overwrite):
                do {
                    _ = try await downloader.download(
                        file: file,
                        to: destination,
                        protocolKind: session.kind,
                        overwrite: overwrite
                    )
                    await manifestScheduler.markSynced(file)
                    copied += 1

                    if file.storage == "sd",
                       file.name.lowercased().hasSuffix(".jpg"),
                       let rawPath = Insta360Paths.companionRawPath(for: file.sourcePath),
                       !files.contains(where: { $0.sourcePath == rawPath && $0.isSynced }) {
                        try await downloadCompanionRaw(
                            rawPath: rawPath,
                            referenceFile: file,
                            camera: camera,
                            settings: settings,
                            session: session,
                            manifestScheduler: manifestScheduler,
                            copied: &copied
                        )
                    }
                } catch {
                    failed += 1
                    AppLogger.shared.error("Download failed for \(file.sourcePath): \(error.localizedDescription)")
                }
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

        await manifestScheduler.finish()

        return BackupResult(
            copiedCount: copied,
            skippedCount: skipped,
            failedCount: failed,
            protocolKind: session.kind
        )
    }

    private func downloadCompanionRaw(
        rawPath: String,
        referenceFile: Insta360CameraFile,
        camera: CameraProfile,
        settings: AppSettings,
        session: CameraSession,
        manifestScheduler: SyncManifestFlushScheduler,
        copied: inout Int
    ) async throws {
        let rawName = (rawPath as NSString).lastPathComponent
        let rawFile = Insta360CameraFile(
            sourcePath: rawPath,
            downloadURL: Insta360Paths.buildDownloadURL(
                host: Insta360Defaults.cameraHost,
                httpPort: Insta360Defaults.cameraHTTPPort,
                sourcePath: rawPath
            ),
            createdAt: referenceFile.createdAt,
            name: rawName,
            storage: "sd",
            captureTime: referenceFile.captureTime
        )
        let proposed = BackupPathResolver.destinationURL(for: rawFile, camera: camera, settings: settings)
        let resolution = BackupPathResolver.resolveDuplicateDestination(
            proposed: proposed,
            behavior: settings.duplicateFileBehavior,
            expectedSize: nil
        )

        switch resolution {
        case .skipAlreadyPresent:
            await manifestScheduler.markSynced(rawFile)
        case let .download(destination, overwrite):
            do {
                _ = try await downloader.download(
                    file: rawFile,
                    to: destination,
                    protocolKind: session.kind,
                    overwrite: overwrite
                )
                await manifestScheduler.markSynced(rawFile)
                copied += 1
            } catch {
                AppLogger.shared.warning(
                    "Companion DNG skipped for \(rawName): \(error.localizedDescription)"
                )
            }
        }
    }
}
