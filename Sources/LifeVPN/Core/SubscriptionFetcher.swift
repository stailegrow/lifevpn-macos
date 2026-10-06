import Foundation

/// Загрузка и разбор подписки.
///
/// Панели отдают список по-разному: то простым текстом, то base64 целиком,
/// то url-safe base64 без выравнивания. Плюс часть панелей смотрит на
/// User-Agent и для незнакомого клиента подсовывает формат другого клиента —
/// поэтому при пустом результате пробуем ещё раз под известным агентом.
enum SubscriptionFetcher {

    struct UserInfo: Sendable, Equatable {
        var used: Int64?
        var total: Int64?
        var expiresAt: Date?
    }

    struct Payload: Sendable {
        var links: [String] = []
        var title: String?
        var announce: String?
        var updateIntervalHours: Double?
        var userInfo = UserInfo()
        /// Исходная строка заголовка — для диагностики расхождений с панелью.
        var rawUserInfo: String?
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Часть панелей отвечает заголовком subscription-userinfo только
    /// знакомым клиентам, а незнакомым отдаёт голый список ссылок. Поэтому
    /// сначала представляемся собой, а если счётчик трафика не пришёл —
    /// повторяем запрос с распространёнными строками.
    private static let userAgents = [
        "LifeVPN/\(AppVersion.short)",
        "v2rayNG/1.9.5",
        "Happ/1.0"
    ]

    // MARK: - Загрузка

    static func fetch(_ urlString: String, timeout: TimeInterval = 20) async throws -> Payload {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw Failure(message: L.t("Это не похоже на ссылку подписки.", "This does not look like a subscription link."))
        }

        var lastFailure: Failure?

        for agent in userAgents {
            do {
                let payload = try await load(url, userAgent: agent, timeout: timeout)
                if !payload.links.isEmpty { return payload }
                lastFailure = Failure(message: L.t("Подписка ответила, но ни одной ссылки в ответе нет.", "The subscription answered, but the reply holds no links."))
            } catch let failure as Failure {
                lastFailure = failure
            } catch {
                lastFailure = Failure(message: error.localizedDescription)
            }
        }

        throw lastFailure ?? Failure(message: L.t("Не удалось загрузить подписку.", "Could not load the subscription."))
    }

    private static func load(_ url: URL, userAgent: String, timeout: TimeInterval) async throws -> Payload {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: L.t("Сервер ответил не по HTTP.", "The server replied over something other than HTTP."))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(message: L.t("Сервер подписки ответил кодом \(http.statusCode).", "The subscription server replied with code \(http.statusCode)."))
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw Failure(message: L.t("Ответ подписки не читается как текст.", "The subscription reply is not readable as text."))
        }

        var payload = Payload()
        payload.links = decodeBody(body)
        payload.title = header(http, "profile-title").flatMap(decodeHeaderValue)
        payload.announce = header(http, "announce").flatMap(decodeHeaderValue)
        if let info = header(http, "subscription-userinfo") {
            payload.rawUserInfo = info
            payload.userInfo = parseUserInfo(info)
        }
        if let days = header(http, "profile-update-interval").flatMap(Double.init), days > 0 {
            payload.updateIntervalHours = days * 24
        }
        return payload
    }

    private static func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        let value = response.value(forHTTPHeaderField: name)
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    // MARK: - Разбор тела

    /// Возвращает строки-ссылки. Тело может быть простым текстом либо base64 —
    /// в том числе url-safe и без выравнивания.
    static func decodeBody(_ body: String) -> [String] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains("://") {
            return links(in: trimmed)
        }
        if let decoded = decodeBase64(trimmed) {
            return links(in: decoded)
        }
        return []
    }

    private static func links(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.contains("://") }
    }

    static func decodeBase64(_ value: String) -> String? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .filter { !$0.isWhitespace }

        // Выравнивание до кратности четырём — многие панели его срезают.
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Заголовки с не-ASCII панели присылают как `base64:<...>`.
    static func decodeHeaderValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("base64:") {
            let payload = String(trimmed.dropFirst("base64:".count))
            return decodeBase64(payload) ?? payload
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `upload=1; download=2; total=3; expire=1767225600`
    static func parseUserInfo(_ value: String) -> UserInfo {
        var fields: [String: Int64] = [:]
        for pair in value.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
            if let number = Int64(raw) { fields[key] = number }
        }

        var info = UserInfo()
        let upload = fields["upload"] ?? 0
        let download = fields["download"] ?? 0
        if fields["upload"] != nil || fields["download"] != nil {
            info.used = upload + download
        }
        info.total = fields["total"]
        // expire=0 у панелей означает «бессрочно», а не 1970 год.
        if let expire = fields["expire"], expire > 0 {
            info.expiresAt = Date(timeIntervalSince1970: TimeInterval(expire))
        }
        return info
    }
}
