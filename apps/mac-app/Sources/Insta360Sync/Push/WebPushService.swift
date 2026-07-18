import CryptoKit
import Foundation

struct PushGatewayResponse: Sendable {
    var statusCode: Int
    var responseBody: String
    var responseHeaders: [String: String]
    var payloadBytes: Int

    var apnsID: String? {
        responseHeaders.first { $0.key.lowercased() == "apns-id" }?.value
    }

    var reason: String? {
        PushHTTPResponseParser.reason(from: responseBody)
    }
}

struct PushDeliveryResult: Sendable {
    var endpoint: String
    var endpointHost: String
    var ok: Bool
    var statusCode: Int?
    var error: String?
    var apnsID: String?
    var reason: String?
    var responseBody: String?
    var responseHeaders: [String: String]
    var payloadBytes: Int?

    var endpointSuffix: String { String(endpoint.suffix(24)) }
    var isExpired: Bool { statusCode == 410 }
}

final class WebPushService: Sendable {
    func notifyBackupPending(settings: AppSettings, pending: PendingBackup) async -> [PushDeliveryResult] {
        let payload: [String: Any] = [
            "title": "Insta360 \"\(pending.cameraName)\" を検出",
            "body": "バックアップを開始しますか？",
            "pendingId": pending.id.uuidString,
            "cameraName": pending.cameraName,
            "ssid": pending.ssid,
        ]
        return await sendWithResults(settings: settings, payload: payload)
    }

    func notifyBackupFinished(settings: AppSettings, cameraName: String, copied: Int, skipped: Int) async -> [PushDeliveryResult] {
        let payload: [String: Any] = [
            "title": "バックアップ完了: \(cameraName)",
            "body": "新規 \(copied) 件 / スキップ \(skipped) 件",
        ]
        return await sendWithResults(settings: settings, payload: payload)
    }

    func sendTest(settings: AppSettings, subscriptions: [PushSubscriptionRecord]? = nil) async -> [PushDeliveryResult] {
        let payload: [String: Any] = [
            "title": "Insta360 Sync テスト",
            "body": "Push 通知のテストです",
            "pendingId": "",
        ]
        return await sendWithResults(settings: settings, payload: payload, subscriptions: subscriptions)
    }

    func sendWithResults(
        settings: AppSettings,
        payload: [String: Any],
        subscriptions: [PushSubscriptionRecord]? = nil
    ) async -> [PushDeliveryResult] {
        if VAPIDKeys.isProblematicSubjectForApple(settings.vapidSubject) {
            AppLogger.shared.warning(
                "VAPID subject may be rejected by Apple: \(settings.vapidSubject)",
                category: .push
            )
        }
        let targets = subscriptions ?? settings.pushSubscriptions
        guard !targets.isEmpty else {
            AppLogger.shared.warning("Web push skipped: no subscriptions registered", category: .push)
            return []
        }
        let keys = VAPIDKeys(
            publicKeyBase64URL: settings.vapidPublicKey,
            privateKeyBase64URL: settings.vapidPrivateKey
        )

        var results: [PushDeliveryResult] = []
        for subscription in targets {
            let host = subscription.endpointHost
            do {
                let gateway = try await sendOne(
                    subscription: subscription,
                    keys: keys,
                    payload: payload,
                    vapidSubject: settings.vapidSubject
                )
                let detail = PushHTTPResponseParser.summary(for: gateway)
                AppLogger.shared.info(
                    "Web push delivered to \(host) …\(subscription.endpointSuffix) \(detail)",
                    category: .push
                )
                results.append(
                    PushDeliveryResult(
                        endpoint: subscription.endpoint,
                        endpointHost: host,
                        ok: true,
                        statusCode: gateway.statusCode,
                        error: nil,
                        apnsID: gateway.apnsID,
                        reason: gateway.reason,
                        responseBody: gateway.responseBody.isEmpty ? nil : gateway.responseBody,
                        responseHeaders: gateway.responseHeaders,
                        payloadBytes: gateway.payloadBytes
                    )
                )
            } catch {
                let status = (error as? WebPushError)?.httpStatusCode
                let gateway = (error as? WebPushError)?.gatewayResponse
                AppLogger.shared.warning(
                    "Web push failed for \(host) …\(subscription.endpointSuffix): \(error.localizedDescription)",
                    category: .push
                )
                results.append(
                    PushDeliveryResult(
                        endpoint: subscription.endpoint,
                        endpointHost: host,
                        ok: false,
                        statusCode: status,
                        error: error.localizedDescription,
                        apnsID: gateway?.apnsID,
                        reason: gateway?.reason,
                        responseBody: gateway?.responseBody,
                        responseHeaders: gateway?.responseHeaders ?? [:],
                        payloadBytes: gateway?.payloadBytes
                    )
                )
            }
        }
        return results
    }

    private func send(settings: AppSettings, payload: [String: Any]) async {
        _ = await sendWithResults(settings: settings, payload: payload)
    }

    private func sendOne(
        subscription: PushSubscriptionRecord,
        keys: VAPIDKeys,
        payload: [String: Any],
        vapidSubject: String
    ) async throws -> PushGatewayResponse {
        guard let endpoint = URL(string: subscription.endpoint),
              let recipientPublicKey = Base64URL.decode(subscription.p256dh),
              let authSecret = Base64URL.decode(subscription.auth) else {
            throw WebPushError.invalidSubscription
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let encrypted = try WebPushEncryption.encrypt(
            payload: payloadData,
            recipientPublicKey: recipientPublicKey,
            authSecret: authSecret
        )

        let audience = endpoint.host.map { "https://\($0)" } ?? endpoint.absoluteString
        let jwt = try keys.makeJWT(audience: audience, subject: vapidSubject)

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = encrypted.body
        request.httpMethod = "POST"
        request.httpBody = encrypted.body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("86400", forHTTPHeaderField: "TTL")
        // Apple: 即時配信を試みるには high。未指定だと端末側で遅延・破棄されやすい。
        request.setValue("high", forHTTPHeaderField: "Urgency")
        request.setValue("vapid t=\(jwt), k=\(keys.publicKeyBase64URL)", forHTTPHeaderField: "Authorization")

        let (responseBody, response) = try await URLSession.shared.data(for: request)
        let bodyText = String(data: responseBody, encoding: .utf8) ?? ""
        let headers = PushHTTPResponseParser.interestingHeaders(from: response)
        let payloadBytes = encrypted.body.count

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let gateway = PushGatewayResponse(
                statusCode: status,
                responseBody: bodyText,
                responseHeaders: headers,
                payloadBytes: payloadBytes
            )
            throw WebPushError.deliveryFailed(gateway)
        }

        return PushGatewayResponse(
            statusCode: http.statusCode,
            responseBody: bodyText,
            responseHeaders: headers,
            payloadBytes: payloadBytes
        )
    }
}

enum PushHTTPResponseParser {
    static func interestingHeaders(from response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            let lower = key.lowercased()
            if lower.hasPrefix("apns") || lower == "content-type" || lower == "retry-after" {
                result[key] = value
            }
        }
        return result
    }

    static func reason(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = json["reason"] as? String else {
            return nil
        }
        return reason
    }

    static func summary(for gateway: PushGatewayResponse) -> String {
        var parts = ["HTTP \(gateway.statusCode)", "payload \(gateway.payloadBytes)B"]
        if let apnsID = gateway.apnsID {
            parts.append("apns-id \(apnsID)")
        }
        if let reason = gateway.reason {
            parts.append("reason \(reason)")
        } else if !gateway.responseBody.isEmpty {
            parts.append("body \(gateway.responseBody)")
        }
        for (key, value) in gateway.responseHeaders.sorted(by: { $0.key < $1.key })
            where key.lowercased() != "apns-id" {
            parts.append("\(key) \(value)")
        }
        return parts.joined(separator: ", ")
    }
}

private enum WebPushEncryption {
    struct Result {
        var body: Data
    }

    static func encrypt(payload: Data, recipientPublicKey: Data, authSecret: Data) throws -> Result {
        let localPrivate = P256.KeyAgreement.PrivateKey()
        let localPublic = localPrivate.publicKey.x963Representation
        guard recipientPublicKey.count == 65 else { throw WebPushError.invalidSubscription }

        let remotePublic = try P256.KeyAgreement.PublicKey(x963Representation: recipientPublicKey)
        let sharedSecret = try localPrivate.sharedSecretFromKeyAgreement(with: remotePublic)

        let salt = randomData(count: 16)
        let keyInfo = Data("WebPush: info\0".utf8) + recipientPublicKey + localPublic
        let ikm = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: authSecret,
            sharedInfo: keyInfo,
            outputByteCount: 32
        )

        let contentKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("Content-Encoding: aes128gcm\0".utf8),
            outputByteCount: 16
        )
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("Content-Encoding: nonce\0".utf8),
            outputByteCount: 12
        )
        let nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })
        // RFC 8188 / RFC 8291: plaintext = content || 0x02 || 0x00*
        // WebKit は末尾から 0x02 を探す。先頭に付けると復号後に破棄され push イベントが発火しない。
        let padded = payload + Data([0x02])
        let sealed = try AES.GCM.seal(padded, using: contentKey, nonce: nonce)
        let ciphertext = sealed.ciphertext
        let tag = sealed.tag

        var body = Data()
        body.append(salt)
        var recordSize = UInt32(4096).bigEndian
        body.append(Data(bytes: &recordSize, count: 4))
        body.append(UInt8(localPublic.count))
        body.append(localPublic)
        body.append(ciphertext)
        body.append(tag)

        return Result(body: body)
    }

    private static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

import Security
