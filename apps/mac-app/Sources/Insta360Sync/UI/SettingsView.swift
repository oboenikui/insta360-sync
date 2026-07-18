import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var core: SyncCore

    @State private var newDisplayName = ""
    @State private var newSSID = ""
    @State private var newPassword = Insta360Defaults.defaultWiFiPassword
    @State private var pushTestMessage = ""
    @State private var isSendingTestPush = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(settings.destinationRoot.path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("保存先フォルダを選択…") { chooseDestination() }
                    Picker("フォルダ構造", selection: $settings.folderStructureMode) {
                        ForEach(FolderStructureMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("重複ファイル", selection: $settings.duplicateFileBehavior) {
                        ForEach(DuplicateFileBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                } header: {
                    Text("保存先")
                } footer: {
                    Text("保存先に同名ファイルがある場合の動作です。")
                }

                Section("カメラ") {
                    ForEach($settings.cameras) { $camera in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("表示名", text: $camera.displayName)
                            TextField("SSID", text: $camera.ssid)
                            PasswordField(title: "Wi-Fi パスワード", text: $camera.wifiPassword)
                            Toggle("有効", isOn: $camera.isEnabled)
                            HStack {
                                Button("今すぐバックアップ") {
                                    Task { await core.runManualBackup(cameraID: camera.id) }
                                }
                                Spacer()
                                Button("削除", role: .destructive) {
                                    settings.cameras.removeAll { $0.id == camera.id }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    TextField("表示名", text: $newDisplayName)
                    TextField("SSID", text: $newSSID)
                    PasswordField(title: "Wi-Fi パスワード", text: $newPassword)
                    Button("カメラを追加") { addCamera() }
                        .disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    LocationPermissionBanner()
                } header: {
                    Text("位置情報")
                } footer: {
                    Text("macOS では Wi-Fi の SSID 取得に位置情報の許可が必要です。ダイアログが出ない場合は .app 版（make mac-app）で起動してください。")
                }

                Section {
                    Stepper(
                        "スキャン間隔: \(Int(settings.scanIntervalSeconds)) 秒",
                        value: $settings.scanIntervalSeconds,
                        in: 10 ... 300,
                        step: 5
                    )
                } header: {
                    Text("Wi-Fi 監視")
                } footer: {
                    Text("登録済み SSID が近くにあるかどうかを定期的に確認します。")
                }

                HTTPSServerSettingsSection(settings: settings, core: core)

                Section("PWA / API") {
                    LabeledContent("API トークン") {
                        HStack(spacing: 8) {
                            Text(settings.apiToken)
                                .font(.caption)
                                .textSelection(.enabled)
                            Button("コピー") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(settings.apiToken, forType: .string)
                            }
                        }
                    }
                    LabeledContent("VAPID 公開鍵") {
                        Text(settings.vapidPublicKey)
                            .font(.caption2)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    LabeledContent("VAPID subject (sub)") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(settings.vapidSubject)
                                .font(.caption2)
                                .textSelection(.enabled)
                            if VAPIDKeys.isProblematicSubjectForApple(settings.vapidSubject) {
                                Text("Apple は .local / localhost を含む subject を拒否します")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    Text("iPhone で PWA をホーム画面に追加し、この API トークンでペアリングしてください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if settings.pushSubscriptions.isEmpty {
                        Text("登録済みの購読はありません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.pushSubscriptions) { subscription in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(subscription.endpointHost)
                                    Text(subscription.createdAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("削除", role: .destructive) {
                                    core.removePushSubscription(endpoint: subscription.endpoint)
                                }
                            }
                        }
                    }
                    HStack {
                        Button("テスト通知を送信") {
                            Task { await sendTestPushFromMac() }
                        }
                        .disabled(settings.pushSubscriptions.isEmpty || isSendingTestPush)
                        Button("すべて削除", role: .destructive) {
                            core.removeAllPushSubscriptions()
                            pushTestMessage = ""
                        }
                        .disabled(settings.pushSubscriptions.isEmpty)
                    }
                    if !pushTestMessage.isEmpty {
                        Text(pushTestMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Push 通知")
                } footer: {
                    Text("テスト通知で iPhone に届くか確認できます。HTTP 410 の購読は送信時に自動削除されます。")
                }

                Section("起動") {
                    Toggle("起動時に自動開始", isOn: $settings.autoStartOnLaunch)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Insta360 Sync 設定")
            .frame(minWidth: 540, minHeight: 620)
        }
    }

    private func addCamera() {
        let name = newDisplayName.trimmingCharacters(in: .whitespaces)
        let ssid = newSSID.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty else { return }
        settings.cameras.append(
            CameraProfile(
                displayName: name.isEmpty ? ssid : name,
                ssid: ssid,
                wifiPassword: newPassword
            )
        )
        newDisplayName = ""
        newSSID = ""
        newPassword = Insta360Defaults.defaultWiFiPassword
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = "バックアップ先フォルダを選択するか、新しいフォルダを作成してください。"
        if panel.runModal() == .OK, let url = panel.url {
            settings.destinationRoot = url
        }
    }

    private func sendTestPushFromMac() async {
        isSendingTestPush = true
        defer { isSendingTestPush = false }
        let results = await core.sendTestPush()
        if results.isEmpty {
            pushTestMessage = "購読が登録されていません"
            return
        }
        let lines = results.map { formatPushDeliveryResult($0) }
        pushTestMessage = lines.joined(separator: "\n\n")
    }

    private func formatPushDeliveryResult(_ result: PushDeliveryResult) -> String {
        var lines: [String] = []
        if result.ok {
            lines.append("✓ \(result.endpointHost) …\(result.endpointSuffix)")
            lines.append("HTTP \(result.statusCode ?? 0)")
        } else {
            lines.append("✗ \(result.endpointHost) …\(result.endpointSuffix)")
            if let status = result.statusCode {
                lines.append("HTTP \(status)\(result.reason.map { ": \($0)" } ?? "")")
            } else {
                lines.append(result.error ?? "失敗")
            }
        }
        if let payloadBytes = result.payloadBytes {
            lines.append("payload: \(payloadBytes) bytes")
        }
        if let apnsID = result.apnsID {
            lines.append("apns-id: \(apnsID)")
        }
        for (key, value) in result.responseHeaders.sorted(by: { $0.key < $1.key })
            where key.lowercased() != "apns-id" {
            lines.append("\(key): \(value)")
        }
        if let body = result.responseBody, !body.isEmpty {
            lines.append("body: \(body)")
        } else if result.ok {
            lines.append("body: (empty)")
        }
        if !result.ok, let error = result.error {
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }
}

/// HTTPS 設定だけを分離し、入力中に Form 全体（Host 解決など）を再描画しない。
private struct HTTPSServerSettingsSection: View {
    @Bindable var settings: AppSettings
    var core: SyncCore

    @State private var httpsPortText = ""
    @State private var publicHostnameText = ""
    @State private var tlsCertificatePathText = ""
    @State private var tlsPrivateKeyPathText = ""
    /// 表示用フォールバックホスト。入力のたびに Host.current() しない。
    @State private var fallbackHost = "localhost"
    @State private var saveMessage = ""

    private var previewURL: String {
        let host: String = {
            let custom = publicHostnameText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { return custom }
            return fallbackHost
        }()
        let port = Int(httpsPortText).map(String.init) ?? String(settings.httpsPort)
        return "https://\(host):\(port)/"
    }

    private var hasUnsavedChanges: Bool {
        let hostname = publicHostnameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let certPath = tlsCertificatePathText.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPath = tlsPrivateKeyPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        let portMatches: Bool = {
            guard let port = Int(httpsPortText), (1024 ... 65535).contains(port) else {
                return httpsPortText == String(settings.httpsPort)
            }
            return UInt16(port) == settings.httpsPort
        }()
        return !portMatches
            || hostname != settings.publicHostname
            || certPath != settings.tlsCertificatePath
            || keyPath != settings.tlsPrivateKeyPath
    }

    var body: some View {
        Section {
            TextField("HTTPS ポート", text: $httpsPortText)
                .frame(width: 88)
                .multilineTextAlignment(.trailing)

            TextField("公開ホスト名", text: $publicHostnameText)

            HStack(spacing: 8) {
                TextField("証明書 PEM（fullchain）", text: $tlsCertificatePathText)
                Button("選択…") { chooseTLSFile(for: .certificate) }
            }

            HStack(spacing: 8) {
                TextField("秘密鍵 PEM", text: $tlsPrivateKeyPathText)
                Button("選択…") { chooseTLSFile(for: .privateKey) }
            }

            LabeledContent("PWA URL（プレビュー）") {
                Text(previewURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button("保存して反映") { applyHTTPSServerSettings() }
                    .disabled(!hasUnsavedChanges)
                if hasUnsavedChanges {
                    Text("未保存の変更があります")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("PWA / HTTPS サーバー")
        } footer: {
            Text(
                "入力後は「保存して反映」を押してください（実行中ならサーバーを再起動します）。公開ホスト名はメニューバーと「PWA を開く」に使います。Let's Encrypt は fullchain.pem と privkey.pem を指定（両方空なら自己署名）。"
            )
        }
        .onAppear {
            httpsPortText = String(settings.httpsPort)
            publicHostnameText = settings.publicHostname
            tlsCertificatePathText = settings.tlsCertificatePath
            tlsPrivateKeyPathText = settings.tlsPrivateKeyPath
            fallbackHost = cachedFallbackHost()
            saveMessage = ""
        }
    }

    private enum TLSFileKind {
        case certificate
        case privateKey
    }

    private func cachedFallbackHost() -> String {
        let custom = settings.publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if settings.usesCustomTLSCertificate { return "localhost" }
        return TLSCertificateEndpoints.current().commonName
    }

    private func chooseTLSFile(for kind: TLSFileKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "選択"
        panel.message = kind == .certificate
            ? "証明書 PEM（fullchain.pem 推奨）を選択してください。"
            : "秘密鍵 PEM（privkey.pem）を選択してください。"
        if panel.runModal() == .OK, let url = panel.url {
            switch kind {
            case .certificate:
                tlsCertificatePathText = url.path
            case .privateKey:
                tlsPrivateKeyPathText = url.path
            }
            saveMessage = ""
        }
    }

    private func applyHTTPSServerSettings() {
        var changed = false

        if let port = Int(httpsPortText), (1024 ... 65535).contains(port) {
            let newPort = UInt16(port)
            if settings.httpsPort != newPort {
                settings.httpsPort = newPort
                changed = true
            }
            httpsPortText = String(newPort)
        } else {
            httpsPortText = String(settings.httpsPort)
        }

        let hostname = publicHostnameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.publicHostname != hostname {
            settings.publicHostname = hostname
            publicHostnameText = hostname
            changed = true
        }

        let certPath = tlsCertificatePathText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.tlsCertificatePath != certPath {
            settings.tlsCertificatePath = certPath
            tlsCertificatePathText = certPath
            changed = true
        }

        let keyPath = tlsPrivateKeyPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.tlsPrivateKeyPath != keyPath {
            settings.tlsPrivateKeyPath = keyPath
            tlsPrivateKeyPathText = keyPath
            changed = true
        }

        guard changed else {
            saveMessage = "変更はありません"
            return
        }

        if case .running = core.appStatus {
            Task { await core.restart() }
            saveMessage = "保存しました（サーバーを再起動しました）"
        } else {
            saveMessage = "保存しました"
        }
    }
}
