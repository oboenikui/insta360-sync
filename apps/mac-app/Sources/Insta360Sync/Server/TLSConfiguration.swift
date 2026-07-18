import Foundation
import Network
import Security

struct TLSCertificateEndpoints: Codable, Equatable {
    /// 証明書生成ロジックのバージョン。openssl 引数を変えたら必ずインクリメントし、
    /// 既存ユーザーの証明書を強制的に再生成させる。旧マニフェストには存在しないため
    /// Optional にしておくことで JSON デコードが失敗せず、`nil != currentFormatVersion`
    /// によって等値比較が外れ、再生成が走る。
    var formatVersion: Int?
    var commonName: String
    var dnsNames: [String]
    var ipAddresses: [String]

    /// - v2: `basicConstraints=CA:TRUE`, `keyUsage=keyCertSign,...`, `extendedKeyUsage=serverAuth`
    ///   を追加し、iOS の証明書信頼設定で「フル信頼」を有効化できるようにした。
    static let currentFormatVersion = 2

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
            // LAN のプライベート IPv4 のみ。変動するグローバル IPv6 は SAN に入れない
            // （証明書が頻繁に再生成され、iOS が信頼を失うため）。
            if Self.isPrivateIPv4(address) {
                ips.insert(address)
            }
        }

        let sortedDNS = dns.sorted()
        let cn = sortedDNS.first(where: { $0.hasSuffix(".local") }) ?? sortedDNS.first ?? "localhost"

        return TLSCertificateEndpoints(
            formatVersion: currentFormatVersion,
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
}

enum TLSConfiguration {
    /// macOS の SecPKCS12Import は空パスワードの .p12 を拒否するため、ローカル用途の固定値を使う。
    private static let p12Passphrase = "insta360-sync-local-tls"

    /// TLS 証明書・秘密鍵・SAN マニフェストを保存するディレクトリ。
    static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Insta360Sync/tls", isDirectory: true)
    }

    static var certificatePEMURL: URL {
        storageDirectory.appendingPathComponent("server.crt")
    }

    static var manifestURL: URL {
        storageDirectory.appendingPathComponent("san-manifest.json")
    }

    static func loadStoredEndpoints() -> TLSCertificateEndpoints? {
        loadManifest(from: manifestURL)
    }

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

    /// 設定に応じてカスタム PEM または自己署名の SecIdentity を返す。
    static func loadIdentity(
        certificatePath: String?,
        privateKeyPath: String?,
        directory: URL = storageDirectory
    ) throws -> SecIdentity {
        let cert = certificatePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cert.isEmpty || !key.isEmpty {
            guard !cert.isEmpty, !key.isEmpty else {
                throw TLSError.customCertificateIncomplete
            }
            return try loadIdentityFromPEM(
                certificatePath: URL(fileURLWithPath: cert),
                privateKeyPath: URL(fileURLWithPath: key)
            )
        }
        return try loadOrCreateIdentity(directory: directory)
    }

    /// Let's Encrypt 等の証明書 PEM + 秘密鍵 PEM から SecIdentity を構築する。
    /// `certificatePath` は fullchain.pem（リーフ + 中間）を推奨。
    static func loadIdentityFromPEM(certificatePath: URL, privateKeyPath: URL) throws -> SecIdentity {
        let certData: Data
        let keyData: Data
        do {
            certData = try Data(contentsOf: certificatePath)
        } catch {
            throw TLSError.customCertificateUnreadable(certificatePath.path, underlying: error)
        }
        do {
            keyData = try Data(contentsOf: privateKeyPath)
        } catch {
            throw TLSError.customCertificateUnreadable(privateKeyPath.path, underlying: error)
        }

        guard let certPEM = String(data: certData, encoding: .utf8),
              certPEM.contains("BEGIN CERTIFICATE") else {
            throw TLSError.customCertificateInvalidPEM(certificatePath.path)
        }
        guard let keyPEM = String(data: keyData, encoding: .utf8),
              keyPEM.contains("BEGIN") && keyPEM.contains("PRIVATE KEY") else {
            throw TLSError.customCertificateInvalidPEM(privateKeyPath.path)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Insta360Sync-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (leafPath, chainPath) = try splitCertificateChain(pem: certPEM, into: tempDir)
        let p12Path = tempDir.appendingPathComponent("custom.p12")
        try exportPKCS12(
            certificatePath: leafPath,
            privateKeyPath: privateKeyPath,
            chainPath: chainPath,
            p12Path: p12Path
        )
        AppLogger.shared.info(
            "Loaded custom TLS certificate from \(certificatePath.path)",
            category: .server
        )
        return try importIdentity(from: p12Path)
    }

    /// fullchain PEM をリーフと中間チェーンに分割する。チェーンが無ければ `chainPath` は nil。
    private static func splitCertificateChain(
        pem: String,
        into directory: URL
    ) throws -> (leaf: URL, chain: URL?) {
        var blocks: [String] = []
        var current: [String] = []
        var inside = false
        for line in pem.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix("-----BEGIN"), text.contains("CERTIFICATE") {
                inside = true
                current = [text]
                continue
            }
            if inside {
                current.append(text)
                if text.hasPrefix("-----END") {
                    blocks.append(current.joined(separator: "\n"))
                    inside = false
                    current = []
                }
            }
        }
        guard let leaf = blocks.first else {
            throw TLSError.customCertificateInvalidPEM(directory.path)
        }
        let leafPath = directory.appendingPathComponent("leaf.crt")
        try (leaf + "\n").write(to: leafPath, atomically: true, encoding: .utf8)
        guard blocks.count > 1 else {
            return (leafPath, nil)
        }
        let chainPath = directory.appendingPathComponent("chain.crt")
        let chainPEM = blocks.dropFirst().joined(separator: "\n") + "\n"
        try chainPEM.write(to: chainPath, atomically: true, encoding: .utf8)
        return (leafPath, chainPath)
    }

    static func loadOrCreateIdentity(directory: URL) throws -> SecIdentity {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let endpoints = TLSCertificateEndpoints.current()
        let manifestPath = directory.appendingPathComponent("san-manifest.json")
        let p12Path = directory.appendingPathComponent("server.p12")

        if fm.fileExists(atPath: p12Path.path),
           let identity = try? importIdentity(from: p12Path) {
            let stored = loadManifest(from: manifestPath)
            if !needsRegeneration(stored: stored) {
                if let stored, stored != endpoints {
                    AppLogger.shared.debug(
                        "Reusing TLS certificate despite SAN change " +
                            "(stored CN=\(stored.commonName), current CN=\(endpoints.commonName))"
                    )
                }
                return identity
            }
            AppLogger.shared.info(
                "Regenerating TLS certificate for format upgrade " +
                    "(v\(stored?.formatVersion ?? 0) -> v\(TLSCertificateEndpoints.currentFormatVersion))"
            )
        }

        for fileName in ["server.p12", "server.crt", "server.key", "san-manifest.json"] {
            try? fm.removeItem(at: directory.appendingPathComponent(fileName))
        }

        try generatePKCS12(in: directory, endpoints: endpoints, p12Path: p12Path)
        try saveManifest(endpoints, to: manifestPath)
        return try importIdentity(from: p12Path)
    }

    /// 証明書を再生成すべきか。SAN の変化（LAN IP 変更など）では再生成しない。
    /// クライアントにインストール済みのルート証明書を維持するため。
    private static func needsRegeneration(stored: TLSCertificateEndpoints?) -> Bool {
        guard let stored else { return false }
        let version = stored.formatVersion ?? 0
        return version < TLSCertificateEndpoints.currentFormatVersion
    }

    static func loadManifest(from path: URL) -> TLSCertificateEndpoints? {
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
        try exportPKCS12(
            certificatePath: certPath,
            privateKeyPath: keyPath,
            chainPath: nil,
            p12Path: p12Path
        )
    }

    /// リーフ証明書・秘密鍵・任意の中間チェーンから PKCS#12 を書き出す。
    private static func exportPKCS12(
        certificatePath: URL,
        privateKeyPath: URL,
        chainPath: URL?,
        p12Path: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        var arguments = [
            "pkcs12", "-export",
            "-out", p12Path.path,
            "-inkey", privateKeyPath.path,
            "-in", certificatePath.path,
            "-passout", "pass:\(p12Passphrase)",
            "-name", "Insta360 Sync",
        ]
        if let chainPath {
            arguments.append(contentsOf: ["-certfile", chainPath.path])
        }
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            AppLogger.shared.error(
                "openssl pkcs12 export failed: \(errText.isEmpty ? "exit \(process.terminationStatus)" : errText)",
                category: .server
            )
            throw TLSError.customCertificateExportFailed
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
            "-sha256",
            "-subj", "/CN=\(endpoints.commonName)/O=Local",
            "-addext", "subjectAltName=\(endpoints.subjectAltName)",
            // iOS の「証明書信頼設定」に表示させるためには CA:TRUE と鍵署名可能な keyUsage が必要。
            // 単一の自己署名ルート証明書でありながら TLS サーバー証明書としても振る舞うため、
            // 署名系フラグと serverAuth の EKU を両方付ける。
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign",
            "-addext", "extendedKeyUsage=serverAuth,clientAuth",
            "-addext", "subjectKeyIdentifier=hash",
            "-addext", "authorityKeyIdentifier=keyid:always,issuer",
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
    case customCertificateIncomplete
    case customCertificateUnreadable(String, underlying: Error?)
    case customCertificateInvalidPEM(String)
    case customCertificateExportFailed

    var errorDescription: String? {
        switch self {
        case .certificateGenerationFailed:
            return "TLS 証明書の生成に失敗しました"
        case .certificateImportFailed:
            return "TLS 証明書の読み込みに失敗しました"
        case .keyImportFailed:
            return "TLS 秘密鍵の読み込みに失敗しました"
        case .identityNotFound:
            return "TLS identity の作成に失敗しました"
        case .customCertificateIncomplete:
            return "カスタム証明書を使うには証明書 PEM と秘密鍵 PEM の両方のパスが必要です"
        case .customCertificateUnreadable(let path, let underlying):
            let hint: String
            if path.contains("/etc/letsencrypt/") {
                hint = " （/etc/letsencrypt は root 専用です。~/Insta360Sync/tls などへコピーしてそのパスを指定してください）"
            } else if let nsError = underlying as? NSError,
                      nsError.domain == NSCocoaErrorDomain,
                      nsError.code == NSFileReadNoPermissionError {
                hint = " （権限がありません。このユーザーが読める場所へコピーしてください）"
            } else if let underlying {
                hint = " （\(underlying.localizedDescription)）"
            } else {
                hint = ""
            }
            return "TLS 証明書ファイルを読めません: \(path)\(hint)"
        case .customCertificateInvalidPEM(let path):
            return "TLS 証明書 PEM が不正です: \(path)"
        case .customCertificateExportFailed:
            return "カスタム TLS 証明書の PKCS#12 変換に失敗しました（証明書と秘密鍵の対応を確認してください）"
        }
    }
}
