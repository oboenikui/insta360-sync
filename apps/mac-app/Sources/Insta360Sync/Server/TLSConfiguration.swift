import Foundation
import Network
import Security

struct TLSCertificateEndpoints: Codable, Equatable {
    var commonName: String
    var dnsNames: [String]
    var ipAddresses: [String]

    static func current() -> TLSCertificateEndpoints {
        let host = Host.current()
        var dns = Set<String>()
        dns.insert("localhost")

        if let name = host.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let normalized = Self.normalizeHostName(name)
            dns.insert(normalized)
            if normalized.hasSuffix(".local") {
                dns.insert(String(normalized.dropLast(".local".count)))
            } else {
                dns.insert("\(normalized).local")
            }
        }

        if let localized = host.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localized.isEmpty,
           Self.isValidDNSLabel(localized) {
            let label = localized.localizedLowercase
            dns.insert(label)
            dns.insert("\(label).local")
        }

        var ips = Set<String>()
        ips.insert("127.0.0.1")
        ips.insert("::1")

        for raw in host.addresses {
            let address = Self.stripZoneIdentifier(raw)
            if Self.isLoopback(address) {
                ips.insert(address)
                continue
            }
            if Self.isPrivateIPv4(address) || Self.isLANIPv6(address) {
                ips.insert(address)
            }
        }

        let sortedDNS = dns.sorted()
        let cn = sortedDNS.first(where: { $0.hasSuffix(".local") }) ?? sortedDNS.first ?? "localhost"

        return TLSCertificateEndpoints(
            commonName: cn,
            dnsNames: sortedDNS,
            ipAddresses: ips.sorted()
        )
    }

    var subjectAltName: String {
        var parts: [String] = []
        parts.append(contentsOf: dnsNames.map { "DNS:\($0)" })
        parts.append(contentsOf: ipAddresses.map { "IP:\($0)" })
        return parts.joined(separator: ",")
    }

    private static func normalizeHostName(_ name: String) -> String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    private static func stripZoneIdentifier(_ address: String) -> String {
        guard let index = address.firstIndex(of: "%") else { return address }
        return String(address[..<index])
    }

    private static func isValidDNSLabel(_ label: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return !label.isEmpty && label.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1"
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 10:
            return true
        case 172 where (16 ... 31).contains(octets[1]):
            return true
        case 192 where octets[1] == 168:
            return true
        default:
            return false
        }
    }

    private static func isLANIPv6(_ address: String) -> Bool {
        if address.hasPrefix("fe80:") { return false }
        return address.contains(":")
    }
}

enum TLSConfiguration {
    /// macOS の SecPKCS12Import は空パスワードの .p12 を拒否するため、ローカル用途の固定値を使う。
    private static let p12Passphrase = "insta360-sync-local-tls"

    static func makeServerParameters(identity: SecIdentity) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            fatalError("sec_identity_create failed")
        }
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            secIdentity
        )
        let params = NWParameters(tls: tlsOptions)
        params.allowLocalEndpointReuse = true
        return params
    }

    static func loadOrCreateIdentity(directory: URL) throws -> SecIdentity {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let endpoints = TLSCertificateEndpoints.current()
        let manifestPath = directory.appendingPathComponent("san-manifest.json")
        let p12Path = directory.appendingPathComponent("server.p12")

        if fm.fileExists(atPath: p12Path.path),
           let stored = loadManifest(from: manifestPath),
           stored == endpoints,
           let identity = try? importIdentity(from: p12Path) {
            return identity
        }

        if storedManifestDiffers(from: manifestPath, current: endpoints) {
            AppLogger.shared.info(
                "Regenerating TLS certificate for CN=\(endpoints.commonName) " +
                    "(SAN DNS=\(endpoints.dnsNames.count), IP=\(endpoints.ipAddresses.count))"
            )
        }

        for fileName in ["server.p12", "server.crt", "server.key", "san-manifest.json"] {
            try? fm.removeItem(at: directory.appendingPathComponent(fileName))
        }

        try generatePKCS12(in: directory, endpoints: endpoints, p12Path: p12Path)
        try saveManifest(endpoints, to: manifestPath)
        return try importIdentity(from: p12Path)
    }

    private static func storedManifestDiffers(from path: URL, current: TLSCertificateEndpoints) -> Bool {
        guard let stored = loadManifest(from: path) else { return false }
        return stored != current
    }

    private static func loadManifest(from path: URL) -> TLSCertificateEndpoints? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(TLSCertificateEndpoints.self, from: data)
    }

    private static func saveManifest(_ endpoints: TLSCertificateEndpoints, to path: URL) throws {
        let data = try JSONEncoder().encode(endpoints)
        try data.write(to: path, options: .atomic)
    }

    private static func generatePKCS12(
        in directory: URL,
        endpoints: TLSCertificateEndpoints,
        p12Path: URL
    ) throws {
        let certPath = directory.appendingPathComponent("server.crt")
        let keyPath = directory.appendingPathComponent("server.key")
        try generateCertificate(certPath: certPath, keyPath: keyPath, endpoints: endpoints)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "pkcs12", "-export",
            "-out", p12Path.path,
            "-inkey", keyPath.path,
            "-in", certPath.path,
            "-passout", "pass:\(p12Passphrase)",
            "-name", "Insta360 Sync",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TLSError.certificateGenerationFailed
        }
    }

    private static func generateCertificate(
        certPath: URL,
        keyPath: URL,
        endpoints: TLSCertificateEndpoints
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyPath.path,
            "-out", certPath.path,
            "-days", "825", "-nodes",
            "-subj", "/CN=\(endpoints.commonName)/O=Local",
            "-addext", "subjectAltName=\(endpoints.subjectAltName)",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TLSError.certificateGenerationFailed
        }
    }

    private static func importIdentity(from p12Path: URL) throws -> SecIdentity {
        let data = try Data(contentsOf: p12Path)
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Passphrase]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            AppLogger.shared.error("SecPKCS12Import failed with OSStatus \(status)")
            throw TLSError.certificateImportFailed
        }
        guard let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw TLSError.identityNotFound
        }
        return (identity as! SecIdentity)
    }
}

enum TLSError: LocalizedError {
    case certificateGenerationFailed
    case certificateImportFailed
    case keyImportFailed
    case identityNotFound

    var errorDescription: String? {
        switch self {
        case .certificateGenerationFailed: "TLS 証明書の生成に失敗しました"
        case .certificateImportFailed: "TLS 証明書の読み込みに失敗しました"
        case .keyImportFailed: "TLS 秘密鍵の読み込みに失敗しました"
        case .identityNotFound: "TLS identity の作成に失敗しました"
        }
    }
}
