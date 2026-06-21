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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Insta360Sync/tls", isDirectory: true)
        let identity = try TLSConfiguration.loadOrCreateIdentity(directory: support)
        let params = TLSConfiguration.makeServerParameters(identity: identity)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPServerError.invalidPort
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                AppLogger.shared.error("HTTPS listener failed: \(error.localizedDescription)")
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        AppLogger.shared.info("HTTPS server listening on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveHTTPRequest(connection, accumulated: Data(), maxTotal: 2_000_000) { [weak self] request in
            guard let self else {
                connection.cancel()
                return
            }
            self.dispatch(connection, request: request)
        }
    }

    private func dispatch(_ connection: NWConnection, request: HTTPRequest) {
        if request.path.hasPrefix("/api") || request.method == "OPTIONS" {
            guard let core else {
                send(connection, data: HTTPResponse.text("server unavailable", status: 503))
                return
            }
            Task { @MainActor in
                let response = core.handleAPI(request)
                self.send(connection, data: response)
            }
            return
        }

        if request.method == "GET" {
            serveStatic(connection, path: request.path)
            return
        }

        send(connection, data: HTTPResponse.notFound())
    }

    private func serveStatic(_ connection: NWConnection, path: String) {
        var relative = path
        if relative == "/" { relative = "/index.html" }
        if relative.hasPrefix("/") { relative.removeFirst() }
        let fileURL = staticRoot.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            send(connection, data: HTTPResponse.data(data, contentType: mimeType(for: fileURL)))
            return
        }
        if let index = try? Data(contentsOf: staticRoot.appendingPathComponent("index.html")) {
            send(connection, data: HTTPResponse.data(index, contentType: "text/html; charset=utf-8"))
            return
        }
        send(connection, data: HTTPResponse.notFound())
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

    private func send(_ connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
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
