import AppKit
import UniformTypeIdentifiers
import Foundation

/// Журнал маршрутизации: куда ушло каждое соединение — в туннель, напрямую
/// или в блок.
///
/// Источник — access-лог самого Xray. Ядро пишет в него строку на каждое
/// принятое соединение, а мы раз в секунду дочитываем только новые байты:
/// перечитывать файл целиком при каждом опросе — лишняя работа на долгой
/// сессии. Файл обнуляется при каждом подключении и не растёт бесконечно.
@MainActor
final class RoutingLog: ObservableObject {
    static let shared = RoutingLog()

    struct Entry: Identifiable, Hashable, Sendable {
        let id: Int
        let time: String
        let network: String
        let host: String
        let port: String
        let inbound: String
        let route: Route
        /// Правило не совпало — ушло по умолчанию (в Xray это `>>`).
        let byDefault: Bool
    }

    enum Route: String, CaseIterable, Sendable {
        case proxy, direct, block, other

        init(tag: String) {
            switch tag {
            case "proxy":  self = .proxy
            case "direct": self = .direct
            case "block":  self = .block
            default:       self = .other
            }
        }

        var title: String {
            switch self {
            case .proxy:  return L.t("Туннель", "Tunnel")
            case .direct: return L.t("Напрямую", "Direct")
            case .block:  return L.t("Блок", "Blocked")
            case .other:  return L.t("Другое", "Other")
            }
        }
    }

    /// Последние записи для окна — новые сверху.
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var counts: [Route: Int] = [:]

    private static let shownLimit = 400
    /// Выше этого размера файл обнуляется: журнал нужен, чтобы видеть
    /// текущие маршруты, а не хранить историю за недели.
    private static let fileLimit: UInt64 = 8 * 1024 * 1024

    private var offset: UInt64 = 0
    private var pending = Data()
    private var nextID = 0
    private var poller: Task<Void, Never>?

    private init() {}

    // MARK: - Жизненный цикл

    /// Перед запуском ядра: старый журнал к новой сессии отношения не имеет.
    func reset() {
        end()
        try? FileManager.default.removeItem(at: Paths.accessLog)
        offset = 0
        pending.removeAll()
        entries = []
        counts = [:]
    }

    func begin() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func end() {
        poller?.cancel()
        poller = nil
    }

    // MARK: - Чтение

    private func poll() {
        let url = Paths.accessLog
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; pending.removeAll() }   // файл обнулили
        if size > Self.fileLimit {
            // Ядро пишет в режиме дозаписи, поэтому обрезка безопасна:
            // следующая строка просто ляжет в начало пустого файла.
            if let writer = try? FileHandle(forWritingTo: url) {
                try? writer.truncate(atOffset: 0)
                try? writer.close()
            }
            offset = 0
            pending.removeAll()
            return
        }
        guard size > offset else { return }

        try? handle.seek(toOffset: offset)
        let chunk = handle.readData(ofLength: Int(min(size - offset, 1024 * 1024)))
        offset += UInt64(chunk.count)
        pending.append(chunk)

        guard let lastNewline = pending.lastIndex(of: 0x0A) else { return }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])

        let text = String(decoding: complete, as: UTF8.self)
        var fresh: [Entry] = []
        for line in text.split(separator: "\n") {
            if let entry = parse(line) { fresh.append(entry) }
        }
        append(fresh)
    }

    private func append(_ fresh: [Entry]) {
        guard !fresh.isEmpty else { return }
        for entry in fresh { counts[entry.route, default: 0] += 1 }
        var merged = Array(fresh.reversed()) + entries
        if merged.count > Self.shownLimit { merged.removeLast(merged.count - Self.shownLimit) }
        entries = merged
    }

    /// `2026/10/23 06:39:53.219282 from tcp:127.0.0.1:42840 accepted tcp:github.com:443 [socks -> direct]`
    ///
    /// HTTP-прокси пишет адрес как `//host:port`, служебные запросы DNS
    /// самого ядра (`from DNS`) в журнал не попадают — к трафику
    /// пользователя они отношения не имеют.
    private func parse(_ line: Substring) -> Entry? {
        guard let acceptedRange = line.range(of: " accepted "),
              let open = line.range(of: " [", range: acceptedRange.upperBound..<line.endIndex),
              let close = line.range(of: "]", range: open.upperBound..<line.endIndex)
        else { return nil }

        let head = line[..<acceptedRange.lowerBound]
        if head.contains(" from DNS") { return nil }
        let headParts = head.split(separator: " ")
        let time = headParts.count > 1 ? String(headParts[1].prefix(8)) : ""

        var target = line[acceptedRange.upperBound..<open.lowerBound]
        var network = "tcp"
        if target.hasPrefix("//") {
            target = target.dropFirst(2)
        } else if target.hasPrefix("tcp:") || target.hasPrefix("udp:") {
            network = String(target.prefix(3))
            target = target.dropFirst(4)
        }
        guard let colon = target.lastIndex(of: ":") else { return nil }
        var host = String(target[..<colon])
        let port = String(target[target.index(after: colon)...])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }

        let detour = line[open.upperBound..<close.lowerBound]
        let byDefault = detour.contains(" >> ")
        let sides = detour.components(separatedBy: byDefault ? " >> " : " -> ")
        guard sides.count == 2 else { return nil }

        nextID += 1
        return Entry(id: nextID, time: time, network: network.uppercased(),
                     host: host, port: port, inbound: sides[0],
                     route: Route(tag: sides[1].trimmingCharacters(in: .whitespaces)),
                     byDefault: byDefault)
    }

    // MARK: - Выгрузка

    /// Сохраняет весь журнал текущей сессии в .txt — не только то, что
    /// помещается в окне.
    func export() {
        poll()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm"
        panel.nameFieldStringValue = "LifeVPN-routing-\(stamp.string(from: Date())).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report().write(to: url, atomically: true, encoding: .utf8)
    }

    private func report() -> String {
        var all: [Entry] = []
        if let data = try? Data(contentsOf: Paths.accessLog) {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if let entry = parse(line) { all.append(entry) }
            }
        }
        if all.isEmpty { all = Array(entries.reversed()) }

        let date = DateFormatter()
        date.dateFormat = "dd.MM.yyyy HH:mm"
        var lines = [
            "Life VPN — журнал маршрутизации",
            "Выгружен: \(date.string(from: Date()))",
            "Соединений: \(all.count)  ·  "
                + Route.allCases.compactMap { route -> String? in
                    let n = all.filter { $0.route == route }.count
                    return n > 0 ? "\(route.title): \(n)" : nil
                }.joined(separator: "  ·  "),
            "",
            "Время     Сеть  Маршрут    Правило      Адрес"
        ]
        for e in all {
            let route = e.route.title.padding(toLength: 10, withPad: " ", startingAt: 0)
            let rule = (e.byDefault ? "по умолч." : "правило").padding(toLength: 12, withPad: " ", startingAt: 0)
            lines.append("\(e.time)  \(e.network)   \(route) \(rule) \(e.host):\(e.port)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Демо

    func fillDemo() {
        guard DemoMode.isOn else { return }
        let sample: [(String, String, Route)] = [
            ("www.youtube.com", "443", .proxy), ("yandex.ru", "443", .direct),
            ("ads.example.net", "443", .block), ("github.com", "443", .proxy),
            ("mail.example.com", "443", .direct), ("www.google.com", "443", .proxy),
            ("vk.com", "443", .direct), ("api.telegram.org", "443", .proxy)
        ]
        reset()
        var fresh: [Entry] = []
        for (index, item) in sample.enumerated() {
            nextID += 1
            fresh.append(Entry(id: nextID, time: String(format: "12:%02d:%02d", 30 + index / 3, index * 7 % 60),
                               network: "TCP", host: item.0, port: item.1, inbound: "socks",
                               route: item.2, byDefault: item.2 == .proxy))
        }
        append(fresh)
    }
}
