import Foundation
import Network
import os

enum Insta360Protocol {
    static let pktSync = Data([0x06, 0x00, 0x00]) + Data("syNceNdinS".utf8)
    static let pktKeepAlive = Data([0x05, 0x00, 0x00])

    static let phoneCommandSetOptions: UInt16 = 7
    static let phoneCommandGetFileList: UInt16 = 13

    static let responseCodeOK: UInt16 = 200
    static let responseCodeError: UInt16 = 500

    static func makeCommandPacket(messageCode: UInt16, sequence: Int32, body: Data) -> Data {
        var header = Data([0x04, 0x00, 0x00])
        header.append(contentsOf: withUnsafeBytes(of: messageCode.littleEndian) { Data($0) })
        header.append(0x02)
        var seq = sequence
        header.append(contentsOf: withUnsafeBytes(of: &seq) { Data($0) }.prefix(3))
        header.append(contentsOf: [0x80, 0x00, 0x00])
        let payload = header + body
        var length = UInt32(payload.count + 4).littleEndian
        return Data(bytes: &length, count: 4) + payload
    }
}

struct Insta360CameraFile: Sendable {
    var sourcePath: String
    var downloadURL: URL
    var size: Int64?
    var createdAt: Date?
    var name: String
    var storage: String
    var captureTime: Int64?
    var isSynced: Bool

    init(
        sourcePath: String,
        downloadURL: URL,
        size: Int64? = nil,
        createdAt: Date? = nil,
        name: String = "",
        storage: String = "sd",
        captureTime: Int64? = nil,
        isSynced: Bool = false
    ) {
        self.sourcePath = sourcePath
        self.downloadURL = downloadURL
        self.size = size
        self.createdAt = createdAt
        self.name = name.isEmpty ? (sourcePath as NSString).lastPathComponent : name
        if storage == "sd", sourcePath.hasPrefix("/storage_") {
            self.storage = Insta360Paths.storageFromPath(sourcePath)
        } else {
            self.storage = storage
        }
        self.captureTime = captureTime ?? Insta360MediaProto.captureTimeFromFilename(self.name)
        self.isSynced = isSynced
    }

    var displayName: String {
        let prefix = isSynced ? "[済] " : ""
        return "\(prefix)[\(Insta360Paths.displayLabel(storage: storage))] \(name)"
    }
}

final class Insta360TCPClient: @unchecked Sendable {
    private struct State {
        var sequence: Int32 = 0
        var pendingResponses: [Int32: CheckedContinuation<Data, Error>] = [:]
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "insta360.tcp")
    private var receiveBuffer = Data()
    private let state = OSAllocatedUnfairLock(initialState: State())

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
        try await sendRaw(Insta360Protocol.pktSync)
        try await sendRaw(Insta360Protocol.pktKeepAlive)
    }

    func close() {
        connection?.cancel()
        connection = nil
        let waiters = state.withLock { state -> [CheckedContinuation<Data, Error>] in
            let waiters = Array(state.pendingResponses.values)
            state.pendingResponses.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    func listAllFiles() async throws -> [Insta360CameraFile] {
        var allURIs: [String] = []
        var start: UInt32 = 0
        let limit: UInt32 = 500
        var totalCount: UInt32?

        repeat {
            let request = Insta360Proto.GetFileListRequest(start: start, limit: limit)
            let body = Insta360Proto.encodeGetFileList(request)
            let responseBody = try await sendCommand(code: Insta360Protocol.phoneCommandGetFileList, body: body)
            let parsed = try Insta360Proto.decodeGetFileListResponse(responseBody)
            if totalCount == nil { totalCount = parsed.totalCount }
            allURIs.append(contentsOf: parsed.uris)
            if parsed.uris.isEmpty { break }
            start += UInt32(parsed.uris.count)
            if let totalCount, start >= totalCount { break }
        } while true

        return allURIs.map { uri in
            let name = (uri as NSString).lastPathComponent
            return Insta360CameraFile(
                sourcePath: uri,
                downloadURL: Insta360Paths.buildDownloadURL(
                    host: Insta360Defaults.cameraHost,
                    httpPort: Insta360Defaults.cameraHTTPPort,
                    sourcePath: uri
                ),
                size: nil,
                createdAt: BackupPathResolver.parseCreationDate(fromFilename: name),
                name: name,
                storage: Insta360Paths.storageFromPath(uri)
            )
        }
    }

    private func sendCommand(code: UInt16, body: Data) async throws -> Data {
        let seq = state.withLock { state -> Int32 in
            let current = state.sequence
            state.sequence += 1
            return current
        }
        let packet = Insta360Protocol.makeCommandPacket(messageCode: code, sequence: seq, body: body)
        try await sendRaw(packet)
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.pendingResponses[seq] = continuation
            }
        }
    }

    private func sendRaw(_ payload: Data) async throws {
        guard let connection else { throw Insta360ClientError.notConnected }
        var framed = Data()
        var length = UInt32(payload.count + 4).littleEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
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
            if let error {
                AppLogger.shared.error("TCP receive error: \(error.localizedDescription)")
                return
            }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processBuffer()
            }
            if isComplete {
                self.close()
            } else {
                self.receiveNextChunk()
            }
        }
    }

    private func processBuffer() {
        while receiveBuffer.count >= 4 {
            let packetLength = Int(receiveBuffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) })
            guard packetLength >= 4, receiveBuffer.count >= packetLength else { break }
            let packet = receiveBuffer.subdata(in: 4 ..< packetLength)
            receiveBuffer.removeSubrange(0 ..< packetLength)
            handlePacket(packet)
        }
    }

    private func handlePacket(_ packet: Data) {
        if packet == Insta360Protocol.pktSync || packet == Insta360Protocol.pktKeepAlive {
            return
        }
        guard packet.count >= 12 else { return }
        let responseCode = packet.subdata(in: 3 ..< 5).withUnsafeBytes { $0.load(as: UInt16.self) }
        let seqBytes = packet.subdata(in: 6 ..< 9)
        var seqValue: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &seqValue) { dest in
            seqBytes.copyBytes(to: dest)
        }
        let seq = Int32(seqValue)
        let body = packet.subdata(in: 12 ..< packet.count)

        if responseCode == Insta360Protocol.responseCodeError {
            let waiter = state.withLock { state in
                state.pendingResponses.removeValue(forKey: seq)
            }
            waiter?.resume(throwing: Insta360ClientError.cameraError(String(data: body, encoding: .utf8) ?? "unknown"))
            return
        }

        if responseCode == Insta360Protocol.responseCodeOK {
            let waiter = state.withLock { state in
                state.pendingResponses.removeValue(forKey: seq)
            }
            waiter?.resume(returning: body)
        }
    }
}

enum Insta360ClientError: LocalizedError {
    case notConnected
    case cameraError(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notConnected: "Camera TCP connection is not open"
        case .cameraError(let message): "Camera error: \(message)"
        case .unsupported: "Camera protocol unsupported"
        }
    }
}
