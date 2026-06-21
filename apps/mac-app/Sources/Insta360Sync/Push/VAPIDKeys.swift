import CryptoKit
import Foundation
import Security

struct VAPIDKeys: Sendable {
    var publicKeyBase64URL: String
    var privateKeyBase64URL: String

    static func generate() -> VAPIDKeys {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let publicRaw = publicKey.x963Representation
        let privateRaw = privateKey.rawRepresentation
        return VAPIDKeys(
            publicKeyBase64URL: Base64URL.encode(publicRaw),
            privateKeyBase64URL: Base64URL.encode(privateRaw)
        )
    }

    func makeJWT(audience: String, subject: String = "mailto:support@insta360-sync.local") throws -> String {
        guard let privateKeyData = Base64URL.decode(privateKeyBase64URL) else {
            throw WebPushError.invalidKeys
        }
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let header = ["alg": "ES256", "typ": "JWT"]
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "aud": audience,
            "exp": now + 12 * 3600,
            "sub": subject,
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let signingInput = Base64URL.encode(headerData) + "." + Base64URL.encode(payloadData)
        let signature = try signingKey.signature(for: Data(signingInput.utf8))
        let rawSignature = signature.rawRepresentation
        let sig = Base64URL.encode(rawSignature)
        return signingInput + "." + sig
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 { base64 += String(repeating: "=", count: padding) }
        return Data(base64Encoded: base64)
    }
}

enum WebPushError: LocalizedError {
    case invalidKeys
    case invalidSubscription
    case deliveryFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKeys: "Invalid VAPID keys"
        case .invalidSubscription: "Invalid push subscription"
        case .deliveryFailed(let code): "Push delivery failed with status \(code)"
        }
    }
}
