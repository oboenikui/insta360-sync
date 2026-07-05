import Foundation

extension SyncCore {
    @MainActor
    func handleAPI(_ request: HTTPRequest) -> Data {
        if request.method == "OPTIONS" {
            return HTTPResponse.options()
        }

        let path = request.path

        if request.method == "GET" && path == "/api/public/vapid" {
            return HTTPResponse.json(["vapidPublicKey": settings.vapidPublicKey])
        }

        if request.method == "GET" && path == "/api/settings" {
            guard authorize(request) else { return HTTPResponse.unauthorized() }
            let dto = PublicSettingsDTO(
                destinationRoot: settings.destinationRoot.path,
                folderStructureMode: settings.folderStructureMode.rawValue,
                vapidPublicKey: settings.vapidPublicKey,
                cameras: settings.cameras.map {
                    CameraDTO(id: $0.id, displayName: $0.displayName, ssid: $0.ssid, isEnabled: $0.isEnabled)
                }
            )
            return HTTPResponse.json(dto)
        }

        if request.method == "GET" && path == "/api/backup/pending" {
            guard authorize(request) else { return HTTPResponse.unauthorized() }
            return HTTPResponse.json(pendingStore.pendingItems())
        }

        if request.method == "GET" && path == "/api/backup/status" {
            guard authorize(request) else { return HTTPResponse.unauthorized() }
            let dto = BackupStatusDTO(
                status: appStatusLabel,
                progress: currentProgress,
                pending: pendingStore.pending,
                history: history
            )
            return HTTPResponse.json(dto)
        }

        if request.method == "POST" && path == "/api/push/subscribe" {
            guard authorize(request) else { return HTTPResponse.unauthorized() }
            do {
                let body = try JSONDecoder().decode(PushSubscribeRequest.self, from: request.body)
                registerPushSubscription(
                    PushSubscriptionRecord(
                        endpoint: body.endpoint,
                        p256dh: body.keys.p256dh,
                        auth: body.keys.auth,
                        createdAt: Date()
                    )
                )
                return HTTPResponse.json(["ok": true])
            } catch {
                AppLogger.shared.warning(
                    "Push subscribe decode failed (\(request.body.count) bytes): \(error.localizedDescription)",
                    category: .server
                )
                return HTTPResponse.text("bad json", status: 400)
            }
        }

        if request.method == "POST" && path == "/api/backup/approve" {
            guard authorize(request) else { return HTTPResponse.unauthorized() }
            guard let body = try? JSONDecoder().decode(BackupActionRequest.self, from: request.body) else {
                return HTTPResponse.text("bad json", status: 400)
            }
            Task { await approveBackup(id: body.pendingId) }
            return HTTPResponse.json(["ok": true])
        }

        if request.method == "POST" && path == "/api/backup/skip" {
            guard authorize(request) else { return HTTPResponse.unauthorized() }
            guard let body = try? JSONDecoder().decode(BackupActionRequest.self, from: request.body) else {
                return HTTPResponse.text("bad json", status: 400)
            }
            skipBackup(id: body.pendingId)
            return HTTPResponse.json(["ok": true])
        }

        return HTTPResponse.notFound()
    }

    @MainActor
    private func authorize(_ request: HTTPRequest) -> Bool {
        guard let header = request.header("authorization") else { return false }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return false }
        let token = String(header.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !token.isEmpty && token == settings.apiToken
    }
}
