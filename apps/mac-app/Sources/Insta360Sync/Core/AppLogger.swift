import Foundation
import os

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    /// Console.app で `subsystem:com.oboenikui.insta360-sync` またはカテゴリで絞り込める。
    static let subsystem = "com.oboenikui.insta360-sync"

    enum Category: String, Sendable {
        case app
        case server
        case push
    }

    private let loggers: [Category: Logger]

    private init() {
        loggers = Dictionary(uniqueKeysWithValues: Category.allCases.map { category in
            (category, Logger(subsystem: Self.subsystem, category: category.rawValue))
        })
    }

    func info(_ message: String, category: Category = .app) {
        loggers[category]?.info("\(message, privacy: .public)")
    }

    func warning(_ message: String, category: Category = .app) {
        loggers[category]?.warning("\(message, privacy: .public)")
    }

    func error(_ message: String, category: Category = .app) {
        loggers[category]?.error("\(message, privacy: .public)")
    }

    func debug(_ message: String, category: Category = .app) {
        loggers[category]?.debug("\(message, privacy: .public)")
    }
}

extension AppLogger.Category: CaseIterable {}
