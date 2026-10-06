import Foundation

enum AppVersion {
    /// Версия из Info.plist собранного .app; при запуске через `swift run` её нет.
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
