import Foundation

enum BackupPathResolver {
    static func destinationURL(
        for file: Insta360CameraFile,
        camera: CameraProfile,
        settings: AppSettings
    ) -> URL {
        let filename = file.name
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

    enum DuplicateDestination {
        case download(to: URL, overwrite: Bool)
        case skipAlreadyPresent
    }

    static func resolveDuplicateDestination(
        proposed: URL,
        behavior: DuplicateFileBehavior,
        expectedSize: Int64?
    ) -> DuplicateDestination {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposed.path) else {
            return .download(to: proposed, overwrite: false)
        }

        let existingSize = fm.fileSize(at: proposed)
        if sizesMatch(expected: expectedSize, existing: existingSize) {
            return .skipAlreadyPresent
        }

        switch behavior {
        case .skip:
            if existingSize != nil, expectedSize != nil {
                AppLogger.shared.warning("Size mismatch for \(proposed.lastPathComponent), skipping")
            }
            return .skipAlreadyPresent
        case .overwrite:
            return .download(to: proposed, overwrite: true)
        case .addNumericSuffix:
            let destination = nextNumericSuffixURL(for: proposed)
            return .download(to: destination, overwrite: false)
        }
    }

    static func nextNumericSuffixURL(for proposed: URL) -> URL {
        let directory = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        var suffix = 1
        while true {
            let candidateName = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
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

    private static func sizesMatch(expected: Int64?, existing: Int64?) -> Bool {
        if let expected, let existing {
            return expected == existing
        }
        if expected == nil, existing != nil {
            return true
        }
        return false
    }

    private static func dateFolderName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
