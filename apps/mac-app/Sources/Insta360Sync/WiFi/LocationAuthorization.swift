import AppKit
import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationAuthorization: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAuthorization()

    private let manager = CLLocationManager()
    private var promotedForPermissionPrompt = false
    private var permissionPromptFallbackTask: Task<Void, Never>?
    private(set) var isAuthorized = false
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var servicesEnabled = CLLocationManager.locationServicesEnabled()

    override private init() {
        super.init()
        manager.delegate = self
        refreshAuthorization()
    }

    var statusMessage: String {
        if !servicesEnabled {
            return "Mac の位置情報サービスがオフです。システム設定で有効にしてください。"
        }
        switch authorizationStatus {
        case .notDetermined:
            return "Wi-Fi の SSID を読み取るには位置情報の許可が必要です。"
        case .denied, .restricted:
            return "位置情報が拒否されています。システム設定で Insta360 Sync を許可してください。"
        case .authorizedAlways, .authorizedWhenInUse:
            return ""
        @unknown default:
            return "位置情報の許可が必要です。"
        }
    }

    var actionButtonTitle: String? {
        if !servicesEnabled {
            return "位置情報サービスを開く"
        }
        switch authorizationStatus {
        case .notDetermined:
            return "位置情報を許可…"
        case .denied, .restricted:
            return "システム設定を開く"
        case .authorizedAlways, .authorizedWhenInUse:
            return nil
        @unknown default:
            return "位置情報を許可…"
        }
    }

    func requestIfNeeded() {
        refreshAuthorization()
        guard servicesEnabled else { return }
        if authorizationStatus == .notDetermined {
            requestAuthorization()
        }
    }

    func requestAuthorization() {
        permissionPromptFallbackTask?.cancel()
        refreshAuthorization()
        guard servicesEnabled else {
            openLocationSettings()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        promoteForPermissionPrompt()

        switch manager.authorizationStatus {
        case .notDetermined:
            AppLogger.shared.info("Requesting location authorization")
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
            schedulePermissionPromptFallback()
        case .denied, .restricted:
            restoreActivationPolicyIfNeeded()
            openLocationSettings()
        case .authorizedAlways, .authorizedWhenInUse:
            restoreActivationPolicyIfNeeded()
            refreshAuthorization()
        @unknown default:
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
            schedulePermissionPromptFallback()
        }
    }

    func openLocationSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let urlStrings = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:",
        ]
        for urlString in urlStrings {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
        AppLogger.shared.warning("Failed to open Location Services settings")
    }

    private func promoteForPermissionPrompt() {
        guard NSApp.activationPolicy() == .accessory else { return }
        NSApp.setActivationPolicy(.regular)
        promotedForPermissionPrompt = true
    }

    private func restoreActivationPolicyIfNeeded() {
        permissionPromptFallbackTask?.cancel()
        permissionPromptFallbackTask = nil
        guard promotedForPermissionPrompt else { return }
        promotedForPermissionPrompt = false
        NSApp.setActivationPolicy(.accessory)
    }

    private func schedulePermissionPromptFallback() {
        permissionPromptFallbackTask?.cancel()
        permissionPromptFallbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            refreshAuthorization()
            guard authorizationStatus == .notDetermined else {
                restoreActivationPolicyIfNeeded()
                return
            }
            AppLogger.shared.warning("Location authorization prompt did not appear")
            restoreActivationPolicyIfNeeded()
            showPermissionGuidanceAlert()
        }
    }

    private func showPermissionGuidanceAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "位置情報の許可が必要です"
        alert.informativeText =
            "Wi-Fi の SSID を検知するには位置情報の許可が必要です。システム設定で Insta360 Sync を許可してください。"
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "後で")
        if alert.runModal() == .alertFirstButtonReturn {
            openLocationSettings()
        }
    }

    func refreshAuthorization() {
        servicesEnabled = CLLocationManager.locationServicesEnabled()
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            isAuthorized = servicesEnabled
        default:
            isAuthorized = false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            refreshAuthorization()
            if isAuthorized {
                self.manager.stopUpdatingLocation()
            }
            restoreActivationPolicyIfNeeded()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            refreshAuthorization()
            self.manager.stopUpdatingLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            AppLogger.shared.warning("Location manager error: \(error.localizedDescription)")
            refreshAuthorization()
            self.manager.stopUpdatingLocation()
        }
    }
}
