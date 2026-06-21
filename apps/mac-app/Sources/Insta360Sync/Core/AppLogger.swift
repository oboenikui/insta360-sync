import Foundation
import os

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let logger = Logger(subsystem: "com.oboenikui.insta360-sync", category: "app")

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
