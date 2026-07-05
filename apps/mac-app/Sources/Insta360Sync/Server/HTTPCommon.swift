import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        let sep = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: sep) else { return nil }
        let headerData = data.subdata(in: data.startIndex ..< sepRange.lowerBound)
        guard let str = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = str.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let rawBody = data.subdata(in: sepRange.upperBound ..< data.endIndex)
        let body: Data
        if let contentLengthHeader = headers["content-length"],
           let contentLength = Int(contentLengthHeader) {
            body = rawBody.prefix(contentLength)
        } else {
            body = rawBody
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    static func hasCompleteMessage(_ data: Data) -> Bool {
        let sep = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: sep) else { return false }
        let bodyStartOffset = data.distance(from: data.startIndex, to: sepRange.upperBound)
        let bodyLength = data.count - bodyStartOffset
        guard let contentLengthHeader = contentLength(in: data) else {
            return true
        }
        return bodyLength >= contentLengthHeader
    }

    static func contentLength(in data: Data) -> Int? {
        let sep = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: sep) else { return nil }
        let headerData = data.subdata(in: data.startIndex ..< sepRange.lowerBound)
        guard let str = String(data: headerData, encoding: .utf8) else { return nil }
        for line in str.split(separator: "\r\n").dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            let value = line.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return nil
    }
}

enum HTTPResponse {
    static func json<T: Encodable>(_ value: T, status: Int = 200) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return response(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> Data {
        response(status: status, contentType: contentType, body: text.data(using: .utf8) ?? Data())
    }

    static func data(_ body: Data, status: Int = 200, contentType: String) -> Data {
        response(status: status, contentType: contentType, body: body)
    }

    /// 添付ファイルとしてダウンロードさせる用途。`fileName` は Content-Disposition に付与される。
    static func attachment(
        _ body: Data,
        contentType: String,
        fileName: String,
        status: Int = 200
    ) -> Data {
        let sanitized = fileName
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return response(
            status: status,
            contentType: contentType,
            body: body,
            extraHeaders: [
                ("Content-Disposition", "attachment; filename=\"\(sanitized)\""),
                ("Cache-Control", "no-store"),
            ]
        )
    }

    static func options() -> Data {
        response(status: 204, contentType: "text/plain", body: Data())
    }

    static func notFound() -> Data {
        text("not found", status: 404)
    }

    static func unauthorized() -> Data {
        text("unauthorized", status: 401)
    }

    private static func response(
        status: Int,
        contentType: String,
        body: Data,
        extraHeaders: [(String, String)] = []
    ) -> Data {
        var response = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Headers: Authorization, Content-Type\r\n"
        response += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        for (name, value) in extraHeaders {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"
        var data = response.data(using: .utf8) ?? Data()
        data.append(body)
        return data
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "OK"
        }
    }
}

func receiveHTTPRequest(
    _ connection: NWConnection,
    accumulated: Data,
    maxTotal: Int,
    completion: @escaping @Sendable (HTTPRequest) -> Void,
    onFailure: (@Sendable (String) -> Void)? = nil
) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        if let error {
            onFailure?("HTTP receive failed: \(error.localizedDescription)")
            connection.cancel()
            return
        }
        var buffer = accumulated
        if let data, !data.isEmpty {
            buffer.append(data)
        }
        if buffer.count > maxTotal {
            onFailure?("HTTP request exceeded \(maxTotal) bytes")
            connection.cancel()
            return
        }
        if HTTPRequest.hasCompleteMessage(buffer), let request = HTTPRequest.parse(buffer) {
            completion(request)
            return
        }
        if isComplete {
            if let request = HTTPRequest.parse(buffer) {
                completion(request)
                return
            }
            onFailure?("HTTP request incomplete or malformed (\(buffer.count) bytes)")
            connection.cancel()
            return
        }
        receiveHTTPRequest(
            connection,
            accumulated: buffer,
            maxTotal: maxTotal,
            completion: completion,
            onFailure: onFailure
        )
    }
}
