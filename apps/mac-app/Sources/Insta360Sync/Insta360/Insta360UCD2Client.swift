import Foundation
import Network

/// Luna Ultra 等が使う UCD2 プロトコル (TCP/6666)。
/// insta360-wifi-api の syNceNdinS 形式とは非互換。
final class Insta360UCD2Client: @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "insta360.ucd2")
    private var receiveBuffer = Data()

    init(host: String = Insta360Defaults.cameraHost, port: UInt16 = Insta360Defaults.cameraTCPPort) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func open() async throws {
        close()
        let conn = NWConnection(host: host, port: port, using: .tcp)
        connection = conn
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    conn.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        startReceiving()
        try await sendReplay()
    }

    func close() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
    }

    func listAllFiles() async throws -> [Insta360CameraFile] {
        let deadline = Date().addingTimeInterval(15)
        var bestPaths: [String] = []
        var lastCount = 0
        var stableSince: Date?
        while Date() < deadline {
            let current = Self.extractPaths(from: receiveBuffer)
            if current.count > lastCount {
                bestPaths = current
                lastCount = current.count
                stableSince = Date()
            } else if !bestPaths.isEmpty, let stableSince, Date().timeIntervalSince(stableSince) >= 1.0 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let finalPaths = Self.dedupeStoragePaths(bestPaths)
        guard !finalPaths.isEmpty else {
            throw Insta360ClientError.cameraError("UCD2 file list timed out")
        }
        return finalPaths.map { path in
            Insta360CameraFile(
                sourcePath: path,
                downloadURL: URL(string: "http://\(Insta360Defaults.cameraHost):\(Insta360Defaults.cameraHTTPPort)\(path)")!,
                size: nil,
                createdAt: BackupPathResolver.parseCreationDate(fromFilename: (path as NSString).lastPathComponent)
            )
        }
    }

    private func sendReplay() async throws {
        guard let sync = Self.loadResource("sync", ext: "bin") else {
            throw Insta360ClientError.unsupported
        }
        guard let handshake = Self.loadResource("handshake", ext: "bin") else {
            throw Insta360ClientError.unsupported
        }
        try await send(sync)
        try await Task.sleep(for: .milliseconds(50))
        // handshake.bin omits cmd 0x0202 (phone time / Asia/Tokyo) to avoid shifting camera clock.
        for packet in Self.splitUCD2Packets(handshake) {
            try await send(packet)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// UCD2 packets are concatenated in handshake.bin; split before send (matches Python client).
    private static func splitUCD2Packets(_ stream: Data) -> [Data] {
        var packets: [Data] = []
        var offset = 0
        let bytes = [UInt8](stream)
        while offset + 16 <= bytes.count {
            guard bytes[offset] == 0x55, bytes[offset + 1] == 0x43,
                  bytes[offset + 2] == 0x44, bytes[offset + 3] == 0x32 else {
                offset += 1
                continue
            }
            let payloadLen = Int(bytes[offset + 8])
                | (Int(bytes[offset + 9]) << 8)
                | (Int(bytes[offset + 10]) << 16)
                | (Int(bytes[offset + 11]) << 24)
            let end = offset + 12 + payloadLen + 4
            guard end <= bytes.count, end > offset else { break }
            packets.append(Data(bytes[offset..<end]))
            offset = end
        }
        return packets
    }

    private func send(_ data: Data) async throws {
        guard let connection else { throw Insta360ClientError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func startReceiving() {
        receiveNextChunk()
    }

    private func receiveNextChunk() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
            }
            if error != nil || isComplete {
                return
            }
            self.receiveNextChunk()
        }
    }

    private static func loadResource(_ name: String, ext: String) -> Data? {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "ucd2"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "ucd2"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return nil
    }

    private static func extractPaths(from data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        let storagePattern = #"/storage_[a-z0-9_]+/DCIM/Camera\d+/[A-Z0-9_]+\.[A-Za-z0-9]+"#
        let sdPattern = #"/DCIM/Camera\d+/[A-Z0-9_]+\.[A-Za-z0-9]+"#
        let filenamePattern = #"^[A-Z0-9_]+\.[A-Za-z0-9]+$"#
        let filenameRegex = try? NSRegularExpression(pattern: filenamePattern)

        func isValidFilename(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            guard let filenameRegex else { return true }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return filenameRegex.firstMatch(in: name, range: range) != nil
        }

        var seen = Set<String>()
        var paths: [String] = []
        var occupied: [NSRange] = []

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
        if let storageRegex = try? NSRegularExpression(pattern: storagePattern) {
            for match in storageRegex.matches(in: text, range: fullRange) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                appendPath(String(text[swiftRange]), range: match.range)
            }
        }
        if let sdRegex = try? NSRegularExpression(pattern: sdPattern) {
            for match in sdRegex.matches(in: text, range: fullRange) {
                if overlaps(match.range) { continue }
                guard let swiftRange = Range(match.range, in: text) else { continue }
                appendPath(String(text[swiftRange]), range: match.range)
            }
        }
        return dedupeStoragePaths(paths)
    }

    private static func dedupeStoragePaths(_ paths: [String]) -> [String] {
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
