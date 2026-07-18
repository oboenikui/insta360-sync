import CryptoKit
import Foundation
import Security

/// PWA / モバイル端末に配布するための TLS 証明書アクセサ。
///
/// 自己署名時は server.crt をルートとして配布する。
/// Let's Encrypt 等のカスタム証明書時はリーフ（+ チェーン）のメタ情報のみ返し、
/// mobileconfig（ルート信頼用）は提供しない。
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
        /// カスタム（公開 CA）証明書を使用中か。true のとき端末へのルートインストールは不要。
        var isCustomCertificate: Bool
        /// ルート証明書のインストールが推奨されるか（自己署名のみ true）。
        var installRecommended: Bool
    }

    /// 使用中の証明書 PEM の URL（カスタム path または自己署名 server.crt）。
    static func activeCertificatePEMURL(customPath: String?) -> URL {
        let trimmed = customPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed)
        }
        return TLSConfiguration.certificatePEMURL
    }

    /// PEM 形式（テキスト）のサーバー証明書（fullchain の場合はそのまま）。
    static func pemData(customPath: String? = nil) throws -> Data {
        let url = activeCertificatePEMURL(customPath: customPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw TLSCertificateServiceError.fileUnreadable(url.path)
        }
        return try Data(contentsOf: url)
    }

    /// DER 形式（バイナリ）のリーフ証明書。
    static func derData(customPath: String? = nil) throws -> Data {
        let pem = try String(contentsOf: activeCertificatePEMURL(customPath: customPath), encoding: .utf8)
        return try leafDERData(fromPEM: pem)
    }

    /// iOS 向けの構成プロファイル (.mobileconfig)。自己署名ルートのみ。
    static func mobileConfigData(customPath: String? = nil) throws -> Data {
        let trimmed = customPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            throw TLSCertificateServiceError.mobileConfigNotApplicable
        }

        let der = try derData(customPath: nil)
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
    static func makeInfo(customPath: String? = nil) throws -> Info {
        let isCustom = !(customPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let pemURL = activeCertificatePEMURL(customPath: customPath)
        let pem = try String(contentsOf: pemURL, encoding: .utf8)
        let der = try leafDERData(fromPEM: pem)

        var notBefore: Date?
        var notAfter: Date?
        var serialNumber: String?
        var commonName = "unknown"
        var dnsNames: [String] = []
        var ipAddresses: [String] = []

        if let cert = SecCertificateCreateWithData(nil, der as CFData) {
            let valueKey = kSecPropertyKeyValue as String
            let queryKeys = [
                kSecOIDX509V1ValidityNotBefore as String,
                kSecOIDX509V1ValidityNotAfter as String,
                kSecOIDX509V1SubjectName as String,
                kSecOIDSubjectAltName as String,
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
                if let cn = subjectCommonName(from: dict) {
                    commonName = cn
                }
                let sans = subjectAltNames(from: dict)
                dnsNames = sans.dns
                ipAddresses = sans.ips
            }
            if let data = SecCertificateCopySerialNumberData(cert, nil) as Data? {
                serialNumber = hexColonSeparated(data)
            }
        }

        if !isCustom {
            let endpoints = TLSConfiguration.loadStoredEndpoints() ?? TLSCertificateEndpoints.current()
            commonName = endpoints.commonName
            dnsNames = endpoints.dnsNames
            ipAddresses = endpoints.ipAddresses
        } else if dnsNames.isEmpty, !commonName.isEmpty {
            dnsNames = [commonName]
        }

        let sha256 = hexColonSeparated(Data(SHA256.hash(data: der)))
        let sha1 = hexColonSeparated(Data(Insecure.SHA1.hash(data: der)))

        let hostSlug = commonName
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        return Info(
            commonName: commonName,
            dnsNames: dnsNames,
            ipAddresses: ipAddresses,
            notBefore: notBefore,
            notAfter: notAfter,
            sha256Fingerprint: sha256,
            sha1Fingerprint: sha1,
            serialNumber: serialNumber,
            downloadBaseName: "insta360-sync-\(hostSlug)",
            pem: pem,
            isCustomCertificate: isCustom,
            installRecommended: !isCustom
        )
    }

    /// fullchain のうち先頭（リーフ）の PEM ブロックだけを DER にする。
    private static func leafDERData(fromPEM pem: String) throws -> Data {
        guard let leafPEM = firstPEMBlock(in: pem, typeContaining: "CERTIFICATE") else {
            throw TLSCertificateServiceError.invalidPEM
        }
        let base64 = leafPEM
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: base64) else {
            throw TLSCertificateServiceError.invalidPEM
        }
        return data
    }

    private static func firstPEMBlock(in pem: String, typeContaining: String) -> String? {
        let lines = pem.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var collecting: [String] = []
        var inside = false
        for line in lines {
            let text = String(line)
            if text.hasPrefix("-----BEGIN"), text.contains(typeContaining) {
                inside = true
                collecting = [text]
                continue
            }
            if inside {
                collecting.append(text)
                if text.hasPrefix("-----END") {
                    return collecting.joined(separator: "\n")
                }
            }
        }
        return nil
    }

    private static func subjectCommonName(from dict: [String: Any]) -> String? {
        let valueKey = kSecPropertyKeyValue as String
        let labelKey = kSecPropertyKeyLabel as String
        guard let entry = dict[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let values = entry[valueKey] as? [[String: Any]] else {
            return nil
        }
        for item in values {
            let label = (item[labelKey] as? String) ?? ""
            if label == "CN" || label.contains("Common Name") {
                return item[valueKey] as? String
            }
        }
        return nil
    }

    private static func subjectAltNames(from dict: [String: Any]) -> (dns: [String], ips: [String]) {
        let valueKey = kSecPropertyKeyValue as String
        let labelKey = kSecPropertyKeyLabel as String
        guard let entry = dict[kSecOIDSubjectAltName as String] as? [String: Any],
              let values = entry[valueKey] as? [[String: Any]] else {
            return ([], [])
        }
        var dns: [String] = []
        var ips: [String] = []
        for item in values {
            let label = ((item[labelKey] as? String) ?? "").lowercased()
            guard let value = item[valueKey] as? String, !value.isEmpty else { continue }
            if label.contains("dns") {
                dns.append(value)
            } else if label.contains("ip") {
                ips.append(value)
            }
        }
        return (dns, ips)
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

enum TLSCertificateServiceError: LocalizedError, Equatable {
    case invalidPEM
    case fileUnreadable(String)
    case mobileConfigNotApplicable

    var errorDescription: String? {
        switch self {
        case .invalidPEM: "TLS 証明書 PEM の解析に失敗しました"
        case .fileUnreadable(let path): "TLS 証明書ファイルを読めません: \(path)"
        case .mobileConfigNotApplicable:
            "公開 CA（Let's Encrypt 等）の証明書を使用中のため、構成プロファイルのインストールは不要です"
        }
    }
}
