import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var core: SyncCore

    @State private var newDisplayName = ""
    @State private var newSSID = ""
    @State private var newPassword = Insta360Defaults.defaultWiFiPassword
    @State private var httpsPortText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("保存先") {
                    Text(settings.destinationRoot.path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("保存先フォルダを選択…") { chooseDestination() }
                    Picker("フォルダ構造", selection: $settings.folderStructureMode) {
                        ForEach(FolderStructureMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
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

                Section {
                    HStack(spacing: 8) {
                        TextField("HTTPS ポート", text: $httpsPortText)
                            .frame(width: 88)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { applyHTTPSPort() }
                        Button("反映") { applyHTTPSPort() }
                    }
                } header: {
                    Text("PWA / HTTPS サーバー")
                } footer: {
                    Text(
                        "iPhone の PWA と API が接続するポートです。PWA の URL や「PWA を開く」のリンク先に使われます。変更すると実行中のサーバーを自動的に再起動します。"
                    )
                }

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
                    Text("iPhone で PWA をホーム画面に追加し、この API トークンでペアリングしてください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("起動") {
                    Toggle("起動時に自動開始", isOn: $settings.autoStartOnLaunch)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Insta360 Sync 設定")
            .frame(minWidth: 540, minHeight: 620)
            .onAppear {
                httpsPortText = String(settings.httpsPort)
            }
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

    private func applyHTTPSPort(from rawValue: String? = nil) {
        let text = rawValue ?? httpsPortText
        guard let port = Int(text), (1024 ... 65535).contains(port) else { return }
        let newPort = UInt16(port)
        guard settings.httpsPort != newPort else { return }
        settings.httpsPort = newPort
        httpsPortText = String(newPort)
        if case .running = core.appStatus {
            Task { await core.restart() }
        }
    }
}
