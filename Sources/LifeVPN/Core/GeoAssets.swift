import Foundation

/// Базы geosite.dat и geoip.dat: по ним ядро понимает, что такое
/// «российский сайт» или «реклама».
///
/// Лежат рядом с конфигом, путь к папке отдаётся ядру через
/// переменную окружения XRAY_LOCATION_ASSET.
enum GeoAssets {

    /// Сборка hydraponique — та же, что используют клиенты с обходом РФ:
    /// в ней есть категории category-ru, whitelist и остальные из пресета.
    static let defaultGeositeURL =
        "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite@202604152235/release/geosite.dat"
    static let defaultGeoipURL =
        "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip@202604160537/release/geoip.dat"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var geosite: URL { Paths.geoDir.appendingPathComponent("geosite.dat") }
    static var geoip: URL { Paths.geoDir.appendingPathComponent("geoip.dat") }

    /// Файл считается годным только если он похож на базу по размеру:
    /// оборвавшаяся закачка иначе выглядит как успешная, а ядро падает.
    private static let minimumSize = 50 * 1024

    static func isValid(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else { return false }
        return size >= minimumSize
    }

    static var isReady: Bool { isValid(geosite) && isValid(geoip) }

    static var lastUpdated: Date? {
        let dates = [geosite, geoip].compactMap { url -> Date? in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        }
        return dates.min()
    }

    static var summary: String {
        guard isReady else { return L.t("не загружены", "not downloaded") }
        let total = [geosite, geoip]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
            .reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .binary)
        guard let date = lastUpdated else { return size }
        return "\(size) · \(Subscription.formatUpdated(date))"
    }

    // MARK: - Загрузка

    /// Обновление при каждом запуске, без оглядки на возраст файлов.
    ///
    /// Базы решают, что пойдёт мимо туннеля, а что через него, и устаревший
    /// список — это молча неверная маршрутизация. Пара сотен килобайт раз
    /// в запуск дешевле, чем разбираться, почему один сайт вдруг поехал не
    /// туда.
    ///
    /// Ошибку показывать некому и незачем: если не обновились, работают
    /// прежние, а сообщение о неудаче человек увидит, когда нажмёт
    /// «Обновить» руками.
    static func refreshOnLaunch(geositeURL: String, geoipURL: String) async {
        try? await download(geositeURL: geositeURL, geoipURL: geoipURL)
    }

    static func download(geositeURL: String, geoipURL: String) async throws {
        try FileManager.default.createDirectory(at: Paths.geoDir, withIntermediateDirectories: true)
        try await fetch(geositeURL, to: geosite, name: "geosite.dat")
        try await fetch(geoipURL, to: geoip, name: "geoip.dat")
    }

    private static func fetch(_ address: String, to destination: URL, name: String) async throws {
        guard let url = URL(string: address) else {
            throw Failure(message: L.t("Неверная ссылка на \(name).", "Bad link for \(name)."))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (temporary, response) = try await session.download(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: L.t("Сервер вернул код \(http.statusCode) на \(name).", "The server returned code \(http.statusCode) for \(name)."))
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let size = (attributes[.size] as? Int) ?? 0
        guard size >= minimumSize else {
            throw Failure(message: L.t("Файл \(name) пришёл обрезанным (\(size) байт).", "File \(name) arrived truncated (\(size) bytes)."))
        }

        // Пишем через временный файл: оборванная замена не должна оставить
        // на месте рабочей базы огрызок, на котором ядро не поднимется.
        let staging = destination.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.moveItem(at: temporary, to: staging)
        _ = try? FileManager.default.replaceItemAt(destination, withItemAt: staging)
    }
}
