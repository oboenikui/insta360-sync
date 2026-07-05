import Foundation
import Network

final class HTTPServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private weak var core: SyncCore?
    private let staticRoot: URL

    init(port: UInt16, staticRoot: URL, core: SyncCore) {
        self.port = port
        self.staticRoot = staticRoot
        self.core = core
    }

    func start() throws {
        guard listener == nil else { return }
        let identity = try TLSConfiguration.loadOrCreateIdentity(directory: TLSConfiguration.storageDirectory)
        let params = TLSConfiguration.makeServerParameters(identity: identity)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPServerError.invalidPort
        }
        let listener = try NWListener(using: params, on: nwPort)
        let listenPort = port
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                AppLogger.shared.error(
                    "HTTPS listener failed: \(error.localizedDescription)",
                    category: .server
                )
            case .ready:
                AppLogger.shared.info("HTTPS listener ready on port \(listenPort)", category: .server)
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        AppLogger.shared.info("HTTPS server listening on port \(port)", category: .server)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        AppLogger.shared.info("HTTPS server stopped", category: .server)
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                self.beginReceiving(connection)
            case .failed(let error):
                self.logConnectionFailure(error)
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func beginReceiving(_ connection: NWConnection) {
        receiveHTTPRequest(connection, accumulated: Data(), maxTotal: 2_000_000) { [weak self] request in
            guard let self else {
                connection.cancel()
                return
            }
            self.dispatch(connection, request: request)
        } onFailure: { message in
            if Self.isTLSHandshakeFailure(message) {
                AppLogger.shared.debug(message, category: .server)
            } else {
                AppLogger.shared.warning(message, category: .server)
            }
        }
    }

    private func logConnectionFailure(_ error: NWError) {
        let message = error.localizedDescription
        if Self.isTLSHandshakeFailure(message) {
            AppLogger.shared.debug("HTTPS TLS handshake failed: \(message)", category: .server)
        } else {
            AppLogger.shared.warning("HTTPS connection failed: \(message)", category: .server)
        }
    }

    private static func isTLSHandshakeFailure(_ message: String) -> Bool {
        message.contains("9825") || message.localizedCaseInsensitiveContains("bad certificate")
    }

    private func dispatch(_ connection: NWConnection, request: HTTPRequest) {
        if request.path.hasPrefix("/api") || request.method == "OPTIONS" {
            guard let core else {
                send(connection, request: request, data: HTTPResponse.text("server unavailable", status: 503))
                return
            }
            Task { @MainActor in
                let response = core.handleAPI(request)
                self.send(connection, request: request, data: response)
            }
            return
        }

        if request.method == "GET" {
            serveStatic(connection, request: request, path: request.path)
            return
        }

        send(connection, request: request, data: HTTPResponse.notFound())
    }

    private func serveStatic(_ connection: NWConnection, request: HTTPRequest, path: String) {
        var relative = path
        if relative == "/" { relative = "/index.html" }
        if relative.hasPrefix("/") { relative.removeFirst() }
        let fileURL = staticRoot.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            send(connection, request: request, data: HTTPResponse.data(data, contentType: mimeType(for: fileURL)))
            return
        }
        if let index = try? Data(contentsOf: staticRoot.appendingPathComponent("index.html")) {
            send(connection, request: request, data: HTTPResponse.data(index, contentType: "text/html; charset=utf-8"))
            return
        }
        send(connection, request: request, data: HTTPResponse.notFound())
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js": "application/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        case "webmanifest": "application/manifest+json"
        default: "application/octet-stream"
        }
    }

    private func send(_ connection: NWConnection, request: HTTPRequest, data: Data) {
        let status = Self.parseStatusCode(data)
        let remote = Self.remoteEndpointDescription(connection)
        AppLogger.shared.info(
            "\(request.method) \(request.path) \(status) from \(remote)",
            category: .server
        )
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseStatusCode(_ response: Data) -> Int {
        guard let firstLine = String(data: response.prefix(128), encoding: .utf8)?
            .split(separator: "\r\n", maxSplits: 1).first
        else { return 0 }
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return 0 }
        return Int(parts[1]) ?? 0
    }

    private static func remoteEndpointDescription(_ connection: NWConnection) -> String {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return "-" }
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(hostString(host)):\(port.rawValue)"
        default:
            return "\(endpoint)"
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            return "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}

enum HTTPServerError: Error {
    case invalidPort
}

struct PublicSettingsDTO: Encodable {
    var destinationRoot: String
    var folderStructureMode: String
    var vapidPublicKey: String
    var cameras: [CameraDTO]
}

struct CameraDTO: Encodable {
    var id: UUID
    var displayName: String
    var ssid: String
    var isEnabled: Bool
}

struct PushSubscribeRequest: Decodable {
    var endpoint: String
    var keys: Keys

    struct Keys: Decodable {
        var p256dh: String
        var auth: String
    }
}

struct BackupActionRequest: Decodable {
    var pendingId: UUID
}

struct BackupStatusDTO: Encodable {
    var status: String
    var progress: BackupProgress?
    var pending: [PendingBackup]
    var history: [BackupHistoryEntry]
}
