import CoreWLAN
import Foundation

final class WiFiMonitor: @unchecked Sendable {
    struct DetectedCamera: Sendable {
        var profile: CameraProfile
    }

    private static let rememberedNetworkKey = "insta360.lastNonCameraSSID"

    private let client = CWWiFiClient.shared()
    private var scanTask: Task<Void, Never>?
    private var onDetected: (@Sendable (DetectedCamera) -> Void)?

    func start(
        interval: TimeInterval,
        camerasProvider: @MainActor @escaping () -> [CameraProfile],
        onDetected: @escaping @Sendable (DetectedCamera) -> Void
    ) {
        self.onDetected = onDetected
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let cameras = await MainActor.run { camerasProvider() }
                await self.scanOnce(cameras: cameras)
                let wait = max(5, interval)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    func currentSSID() -> String? {
        client.interface()?.ssid()
    }

    /// Connect to the camera AP only when not already associated and reachable.
    func connectIfNeeded(to profile: CameraProfile) async throws {
        if currentSSID() == profile.ssid, await pingCamera() {
            AppLogger.shared.info("Already on camera Wi-Fi (\(profile.ssid))")
            return
        }
        try await connect(to: profile)
    }

    func connect(to profile: CameraProfile) async throws {
        guard let interface = client.interface() else {
            throw WiFiError.noInterface
        }
        let networks = try interface.scanForNetworks(withSSID: Data(profile.ssid.utf8), includeHidden: true)
        guard let network = networks.first else {
            throw WiFiError.networkNotFound(profile.ssid)
        }
        try interface.associate(to: network, password: profile.wifiPassword)
        try await waitForCameraReachable(timeout: 20)
    }

    /// After backup: return to the previous network, or disconnect from the camera AP.
    func finishCameraSession(previousSSID: String?, cameraSSID: String) async {
        if let previousSSID, !previousSSID.isEmpty, previousSSID != cameraSSID {
            rememberNonCameraNetwork(previousSSID)
            AppLogger.shared.info("Restoring Wi-Fi to \(previousSSID)")
            await restoreNetwork(ssid: previousSSID, password: nil)
            return
        }

        if let remembered = rememberedNonCameraSSID(), remembered != cameraSSID {
            AppLogger.shared.info("Restoring Wi-Fi to remembered network \(remembered)")
            await restoreNetwork(ssid: remembered, password: nil)
            return
        }

        if currentSSID() == cameraSSID {
            AppLogger.shared.info("Disconnecting from camera Wi-Fi (\(cameraSSID))")
            disassociateFromCurrentNetwork()
        }
    }

    func rememberNonCameraNetwork(_ ssid: String) {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.rememberedNetworkKey)
    }

    private func rememberedNonCameraSSID() -> String? {
        UserDefaults.standard.string(forKey: Self.rememberedNetworkKey)
    }

    func restoreNetwork(ssid: String, password: String?) async {
        guard !ssid.isEmpty, let interface = client.interface() else { return }
        do {
            let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8), includeHidden: true)
            guard let network = networks.first else {
                AppLogger.shared.warning("Could not find network \(ssid) for restore")
                return
            }
            try interface.associate(to: network, password: password)
            AppLogger.shared.info("Restored Wi-Fi connection to \(ssid)")
        } catch {
            AppLogger.shared.error("Failed to restore Wi-Fi to \(ssid): \(error.localizedDescription)")
        }
    }

    private func disassociateFromCurrentNetwork() {
        guard let interface = client.interface() else { return }
        interface.disassociate()
    }

    private func scanOnce(cameras: [CameraProfile]) async {
        let authorized = await MainActor.run { LocationAuthorization.shared.isAuthorized }
        guard authorized else { return }
        guard let interface = client.interface() else { return }

        let cameraSSIDs = Set(cameras.map(\.ssid))
        if let ssid = interface.ssid(), !cameraSSIDs.contains(ssid) {
            rememberNonCameraNetwork(ssid)
        }

        for camera in cameras where camera.isEnabled {
            do {
                let networks = try interface.scanForNetworks(withSSID: Data(camera.ssid.utf8), includeHidden: true)
                if !networks.isEmpty {
                    onDetected?(DetectedCamera(profile: camera))
                }
            } catch {
                AppLogger.shared.debug("Scan failed for \(camera.ssid): \(error.localizedDescription)")
            }
        }
    }

    private func waitForCameraReachable(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await pingCamera() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw WiFiError.cameraUnreachable
    }

    private func pingCamera() async -> Bool {
        guard let url = URL(string: "http://\(Insta360Defaults.cameraHost)/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200 ..< 500).contains(http.statusCode)
            }
        } catch {
            return false
        }
        return false
    }
}

enum WiFiError: LocalizedError {
    case noInterface
    case networkNotFound(String)
    case cameraUnreachable

    var errorDescription: String? {
        switch self {
        case .noInterface: "Wi-Fi interface unavailable"
        case .networkNotFound(let ssid): "Network not found: \(ssid)"
        case .cameraUnreachable: "Camera at 192.168.42.1 is unreachable"
        }
    }
}
