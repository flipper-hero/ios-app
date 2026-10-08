import Foundation
import os

/// Unified logging. Debug builds also print, so `devicectl device process launch --console`
/// shows the messages while testing against real hardware.
enum AppLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlipperHero", category: "app")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        #if DEBUG
        print("[App] \(message)")
        #endif
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        #if DEBUG
        print("[App] error: \(message)")
        #endif
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        #if DEBUG
        print("[FK] \(message)")
        #endif
    }
}
