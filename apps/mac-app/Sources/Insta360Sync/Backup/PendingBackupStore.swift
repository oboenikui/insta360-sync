import Foundation

@MainActor
final class PendingBackupStore {
    private(set) var pending: [PendingBackup] = []
    private var recentlyNotified: [UUID: Date] = [:]
    private let cooldown: TimeInterval = 300

    /// 承認済みまたは実行中のバックアップがあるか（カメラ AP 占有中）。
    var hasActiveBackup: Bool {
        pending.contains { $0.status == .approved || $0.status == .running }
    }

    /// 新規の検知 pending を作成する。既存の未完了アイテムがある場合やクールダウン中は `nil`。
    func createPending(for camera: CameraProfile) -> PendingBackup? {
        if pending.contains(where: {
            $0.cameraID == camera.id && ($0.status == .pending || $0.status == .approved || $0.status == .running)
        }) {
            // 既存を返すと呼び出し側が再通知してしまうため、新規作成時のみ非 nil を返す。
            return nil
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
        recentlyNotified[item.cameraID] = Date()
    }

    /// 同期完了直後の再検知 Push を抑止するため、クールダウンを延長する。
    func suppressDetection(for cameraID: UUID) {
        recentlyNotified[cameraID] = Date()
    }

    /// Wi-Fi が検出されなくなったカメラの承認待ちを消し、再出現時に再検知できるようにする。
    func clearPending(forAbsentCameraIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removedCameraIDs = Set(
            pending
                .filter { $0.status == .pending && ids.contains($0.cameraID) }
                .map(\.cameraID)
        )
        guard !removedCameraIDs.isEmpty else { return }
        pending.removeAll { $0.status == .pending && removedCameraIDs.contains($0.cameraID) }
        for cameraID in removedCameraIDs {
            recentlyNotified.removeValue(forKey: cameraID)
        }
        AppLogger.shared.info(
            "Cleared \(removedCameraIDs.count) pending backup(s) for cameras no longer on Wi-Fi"
        )
    }

    func pendingItems() -> [PendingBackup] {
        pending.filter { $0.status == .pending }
    }
}
