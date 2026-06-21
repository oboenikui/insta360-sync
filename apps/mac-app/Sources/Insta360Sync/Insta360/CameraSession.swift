import Foundation

enum CameraProtocolKind: String, Sendable {
    case ucd2
    case tcp
    case osc
}

struct CameraSession: Sendable {
    var kind: CameraProtocolKind
    private let ucd2Client: Insta360UCD2Client?
    private let tcpClient: Insta360TCPClient?
    private let oscClient: Insta360OSCClient?

    static func connect() async throws -> CameraSession {
        let ucd2 = Insta360UCD2Client()
        do {
            try await ucd2.open()
            return CameraSession(kind: .ucd2, ucd2Client: ucd2, tcpClient: nil, oscClient: nil)
        } catch {
            ucd2.close()
        }

        let tcp = Insta360TCPClient()
        do {
            try await tcp.open()
            return CameraSession(kind: .tcp, ucd2Client: nil, tcpClient: tcp, oscClient: nil)
        } catch {
            tcp.close()
        }

        let osc = Insta360OSCClient()
        guard await osc.isAvailable() else {
            throw Insta360ClientError.unsupported
        }
        return CameraSession(kind: .osc, ucd2Client: nil, tcpClient: nil, oscClient: osc)
    }

    func listAllFiles() async throws -> [Insta360CameraFile] {
        switch kind {
        case .ucd2:
            guard let ucd2Client else { throw Insta360ClientError.notConnected }
            return try await ucd2Client.listAllFiles()
        case .tcp:
            guard let tcpClient else { throw Insta360ClientError.notConnected }
            return try await tcpClient.listAllFiles()
        case .osc:
            guard let oscClient else { throw Insta360ClientError.notConnected }
            return try await oscClient.listAllFiles()
        }
    }

    func close() {
        ucd2Client?.close()
        tcpClient?.close()
    }
}

final class FileDownloader: Sendable {
    func remoteExists(at sourceURL: URL) async -> Bool {
        var request = URLRequest(url: sourceURL, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue("Lavf/60.3.100", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200 || http.statusCode == 206
        } catch {
            return false
        }
    }

    func download(from sourceURL: URL, to destinationURL: URL) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            return fm.fileSize(at: destinationURL) ?? 0
        }

        var request = URLRequest(url: sourceURL, timeoutInterval: 300)
        request.httpMethod = "GET"
        request.setValue("Lavf/60.3.100", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else {
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
