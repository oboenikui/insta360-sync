import Foundation

@MainActor
final class PendingBackupStore {
    private(set) var pending: [PendingBackup] = []
    private var recentlyNotified: [UUID: Date] = [:]
    private let cooldown: TimeInterval = 300

    func createPending(for camera: CameraProfile) -> PendingBackup? {
        if let existing = pending.first(where: {
            $0.cameraID == camera.id && ($0.status == .pending || $0.status == .approved || $0.status == .running)
        }) {
            return existing
        }
        if let last = recentlyNotified[camera.id], Date().timeIntervalSince(last) < cooldown {
            return nil
        }
        let item = PendingBackup(
            id: UUID(),
            cameraID: camera.id,
            cameraName: camera.displayName,
            ssid: camera.ssid,
            detectedAt: Date(),
            status: .pending
        )
        pending.insert(item, at: 0)
        recentlyNotified[camera.id] = Date()
        return item
    }

    func update(_ id: UUID, status: PendingBackup.PendingStatus) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].status = status
    }

    func item(id: UUID) -> PendingBackup? {
        pending.first { $0.id == id }
    }

    func addManualPending(_ item: PendingBackup) {
        pending.insert(item, at: 0)
    }

    func pendingItems() -> [PendingBackup] {
        pending.filter { $0.status == .pending }
    }
}
