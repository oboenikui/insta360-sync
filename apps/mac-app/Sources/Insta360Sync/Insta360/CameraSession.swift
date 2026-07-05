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

enum RemoteFileProbeResult: Sendable {
    case available
    case notFound
    case inconclusive
}

final class FileDownloader: Sendable {
    private static let userAgent = "Lavf/60.3.100"

    func probeRemoteFile(url: URL, timeout: TimeInterval = 10) async -> RemoteFileProbeResult {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive }
            switch http.statusCode {
            case 200, 206:
                return .available
            case 404:
                return .notFound
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    static func isHTTPNotFound(_ error: Error) -> Bool {
        if case FileDownloadError.httpStatus(404) = error {
            return true
        }
        if case Insta360ClientError.cameraError(let message) = error {
            return message.hasPrefix("HTTP 404:")
        }
        return false
    }

    func download(
        file: Insta360CameraFile,
        to destinationURL: URL,
        protocolKind: CameraProtocolKind,
        overwrite: Bool = false
    ) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            if overwrite {
                try fm.removeItem(at: destinationURL)
            } else {
                return fm.fileSize(at: destinationURL) ?? 0
            }
        }

        var lastError: Error = FileDownloadError.httpFailure
        for useRange in [true, false] {
            var request = URLRequest(url: file.downloadURL, timeoutInterval: 300)
            request.httpMethod = "GET"
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("close", forHTTPHeaderField: "Connection")
            request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
            if useRange {
                request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            }

            do {
                let (tempURL, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw FileDownloadError.httpFailure
                }
                guard http.statusCode == 200 || http.statusCode == 206 else {
                    throw FileDownloadError.httpStatus(http.statusCode)
                }
                if fm.fileExists(atPath: destinationURL.path) {
                    try? fm.removeItem(at: tempURL)
                    if overwrite {
                        try fm.removeItem(at: destinationURL)
                        try fm.moveItem(at: tempURL, to: destinationURL)
                        return fm.fileSize(at: destinationURL) ?? 0
                    }
                    return fm.fileSize(at: destinationURL) ?? 0
                }
                try fm.moveItem(at: tempURL, to: destinationURL)
                return fm.fileSize(at: destinationURL) ?? 0
            } catch let error as FileDownloadError {
                switch error {
                case .httpStatus(let code) where useRange && (code == 405 || code == 416):
                    lastError = error
                    continue
                case .httpStatus(401) where protocolKind == .ucd2:
                    throw Insta360ClientError.cameraError(
                        "HTTP 401: \(file.displayName) — UCD2 セッションが切れている可能性があります。"
                    )
                case .httpStatus(404) where file.storage == "internal":
                    throw Insta360ClientError.cameraError(
                        "HTTP 404: \(file.displayName) — 本体ストレージのパスが不正な可能性があります。 (\(file.sourcePath))"
                    )
                case .httpStatus(let code):
                    throw Insta360ClientError.cameraError("HTTP \(code): \(file.displayName)")
                case .httpFailure:
                    if useRange {
                        lastError = error
                        continue
                    }
                    throw error
                }
            } catch {
                lastError = error
                if useRange {
                    continue
                }
                throw Insta360ClientError.cameraError("保存失敗 (\(file.name)): \(error.localizedDescription)")
            }
        }

        throw Insta360ClientError.cameraError(
            "ダウンロード失敗 (\(file.displayName)): \(lastError.localizedDescription)"
        )
    }
}

enum FileDownloadError: Error {
    case httpFailure
    case httpStatus(Int)
}

extension FileManager {
    func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}
