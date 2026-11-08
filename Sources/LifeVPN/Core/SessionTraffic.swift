import Darwin
import Foundation

/// Трафик через туннель за текущую сессию.
///
/// Xray сам считает байты по каждому outbound (`stats` + `policy.system`).
/// Отдельного порта для счётчиков ядро не открывает (его видели бы все
/// программы на компьютере): запрос идёт через наш же HTTP-прокси на
/// служебное имя `XrayConfigBuilder.metricsHost`, и ядро пускает к нему
/// только процесс самой Life VPN. Берём только outbound «proxy»: прямой
/// трафик и заблокированное через VPN не ходят и в цифру не входят.
@MainActor
final class SessionTraffic: ObservableObject {
    static let shared = SessionTraffic()

    @Published private(set) var uplink: Int64 = 0
    @Published private(set) var downlink: Int64 = 0

    var total: Int64 { uplink + downlink }

    private var port: Int?
    private var poller: Task<Void, Never>?
    private var session: URLSession?

    private init() {}

    /// Сессия строго через HTTP-прокси ядра на заданном порту.
    private static func makeSession(proxyPort: Int) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
        ]
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }

    /// Перед запуском ядра: новая сессия считается с нуля.
    /// `port` — HTTP-прокси ядра.
    func reset(port: Int?) {
        stop()
        self.port = port
        session?.invalidateAndCancel()
        session = port.map { Self.makeSession(proxyPort: $0) }
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
        guard let session,
              let url = URL(string: "http://\(XrayConfigBuilder.metricsHost)/debug/vars"),
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
