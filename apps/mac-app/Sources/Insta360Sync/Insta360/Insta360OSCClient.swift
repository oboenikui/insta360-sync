import Foundation

final class Insta360OSCClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(host: String = Insta360Defaults.cameraHost) {
        self.baseURL = URL(string: "http://\(host)")!
        self.session = URLSession(configuration: .default)
    }

    func isAvailable() async -> Bool {
        let url = baseURL.appendingPathComponent("osc/info")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func listAllFiles() async throws -> [Insta360CameraFile] {
        var files: [Insta360CameraFile] = []
        var startPosition = 0
        let pageSize = 50
        var totalEntries: Int?

        repeat {
            let command: [String: Any] = [
                "name": "camera.listFiles",
                "parameters": [
                    "fileType": "all",
                    "startPosition": startPosition,
                    "entryCount": pageSize,
                    "maxThumbSize": 0,
                ],
            ]
            let result = try await executeCommand(command)
            guard let results = result["results"] as? [String: Any] else { break }
            if totalEntries == nil {
                totalEntries = results["totalEntries"] as? Int
            }
            guard let entries = results["entries"] as? [[String: Any]] else { break }
            for entry in entries {
                let name = entry["name"] as? String ?? "unknown"
                let localPath = entry["_localFileUrl"] as? String
                    ?? entry["fileUrl"] as? String
                    ?? "/DCIM/Camera01/\(name)"
                let fileURLString = entry["fileUrl"] as? String
                    ?? "http://\(Insta360Defaults.cameraHost):\(Insta360Defaults.cameraHTTPPort)\(localPath)"
                guard let downloadURL = URL(string: fileURLString) else { continue }
                let size = (entry["size"] as? NSNumber)?.int64Value
                let createdAt = parseOSCTimestamp(entry["dateTimeZone"] as? String)
                    ?? BackupPathResolver.parseCreationDate(fromFilename: name)
                files.append(
                    Insta360CameraFile(
                        sourcePath: localPath.hasPrefix("/") ? localPath : "/\(localPath)",
                        downloadURL: downloadURL,
                        size: size,
                        createdAt: createdAt
                    )
                )
            }
            if entries.isEmpty { break }
            startPosition += entries.count
            if let totalEntries, startPosition >= totalEntries { break }
        } while true

        return files
    }

    private func executeCommand(_ command: [String: Any]) async throws -> [String: Any] {
        let commandURL = baseURL.appendingPathComponent("osc/commands/execute")
        var request = URLRequest(url: commandURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: command)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw Insta360ClientError.cameraError("OSC execute failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Insta360ClientError.cameraError("Invalid OSC response")
        }

        if let state = json["state"] as? String, state == "inProgress" {
            guard let id = json["id"] as? String else {
                throw Insta360ClientError.cameraError("Missing OSC command id")
            }
            return try await pollStatus(id: id)
        }
        return json
    }

    private func pollStatus(id: String) async throws -> [String: Any] {
        let statusURL = baseURL.appendingPathComponent("osc/commands/status")
        for _ in 0 ..< 30 {
            var request = URLRequest(url: statusURL, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id])
            let (data, _) = try await session.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = json["state"] as? String {
                if state == "done" { return json }
                if state == "error" {
                    throw Insta360ClientError.cameraError(json["error"] as? String ?? "OSC command failed")
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw Insta360ClientError.cameraError("OSC command timed out")
    }

    private func parseOSCTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZ"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZ"
        return formatter.date(from: value.replacingOccurrences(of: "+", with: "+").replacingOccurrences(of: " ", with: " "))
    }
}
