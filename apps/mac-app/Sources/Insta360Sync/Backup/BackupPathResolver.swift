import Foundation

enum BackupPathResolver {
    static func destinationURL(
        for file: Insta360CameraFile,
        camera: CameraProfile,
        settings: AppSettings
    ) -> URL {
        let filename = localFilename(for: file)
        switch settings.folderStructureMode {
        case .preserveOriginal:
            let relative = file.sourcePath.hasPrefix("/") ? String(file.sourcePath.dropFirst()) : file.sourcePath
            return settings.destinationRoot
                .appendingPathComponent(camera.folderSlug, isDirectory: true)
                .appendingPathComponent(relative, isDirectory: false)
        case .byDate:
            let date = file.createdAt ?? parseCreationDate(fromFilename: filename) ?? Date()
            let folder = dateFolderName(date)
            return settings.destinationRoot
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
        }
    }

    static func localFilename(for file: Insta360CameraFile) -> String {
        Insta360Paths.localFilename(name: file.name, storage: file.storage)
    }

    static func resolveCollisionURL(
        proposed: URL,
        camera: CameraProfile,
        expectedSize: Int64?
    ) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposed.path) else { return proposed }
        let existingSize = fm.fileSize(at: proposed)
        if let expectedSize, let existingSize, existingSize == expectedSize {
            return proposed
        }
        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent
        let renamed = ext.isEmpty
            ? "\(base)_\(camera.folderSlug)"
            : "\(base)_\(camera.folderSlug).\(ext)"
        return proposed.deletingLastPathComponent().appendingPathComponent(renamed, isDirectory: false)
    }

    static func parseCreationDate(fromFilename filename: String) -> Date? {
        let patterns = [
            #"^(?:VID|IMG|LRV)_(\d{4})(\d{2})(\d{2})_"#,
            #"^(?:VID|IMG|LRV)_(\d{4})(\d{2})(\d{2})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
                  match.numberOfRanges >= 4,
                  let yRange = Range(match.range(at: 1), in: filename),
                  let mRange = Range(match.range(at: 2), in: filename),
                  let dRange = Range(match.range(at: 3), in: filename) else { continue }
            var components = DateComponents()
            components.year = Int(filename[yRange])
            components.month = Int(filename[mRange])
            components.day = Int(filename[dRange])
            if let date = Calendar.current.date(from: components) {
                return date
            }
        }
        return nil
    }

    private static func dateFolderName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
