import Foundation

enum CameraProtocolKind: String, Sendable {
    case tcp
    case osc
}

struct CameraSession: Sendable {
    var kind: CameraProtocolKind
    private let tcpClient: Insta360TCPClient?
    private let oscClient: Insta360OSCClient?

    static func connect() async throws -> CameraSession {
        let tcp = Insta360TCPClient()
        do {
            try await tcp.open()
            return CameraSession(kind: .tcp, tcpClient: tcp, oscClient: nil)
        } catch {
            tcp.close()
        }

        let osc = Insta360OSCClient()
        guard await osc.isAvailable() else {
            throw Insta360ClientError.unsupported
        }
        return CameraSession(kind: .osc, tcpClient: nil, oscClient: osc)
    }

    func listAllFiles() async throws -> [Insta360CameraFile] {
        switch kind {
        case .tcp:
            guard let tcpClient else { throw Insta360ClientError.notConnected }
            return try await tcpClient.listAllFiles()
        case .osc:
            guard let oscClient else { throw Insta360ClientError.notConnected }
            return try await oscClient.listAllFiles()
        }
    }

    func close() {
        tcpClient?.close()
    }
}

final class FileDownloader: Sendable {
    func download(from sourceURL: URL, to destinationURL: URL) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            return fm.fileSize(at: destinationURL) ?? 0
        }

        var request = URLRequest(url: sourceURL, timeoutInterval: 300)
        request.httpMethod = "GET"
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw FileDownloadError.httpFailure
        }
        if fm.fileExists(atPath: destinationURL.path) {
            try? fm.removeItem(at: tempURL)
            return fm.fileSize(at: destinationURL) ?? 0
        }
        try fm.moveItem(at: tempURL, to: destinationURL)
        return fm.fileSize(at: destinationURL) ?? 0
    }
}

enum FileDownloadError: Error {
    case httpFailure
}

extension FileManager {
    func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}
