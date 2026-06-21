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
        let body = data.subdata(in: sepRange.upperBound ..< data.endIndex)
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
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

    static func options() -> Data {
        response(status: 204, contentType: "text/plain", body: Data())
    }

    static func notFound() -> Data {
        text("not found", status: 404)
    }

    static func unauthorized() -> Data {
        text("unauthorized", status: 401)
    }

    private static func response(status: Int, contentType: String, body: Data) -> Data {
        var response = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Headers: Authorization, Content-Type\r\n"
        response += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
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
    completion: @escaping @Sendable (HTTPRequest) -> Void
) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        if error != nil {
            connection.cancel()
            return
        }
        var buffer = accumulated
        if let data, !data.isEmpty {
            buffer.append(data)
        }
        if buffer.count > maxTotal {
            connection.cancel()
            return
        }
        if let request = HTTPRequest.parse(buffer) {
            completion(request)
            return
        }
        if isComplete {
            connection.cancel()
            return
        }
        receiveHTTPRequest(connection, accumulated: buffer, maxTotal: maxTotal, completion: completion)
    }
}
