import Darwin
import Foundation

/// Трафик через туннель за текущую сессию.
///
/// Xray сам считает байты по каждому outbound (`stats` + `policy.system`), а
/// отдаёт счётчики через встроенный HTTP-эндпоинт `metrics` на 127.0.0.1.
/// Берём только outbound «proxy»: прямой трафик и заблокированное через VPN
/// не ходят и в цифру не входят.
@MainActor
final class SessionTraffic: ObservableObject {
    static let shared = SessionTraffic()

    @Published private(set) var uplink: Int64 = 0
    @Published private(set) var downlink: Int64 = 0

    var total: Int64 { uplink + downlink }

    private var port: Int?
    private var poller: Task<Void, Never>?

    /// Запросы к счётчикам идут мимо системного прокси, который мы сами же
    /// и включили: иначе запрос к 127.0.0.1 мог бы уйти в ядро по кругу.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Свободный локальный порт для эндпоинта счётчиков: занятый порт
    /// уронил бы ядро на старте, а фиксированный может оказаться занят.
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Перед запуском ядра: новая сессия считается с нуля.
    func reset(port: Int?) {
        stop()
        self.port = port
        uplink = 0
        downlink = 0
    }

    func start() {
        guard let port else { return }
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(port: port)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func fillDemo() {
        uplink = 412_000_000
        downlink = 3_870_000_000
    }

    private func poll(port: Int) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/debug/vars"),
              let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = root["stats"] as? [String: Any],
              let outbound = stats["outbound"] as? [String: Any],
              let proxy = outbound["proxy"] as? [String: Any]
        else { return }
        let up = (proxy["uplink"] as? NSNumber)?.int64Value ?? 0
        let down = (proxy["downlink"] as? NSNumber)?.int64Value ?? 0
        // Счётчики ядра только растут; если вдруг пришло меньше — это уже
        // другой процесс ядра, старые цифры не затираем нулями.
        if up >= uplink { uplink = up }
        if down >= downlink { downlink = down }
    }
}
