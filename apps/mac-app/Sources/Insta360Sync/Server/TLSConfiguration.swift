import Foundation
import Network
import Security

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

        let p12Path = directory.appendingPathComponent("server.p12")
        if fm.fileExists(atPath: p12Path.path) {
            if let identity = try? importIdentity(from: p12Path) {
                return identity
            }
            AppLogger.shared.warning("Existing server.p12 could not be imported; regenerating")
            try? fm.removeItem(at: p12Path)
        }

        try generatePKCS12(in: directory, p12Path: p12Path)
        return try importIdentity(from: p12Path)
    }

    private static func generatePKCS12(in directory: URL, p12Path: URL) throws {
        let certPath = directory.appendingPathComponent("server.crt")
        let keyPath = directory.appendingPathComponent("server.key")

        if !FileManager.default.fileExists(atPath: certPath.path)
            || !FileManager.default.fileExists(atPath: keyPath.path) {
            try generateCertificate(certPath: certPath, keyPath: keyPath)
        }

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

    private static func generateCertificate(certPath: URL, keyPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyPath.path,
            "-out", certPath.path,
            "-days", "825", "-nodes",
            "-subj", "/CN=Insta360 Sync/O=Local",
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
