import Foundation

/// Проверка внешнего IP через локальный HTTP-прокси ядра.
///
/// Ходим именно через прокси, а не через системные настройки: так проверка
/// отвечает на вопрос «работает ли туннель», не завися от того, применились
/// системные настройки или нет.
enum IPChecker {

    private static let endpoints = [
        URL(string: "https://api.ipify.org")!,
        URL(string: "https://ipinfo.io/ip")!,
        URL(string: "https://ifconfig.me/ip")!
    ]

    static func externalIP(viaHTTPProxyPort port: Int, timeout: TimeInterval = 8) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: port
        ]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for endpoint in endpoints {
            guard let value = try? await fetch(endpoint, session: session) else { continue }
            if isPlausibleIP(value) { return value }
        }
        return nil
    }

    /// Внешний IP без прокси — чтобы было с чем сравнить.
    static func directExternalIP(timeout: TimeInterval = 8) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for endpoint in endpoints {
            guard let value = try? await fetch(endpoint, session: session) else { continue }
            if isPlausibleIP(value) { return value }
        }
        return nil
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> String {
        let (data, _) = try await session.data(from: url)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func isPlausibleIP(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 45 else { return false }
        if value.contains(":") { return true }                       // IPv6
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }
}
