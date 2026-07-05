import CryptoKit
import Foundation

final class WebPushService: Sendable {
    func notifyBackupPending(settings: AppSettings, pending: PendingBackup) async {
        let payload: [String: Any] = [
            "title": "Insta360 \"\(pending.cameraName)\" を検出",
            "body": "バックアップを開始しますか？",
            "pendingId": pending.id.uuidString,
            "cameraName": pending.cameraName,
            "ssid": pending.ssid,
        ]
        await send(settings: settings, payload: payload)
    }

    func notifyBackupFinished(settings: AppSettings, cameraName: String, copied: Int, skipped: Int) async {
        let payload: [String: Any] = [
            "title": "バックアップ完了: \(cameraName)",
            "body": "新規 \(copied) 件 / スキップ \(skipped) 件",
        ]
        await send(settings: settings, payload: payload)
    }

    private func send(settings: AppSettings, payload: [String: Any]) async {
        guard !settings.pushSubscriptions.isEmpty else {
            AppLogger.shared.warning("Web push skipped: no subscriptions registered", category: .push)
            return
        }
        let keys = VAPIDKeys(
            publicKeyBase64URL: settings.vapidPublicKey,
            privateKeyBase64URL: settings.vapidPrivateKey
        )

        for subscription in settings.pushSubscriptions {
            do {
                try await sendOne(subscription: subscription, keys: keys, payload: payload)
                AppLogger.shared.info(
                    "Web push delivered to \(pushEndpointLabel(subscription.endpoint))",
                    category: .push
                )
            } catch {
                AppLogger.shared.warning(
                    "Web push failed for \(pushEndpointLabel(subscription.endpoint)): \(error.localizedDescription)",
                    category: .push
                )
            }
        }
    }

    private func pushEndpointLabel(_ endpoint: String) -> String {
        guard let host = URL(string: endpoint)?.host else { return endpoint }
        return host
    }

    private func sendOne(
        subscription: PushSubscriptionRecord,
        keys: VAPIDKeys,
        payload: [String: Any]
    ) async throws {
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
        let jwt = try keys.makeJWT(audience: audience)

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = encrypted.body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("86400", forHTTPHeaderField: "TTL")
        request.setValue("vapid t=\(jwt), k=\(keys.publicKeyBase64URL)", forHTTPHeaderField: "Authorization")

        let (responseBody, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: responseBody, encoding: .utf8) ?? ""
            throw WebPushError.deliveryFailed(status, bodyText)
        }
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
        // RFC 8291: aes128gcm の padding delimiter は 0x02 必須（0x00 だと iOS が破棄する）
        let padded = Data([0x02]) + payload
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
