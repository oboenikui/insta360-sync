import Foundation

struct BackupResult: Sendable {
    var copiedCount: Int
    var skippedCount: Int
    var failedCount: Int
    var failures: [BackupFailure]
    var protocolKind: CameraProtocolKind
}

enum BackupEngineError: LocalizedError {
    case destinationNotConfigured

    var errorDescription: String? {
        switch self {
        case .destinationNotConfigured:
            "カメラの保存先が設定されていません"
        }
    }
}

final class BackupEngine: @unchecked Sendable {
    private let downloader = FileDownloader()

    func runBackup(
        camera: CameraProfile,
        settings: AppSettings,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> BackupResult {
        guard let destinationRoot = camera.destinationRoot else {
            throw BackupEngineError.destinationNotConfigured
        }
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

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

        let manifest = SyncManifestStore.load(destinationRoot: destinationRoot, cameraID: camera.id)
        let manifestScheduler = SyncManifestFlushScheduler(
            manifest: manifest,
            destinationRoot: destinationRoot,
            cameraID: camera.id
        )

        let unavailablePaths = SyncManifestStore.unavailable404Paths(in: manifest)

        let listedFiles = try await session.listAllFiles()
            .filter { !unavailablePaths.contains($0.sourcePath) }
        let files = listedFiles.map { file in
            var updated = file
            updated.isSynced = SyncManifestStore.isSynced(file, manifest: manifest)
            return updated
        }

        var copied = 0
        var skipped = 0
        var failed = 0
        var failures: [BackupFailure] = []

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

            let proposed = BackupPathResolver.destinationURL(
                for: file,
                camera: camera,
                destinationRoot: destinationRoot,
                settings: settings
            )
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
                if file.isInferredCompanion {
                    switch await downloader.probeRemoteFile(url: file.downloadURL) {
                    case .notFound:
                        await manifestScheduler.markUnavailable404(file)
                        skipped += 1
                        AppLogger.shared.debug("Inferred companion DNG not found: \(file.name)")
                        continue
                    case .available, .inconclusive:
                        break
                    }
                }
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
                       !files.contains(where: { $0.sourcePath == rawPath }) {
                        try await downloadCompanionRaw(
                            rawPath: rawPath,
                            referenceFile: file,
                            camera: camera,
                            destinationRoot: destinationRoot,
                            settings: settings,
                            session: session,
                            manifestScheduler: manifestScheduler,
                            copied: &copied,
                            failed: &failed,
                            failures: &failures
                        )
                    }
                } catch {
                    if file.isInferredCompanion, FileDownloader.isHTTPNotFound(error) {
                        await manifestScheduler.markUnavailable404(file)
                        skipped += 1
                        AppLogger.shared.debug(
                            "Inferred companion DNG not found: \(file.name)"
                        )
                        continue
                    }
                    failed += 1
                    failures.append(
                        BackupFailure(path: file.sourcePath, error: error.localizedDescription)
                    )
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
            failures: failures,
            protocolKind: session.kind
        )
    }

    private func downloadCompanionRaw(
        rawPath: String,
        referenceFile: Insta360CameraFile,
        camera: CameraProfile,
        destinationRoot: URL,
        settings: AppSettings,
        session: CameraSession,
        manifestScheduler: SyncManifestFlushScheduler,
        copied: inout Int,
        failed: inout Int,
        failures: inout [BackupFailure]
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
        let proposed = BackupPathResolver.destinationURL(
            for: rawFile,
            camera: camera,
            destinationRoot: destinationRoot,
            settings: settings
        )
        let resolution = BackupPathResolver.resolveDuplicateDestination(
            proposed: proposed,
            behavior: settings.duplicateFileBehavior,
            expectedSize: nil
        )

        switch resolution {
        case .skipAlreadyPresent:
            await manifestScheduler.markSynced(rawFile)
        case let .download(destination, overwrite):
            if await manifestScheduler.isUnavailable404(sourcePath: rawPath) {
                return
            }
            switch await downloader.probeRemoteFile(url: rawFile.downloadURL) {
            case .notFound:
                await manifestScheduler.markUnavailable404(rawFile)
                AppLogger.shared.debug("Companion DNG not found: \(rawName)")
                return
            case .available, .inconclusive:
                break
            }
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
                if FileDownloader.isHTTPNotFound(error) {
                    await manifestScheduler.markUnavailable404(rawFile)
                    AppLogger.shared.debug("Companion DNG not found: \(rawName)")
                    return
                }
                failed += 1
                failures.append(
                    BackupFailure(path: rawPath, error: error.localizedDescription)
                )
                AppLogger.shared.error("Download failed for \(rawPath): \(error.localizedDescription)")
            }
        }
    }
}
