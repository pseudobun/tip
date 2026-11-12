import os

enum Log {
    static let app = Logger(subsystem: AppPaths.bundleID, category: "app")
    static let provider = Logger(subsystem: AppPaths.bundleID, category: "provider")
    static let plugin = Logger(subsystem: AppPaths.bundleID, category: "plugin")
}
