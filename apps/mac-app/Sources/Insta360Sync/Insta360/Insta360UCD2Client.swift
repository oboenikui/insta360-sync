import Foundation
import Network

/// Luna Ultra 等が使う UCD2 プロトコル (TCP/6666)。
/// insta360-wifi-api の syNceNdinS 形式とは非互換。
final class Insta360UCD2Client: @unchecked Sendable {
    private let hostString: String
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "insta360.ucd2")
    private var receiveBuffer = Data()
    private var isClosed = true

    init(host: String = Insta360Defaults.cameraHost, port: UInt16 = Insta360Defaults.cameraTCPPort) {
        self.hostString = host
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func open() async throws {
        close()
        isClosed = false
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
    }

    func close() {
        isClosed = true
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
    }

    func listAllFiles() async throws -> [Insta360CameraFile] {
        let handshakeStarted = Date()
        let totalWait: TimeInterval = 30
        let deadline = handshakeStarted.addingTimeInterval(totalWait)

        let handshakeTask = Task {
            try await self.sendPhasedReplay()
        }

        var bestPaths: [String] = []
        var lastCount = 0
        var stableSince: Date?
        while Date() < deadline {
            let current = Insta360Paths.parseMediaPaths(from: receiveBuffer)
            if current.count > lastCount {
                bestPaths = current
                lastCount = current.count
                stableSince = Date()
            } else if !bestPaths.isEmpty, let since = stableSince {
                let elapsed = Date().timeIntervalSince(handshakeStarted)
                let (sdJpg, sdDng) = Self.countSDRaw(paths: bestPaths)
                let waitingForSDDng = sdJpg > 0 && sdDng == 0
                if elapsed < 10 || waitingForSDDng {
                    if Date().timeIntervalSince(since) >= 2.0 {
                        stableSince = Date()
                    }
                } else if Date().timeIntervalSince(since) >= 2.0 {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        do {
            try await handshakeTask.value
        } catch {
            handshakeTask.cancel()
            throw error
        }

        let entries = Insta360MediaProto.parseMediaFileEntries(from: receiveBuffer)
        guard !entries.isEmpty else {
            throw Insta360ClientError.cameraError(
                "UCD2 file list timed out (received \(receiveBuffer.count) bytes)"
            )
        }

        let files = entries.map { entry in
            let name = (entry.sourcePath as NSString).lastPathComponent
            return Insta360CameraFile(
                sourcePath: entry.sourcePath,
                downloadURL: Insta360Paths.buildDownloadURL(
                    host: hostString,
                    httpPort: Insta360Defaults.cameraHTTPPort,
                    sourcePath: entry.sourcePath
                ),
                size: entry.size,
                createdAt: BackupPathResolver.parseCreationDate(fromFilename: name),
                name: name,
                storage: Insta360Paths.storageFromPath(entry.sourcePath),
                captureTime: entry.captureTime
            )
        }

        return Insta360Paths.inferCompanionDNGFiles(
            files,
            host: hostString,
            httpPort: Insta360Defaults.cameraHTTPPort
        )
    }

    private func sendPhasedReplay() async throws {
        guard let sync = Self.loadResource("sync", ext: "bin") else {
            throw Insta360ClientError.unsupported
        }
        guard let handshake = Self.loadResource("handshake", ext: "bin") else {
            throw Insta360ClientError.unsupported
        }
        try await send(sync)
        try await Task.sleep(for: .milliseconds(50))

        for (phaseIndex, phase) in Self.handshakePhases(from: handshake).enumerated() {
            for packet in phase.packets {
                try await send(packet)
                try await Task.sleep(for: .milliseconds(20))
            }
            if phase.delayAfter > 0 {
                let waitStarted = Date()
                if phaseIndex == 0 {
                    _ = await waitForCameraCommand(0x1002, timeout: min(phase.delayAfter, 2.0))
                }
                let remaining = max(0, phase.delayAfter - Date().timeIntervalSince(waitStarted))
                if remaining > 0 {
                    try await Task.sleep(for: .seconds(remaining))
                }
            }
        }
    }

    private func waitForCameraCommand(_ command: UInt16, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.cameraCommands(in: receiveBuffer).contains(command) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func handshakePhases(from handshake: Data) -> [HandshakePhase] {
        let packets = splitUCD2Packets(handshake)
        let upperBounds: [UInt16] = [0x1002, 0x1502, 0x1802, 0x1b02, 0x1d02, 0x2a02]
        let delays: [TimeInterval] = [0.70, 0.15, 0.60, 3.00, 4.50, 0.0]
        var phases: [HandshakePhase] = []
        var remaining = packets
        for (index, bound) in upperBounds.enumerated() {
            var batch: [Data] = []
            var next: [Data] = []
            var capturing = true
            for packet in remaining {
                if capturing {
                    batch.append(packet)
                    if ucd2Command(from: packet) == bound {
                        capturing = false
                    }
                } else {
                    next.append(packet)
                }
            }
            remaining = next
            if !batch.isEmpty {
                phases.append(HandshakePhase(packets: batch, delayAfter: delays[index]))
            }
        }
        if !remaining.isEmpty {
            phases.append(HandshakePhase(packets: remaining, delayAfter: 0))
        }
        return phases
    }

    private static func countSDRaw(paths: [String]) -> (jpg: Int, dng: Int) {
        var jpg = 0
        var dng = 0
        for path in paths {
            guard Insta360Paths.storageFromPath(path) == "sd" else { continue }
            let lower = path.lowercased()
            if lower.hasSuffix(".jpg") { jpg += 1 }
            else if lower.hasSuffix(".dng") { dng += 1 }
        }
        return (jpg, dng)
    }

    private static func cameraCommands(in stream: Data) -> Set<UInt16> {
        var commands = Set<UInt16>()
        for packet in splitUCD2Packets(stream) {
            if let command = ucd2Command(from: packet) {
                commands.insert(command)
            }
        }
        return commands
    }

    private static func ucd2Command(from packet: Data) -> UInt16? {
        guard packet.count >= 16 else { return nil }
        let bytes = [UInt8](packet)
        guard bytes[0] == 0x55, bytes[1] == 0x43, bytes[2] == 0x44, bytes[3] == 0x32 else {
            return nil
        }
        guard bytes[5] == 0x0C, bytes[6] == 0x04 else { return nil }
        return UInt16(bytes[14]) | (UInt16(bytes[15]) << 8)
    }

    private struct HandshakePhase {
        var packets: [Data]
        var delayAfter: TimeInterval
    }

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
                self.handleIncoming(data)
                self.receiveBuffer.append(data)
            }
            if error != nil || isComplete || self.isClosed {
                return
            }
            self.receiveNextChunk()
        }
    }

    private func handleIncoming(_ chunk: Data) {
        var offset = 0
        let bytes = [UInt8](chunk)
        while offset + 16 <= bytes.count {
            guard bytes[offset] == 0x55, bytes[offset + 1] == 0x43,
                  bytes[offset + 2] == 0x44, bytes[offset + 3] == 0x32 else {
                break
            }
            let payloadLen = Int(bytes[offset + 8])
                | (Int(bytes[offset + 9]) << 8)
                | (Int(bytes[offset + 10]) << 16)
                | (Int(bytes[offset + 11]) << 24)
            let end = offset + 12 + payloadLen + 4
            if end > bytes.count {
                break
            }
            if bytes[offset + 5] == 0x0C, bytes[offset + 6] == 0x05, !isClosed {
                replyKeepalive(cameraSeq: bytes[offset + 7])
            }
            offset = end
        }
    }

    private func replyKeepalive(cameraSeq: UInt8) {
        let replySeq = UInt8((UInt(cameraSeq) + 4) & 0xFF)
        let templates: [UInt8: Data] = [
            0x05: Data([0x55, 0x43, 0x44, 0x32, 0x01, 0x0C, 0x05, 0x05, 0x00, 0x00, 0x00, 0x00, 0x65, 0xED, 0x78, 0xED]),
            0x1D: Data([0x55, 0x43, 0x44, 0x32, 0x01, 0x0C, 0x05, 0x1D, 0x00, 0x00, 0x00, 0x00, 0xEA, 0x6F, 0x13, 0x2A]),
            0x1E: Data([0x55, 0x43, 0x44, 0x32, 0x01, 0x0C, 0x05, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x0D, 0x3C, 0x66, 0x12]),
            0x21: Data([0x55, 0x43, 0x44, 0x32, 0x01, 0x0C, 0x05, 0x21, 0x00, 0x00, 0x00, 0x00, 0xDF, 0x38, 0xD0, 0x41]),
            0x22: Data([0x55, 0x43, 0x44, 0x32, 0x01, 0x0C, 0x05, 0x22, 0x00, 0x00, 0x00, 0x00, 0x38, 0x6B, 0xA5, 0x79]),
        ]
        let packet = templates[replySeq] ?? Data([
            0x55, 0x43, 0x44, 0x32, 0x01, 0x0C, 0x05, replySeq,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        Task { try? await self.send(packet) }
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
}
