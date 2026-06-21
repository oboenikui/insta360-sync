import AppKit
import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationAuthorization: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAuthorization()

    private let manager = CLLocationManager()
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
        refreshAuthorization()
        guard servicesEnabled else {
            openLocationSettings()
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        switch manager.authorizationStatus {
        case .notDetermined:
            AppLogger.shared.info("Requesting location authorization")
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
        case .denied, .restricted:
            openLocationSettings()
        case .authorizedAlways, .authorizedWhenInUse:
            refreshAuthorization()
        @unknown default:
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
        }
    }

    func openLocationSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let urlStrings = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
        ]
        for urlString in urlStrings {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
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
