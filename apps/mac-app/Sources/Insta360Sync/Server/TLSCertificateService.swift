import CryptoKit
import Foundation
import Security

/// PWA / モバイル端末に配布するための TLS 証明書アクセサ。
///
/// TLS サーバーで使っている自己署名証明書 (server.crt) をそのまま
/// ルート証明書として iOS / Android にインストールしてもらう想定。
enum TLSCertificateService {
    struct Info: Encodable {
        var commonName: String
        var dnsNames: [String]
        var ipAddresses: [String]
        var notBefore: Date?
        var notAfter: Date?
        var sha256Fingerprint: String
        var sha1Fingerprint: String
        var serialNumber: String?
        var downloadBaseName: String
        var pem: String
    }

    /// PEM 形式（テキスト）のサーバー証明書。
    static func pemData() throws -> Data {
        try Data(contentsOf: TLSConfiguration.certificatePEMURL)
    }

    /// DER 形式（バイナリ）のサーバー証明書。
    static func derData() throws -> Data {
        let pem = try String(contentsOf: TLSConfiguration.certificatePEMURL, encoding: .utf8)
        return try derData(fromPEM: pem)
    }

    /// iOS 向けの構成プロファイル (.mobileconfig)。
    /// ルート証明書ペイロード (com.apple.security.root) 1 件だけを含む。
    static func mobileConfigData() throws -> Data {
        let der = try derData()
        let endpoints = TLSConfiguration.loadStoredEndpoints() ?? TLSCertificateEndpoints.current()

        let certUUID = deterministicUUIDString(seed: der, salt: "cert")
        let profileUUID = deterministicUUIDString(seed: der, salt: "profile")

        let identifierBase = "local.insta360sync"
        let displayName = "Insta360 Sync 証明書 (\(endpoints.commonName))"
        let description = "Insta360 Sync が使用している自己署名ルート証明書。インストール後に信頼設定を有効化してください。"

        let certificatePayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifierBase).certificate.\(endpoints.commonName)",
            "PayloadUUID": certUUID,
            "PayloadDisplayName": displayName,
            "PayloadDescription": description,
            "PayloadCertificateFileName": "insta360-sync-root.crt",
            "PayloadContent": der,
        ]

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifierBase).profile.\(endpoints.commonName)",
            "PayloadUUID": profileUUID,
            "PayloadDisplayName": displayName,
            "PayloadDescription": description,
            "PayloadOrganization": "Insta360 Sync",
            "PayloadContent": [certificatePayload],
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .xml,
            options: 0
        )
    }

    /// 証明書のメタ情報 (フィンガープリント・有効期限・SAN 等)。
    static func makeInfo() throws -> Info {
        let der = try derData()
        let pem = try String(contentsOf: TLSConfiguration.certificatePEMURL, encoding: .utf8)
        let endpoints = TLSConfiguration.loadStoredEndpoints() ?? TLSCertificateEndpoints.current()

        var notBefore: Date?
        var notAfter: Date?
        var serialNumber: String?

        if let cert = SecCertificateCreateWithData(nil, der as CFData) {
            let valueKey = kSecPropertyKeyValue as String
            let queryKeys = [
                kSecOIDX509V1ValidityNotBefore as String,
                kSecOIDX509V1ValidityNotAfter as String,
            ] as CFArray
            if let dict = SecCertificateCopyValues(cert, queryKeys, nil) as? [String: Any] {
                if let entry = dict[kSecOIDX509V1ValidityNotBefore as String] as? [String: Any],
                   let value = entry[valueKey] as? Double {
                    notBefore = Date(timeIntervalSinceReferenceDate: value)
                }
                if let entry = dict[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
                   let value = entry[valueKey] as? Double {
                    notAfter = Date(timeIntervalSinceReferenceDate: value)
                }
            }
            if let data = SecCertificateCopySerialNumberData(cert, nil) as Data? {
                serialNumber = hexColonSeparated(data)
            }
        }

        let sha256 = hexColonSeparated(Data(SHA256.hash(data: der)))
        let sha1 = hexColonSeparated(Data(Insecure.SHA1.hash(data: der)))

        let hostSlug = endpoints.commonName
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        return Info(
            commonName: endpoints.commonName,
            dnsNames: endpoints.dnsNames,
            ipAddresses: endpoints.ipAddresses,
            notBefore: notBefore,
            notAfter: notAfter,
            sha256Fingerprint: sha256,
            sha1Fingerprint: sha1,
            serialNumber: serialNumber,
            downloadBaseName: "insta360-sync-\(hostSlug)",
            pem: pem
        )
    }

    private static func derData(fromPEM pem: String) throws -> Data {
        let base64 = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: base64) else {
            throw TLSCertificateServiceError.invalidPEM
        }
        return data
    }

    private static func hexColonSeparated(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// 同じ証明書からは同じ UUID を導出することで、iOS 上で既存プロファイルの再インストールとして扱われるようにする。
    private static func deterministicUUIDString(seed: Data, salt: String) -> String {
        var hasher = SHA256()
        hasher.update(data: seed)
        hasher.update(data: Data(salt.utf8))
        let digest = hasher.finalize()
        var bytes = Array(digest.prefix(16))
        // RFC 4122 準拠 (version=4, variant=RFC4122) の見た目に整える。
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        func slice(_ start: Int, _ end: Int) -> String {
            let a = hex.index(hex.startIndex, offsetBy: start)
            let b = hex.index(hex.startIndex, offsetBy: end)
            return String(hex[a ..< b])
        }
        return slice(0, 8) + "-"
            + slice(8, 12) + "-"
            + slice(12, 16) + "-"
            + slice(16, 20) + "-"
            + slice(20, 32)
    }
}

enum TLSCertificateServiceError: LocalizedError {
    case invalidPEM

    var errorDescription: String? {
        switch self {
        case .invalidPEM: "TLS 証明書 PEM の解析に失敗しました"
        }
    }
}
