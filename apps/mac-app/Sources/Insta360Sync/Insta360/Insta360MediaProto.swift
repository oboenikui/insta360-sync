import Foundation

struct MediaFileEntry: Equatable, Sendable {
    var sourcePath: String
    var size: Int64?
    var captureTime: Int64?
}

enum Insta360MediaProto {
    private static let captureTimePattern = #"^(?:VID|IMG|LRV)_(\d{4})(\d{2})(\d{2})_(\d{6})"#

    static func captureTimeFromFilename(_ name: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: captureTimePattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              match.numberOfRanges >= 5,
              let yRange = Range(match.range(at: 1), in: name),
              let mRange = Range(match.range(at: 2), in: name),
              let dRange = Range(match.range(at: 3), in: name),
              let tRange = Range(match.range(at: 4), in: name) else {
            return nil
        }
        let digits = "\(name[yRange])\(name[mRange])\(name[dRange])\(name[tRange])"
        return Int64(digits)
    }

    static func parseMediaFileEntries(from data: Data) -> [MediaFileEntry] {
        let paths = Insta360Paths.parseMediaPaths(from: data)
        let bytes = [UInt8](data)
        return paths.map { path in
            var captureTime: Int64?
            var size: Int64?
            let pathBytes = Array(path.utf8)
            guard !pathBytes.isEmpty, !bytes.isEmpty else {
                let name = (path as NSString).lastPathComponent
                return MediaFileEntry(
                    sourcePath: path,
                    size: nil,
                    captureTime: captureTimeFromFilename(name)
                )
            }

            var search = 0
            while search <= bytes.count - pathBytes.count {
                guard let idx = indexOf(pathBytes, in: bytes, startingAt: search) else { break }
                if let meta = metaAtPath(bytes: bytes, pathOffset: idx, pathLength: pathBytes.count) {
                    if let ct = meta.captureTime { captureTime = ct }
                    if let sz = meta.size { size = sz }
                    if captureTime != nil || size != nil { break }
                }
                search = idx + 1
            }
            let name = (path as NSString).lastPathComponent
            if captureTime == nil {
                captureTime = captureTimeFromFilename(name)
            }
            return MediaFileEntry(sourcePath: path, size: size, captureTime: captureTime)
        }
    }

    private static func metaAtPath(bytes: [UInt8], pathOffset: Int, pathLength: Int) -> MediaFileEntry? {
        guard pathOffset >= 0,
              pathLength > 0,
              pathOffset + pathLength <= bytes.count else {
            return nil
        }
        let start = max(0, pathOffset - 12)
        for tagPos in start..<pathOffset {
            guard tagPos < bytes.count, bytes[tagPos] == 0x0A else { continue }
            guard tagPos + 1 < bytes.count,
                  let strLen = readVarint(bytes, offset: tagPos + 1) else { continue }
            let (length, strStart) = strLen
            guard strStart == pathOffset, length == pathLength else { continue }
            return parseFileEntry(Array(bytes[tagPos...]))
        }
        return nil
    }

    private static func parseFileEntry(_ entry: [UInt8]) -> MediaFileEntry? {
        var offset = 0
        var captureTime: Int64?
        var size: Int64?
        while offset < entry.count {
            guard let keyPair = readVarint(entry, offset: offset) else { break }
            let (key, next) = keyPair
            offset = next
            let field = Int(key >> 3)
            let wire = Int(key & 0x07)
            switch wire {
            case 0:
                guard let valuePair = readVarint(entry, offset: offset) else { return nil }
                offset = valuePair.1
            case 2:
                guard let lenPair = readVarint(entry, offset: offset) else { return nil }
                let (length, lenNext) = lenPair
                offset = lenNext
                guard offset + length <= entry.count else { return nil }
                if field == 1 {
                    offset += length
                } else if field == 2 {
                    let meta = Array(entry[offset..<(offset + length)])
                    offset += length
                    if let nested = parseNestedMeta(meta) {
                        if let ct = nested.captureTime { captureTime = ct }
                        if let sz = nested.size { size = sz }
                    }
                    return MediaFileEntry(sourcePath: "", size: size, captureTime: captureTime)
                } else {
                    offset += length
                }
            case 1:
                offset += 8
            case 5:
                offset += 4
            default:
                return MediaFileEntry(sourcePath: "", size: size, captureTime: captureTime)
            }
        }
        return MediaFileEntry(sourcePath: "", size: size, captureTime: captureTime)
    }

    private static func parseNestedMeta(_ meta: [UInt8]) -> MediaFileEntry? {
        var offset = 0
        var captureTime: Int64?
        var size: Int64?
        while offset < meta.count {
            guard let keyPair = readVarint(meta, offset: offset) else { break }
            let (key, next) = keyPair
            offset = next
            let field = Int(key >> 3)
            let wire = Int(key & 0x07)
            switch wire {
            case 0:
                guard let valuePair = readVarint(meta, offset: offset) else { return nil }
                let (value, valueNext) = valuePair
                offset = valueNext
                if field == 7 { captureTime = Int64(value) }
                if field == 9 { size = Int64(value) }
            case 2:
                guard let lenPair = readVarint(meta, offset: offset) else { return nil }
                let (length, lenNext) = lenPair
                offset = lenNext + length
            case 1:
                offset += 8
            case 5:
                offset += 4
            default:
                return MediaFileEntry(sourcePath: "", size: size, captureTime: captureTime)
            }
        }
        return MediaFileEntry(sourcePath: "", size: size, captureTime: captureTime)
    }

    private static func indexOf(_ needle: [UInt8], in haystack: [UInt8], startingAt start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, start <= haystack.count - needle.count else { return nil }
        let limit = haystack.count - needle.count
        for index in start...limit {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
        }
        return nil
    }

    private static func readVarint(_ bytes: [UInt8], offset: Int) -> (Int, Int)? {
        var result = 0
        var shift = 0
        var index = offset
        while index < bytes.count {
            let byte = Int(bytes[index])
            index += 1
            result |= (byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return (result, index)
            }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
