import Foundation

enum Insta360Paths {
    private static let storagePathPattern = #"/storage_[a-z0-9_]+/DCIM/Camera\d+/[A-Z0-9_]+\.[A-Za-z0-9]+"#
    private static let sdPathPattern = #"/DCIM/Camera\d+/[A-Z0-9_]+\.[A-Za-z0-9]+"#
    private static let filenamePattern = #"^[A-Z0-9_]+\.[A-Za-z0-9]+$"#

    static func storageFromPath(_ path: String) -> String {
        if path.hasPrefix("/storage_internal/") {
            return "internal"
        }
        if path.hasPrefix("/storage_") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                let segment = String(parts[1])
                if segment.hasPrefix("storage_") {
                    return String(segment.dropFirst("storage_".count))
                }
                return segment
            }
        }
        return "sd"
    }

    static func localFilename(name: String, storage: String) -> String {
        if storage.isEmpty || storage == "sd" {
            return name
        }
        let filename = name as NSString
        let ext = filename.pathExtension
        let suffix = storage == "internal" ? "internal" : storage
        if ext.isEmpty {
            return "\(name)_\(suffix)"
        }
        return "\(filename.deletingPathExtension)_\(suffix).\(ext)"
    }

    static func displayLabel(storage: String) -> String {
        switch storage {
        case "sd":
            return "SD"
        case "internal":
            return "本体"
        default:
            return storage
        }
    }

    static func buildDownloadURL(host: String, httpPort: UInt16, sourcePath: String) -> URL {
        URL(string: "http://\(host):\(httpPort)\(sourcePath)")!
    }

    static func parseMediaPaths(from data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        let filenameRegex = try? NSRegularExpression(pattern: filenamePattern)
        var seen = Set<String>()
        var paths: [String] = []
        var occupied: [NSRange] = []

        func isValidFilename(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            guard let filenameRegex else { return true }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return filenameRegex.firstMatch(in: name, range: range) != nil
        }

        func appendPath(_ path: String, range: NSRange) {
            guard !seen.contains(path), isValidFilename(path) else { return }
            seen.insert(path)
            paths.append(path)
            occupied.append(range)
        }

        func overlaps(_ range: NSRange) -> Bool {
            occupied.contains { NSIntersectionRange($0, range).length > 0 }
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let storageRegex = try? NSRegularExpression(pattern: storagePathPattern) {
            for match in storageRegex.matches(in: text, range: fullRange) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                appendPath(String(text[swiftRange]), range: match.range)
            }
        }
        if let sdRegex = try? NSRegularExpression(pattern: sdPathPattern) {
            for match in sdRegex.matches(in: text, range: fullRange) {
                if overlaps(match.range) { continue }
                guard let swiftRange = Range(match.range, in: text) else { continue }
                appendPath(String(text[swiftRange]), range: match.range)
            }
        }
        return dedupeStoragePaths(paths)
    }

    static func dedupeStoragePaths(_ paths: [String]) -> [String] {
        let internalSuffixes = Set(
            paths
                .filter { $0.hasPrefix("/storage_internal/") }
                .map { String($0.dropFirst("/storage_internal".count)) }
        )
        guard !internalSuffixes.isEmpty else { return paths }
        return paths.filter { path in
            !(path.hasPrefix("/DCIM/") && internalSuffixes.contains(path))
        }
    }
}
