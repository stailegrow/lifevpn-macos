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

    // MARK: - Лимиты

    /// Больше этого тело ответа не читаем: подписка — список ссылок, а не
    /// архив. Проверяем реально полученные байты, а не Content-Length.
    static let maxSubscriptionBytes = 8 * 1024 * 1024
    /// Больше ссылок не принимаем — и не обрезаем список молча: частичное
    /// обновление удалило бы существующие узлы.
    static let maxSubscriptionLinks = 10_000
    /// Сколько перенаправлений допускаем на одну загрузку.
    static let maxRedirects = 5

    static var tooLarge: Failure {
        Failure(message: L.t("Ответ подписки слишком большой (больше 8 МиБ).", "The subscription reply is too large (over 8 MiB)."))
    }
    static var tooManyLinks: Failure {
        Failure(message: L.t("В подписке больше 10 000 ссылок — список не принят, прежние узлы сохранены.",
                             "The subscription holds more than 10,000 links — it was rejected, existing nodes are kept."))
    }

    struct BoundedBody {
        private(set) var data = Data()
        let limit: Int
        init(limit: Int = SubscriptionFetcher.maxSubscriptionBytes) { self.limit = limit }
        mutating func append(_ byte: UInt8) throws {
            guard data.count < limit else { throw SubscriptionFetcher.tooLarge }
            data.append(byte)
        }
    }

    // MARK: - Загрузка

    /// Подписка принимается только по HTTPS: по голому http список узлов
    /// может подменить любой на пути соединения. С 3.1.5 это касается и
    /// адресов локальной сети — исключений нет.
    static func isSecureSubscriptionURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    static func fetch(_ urlString: String, timeout: TimeInterval = 20) async throws -> Payload {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw Failure(message: L.t("Это не похоже на ссылку подписки.", "This does not look like a subscription link."))
        }
        guard isSecureSubscriptionURL(url) else {
            throw Failure(message: L.t("Ссылка подписки начинается с http:// — по такой ссылке список узлов можно подменить по дороге. Нужна https-ссылка; прежние узлы сохранены.",
                                       "The subscription link uses http:// — the node list could be tampered with on the way. An https link is required; existing nodes are kept."))
        }

        var lastFailure: Failure?

        for agent in userAgents {
            try Task.checkCancellation()
            do {
                let payload = try await load(url, userAgent: agent, timeout: timeout)
                if !payload.links.isEmpty { return payload }
                lastFailure = Failure(message: L.t("Подписка ответила, но ни одной ссылки в ответе нет.", "The subscription answered, but the reply holds no links."))
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as Failure {
                lastFailure = failure
                // Превышение лимитов от смены User-Agent не исчезнет.
                if failure.message == tooLarge.message || failure.message == tooManyLinks.message { break }
            } catch {
                lastFailure = Failure(message: error.localizedDescription)
            }
        }

        throw lastFailure ?? Failure(message: L.t("Не удалось загрузить подписку.", "Could not load the subscription."))
    }

    /// Каждое перенаправление проверяется ДО отправки запроса: HTTPS → HTTP
    /// и бесконечные цепочки отклоняются, HTTPS-CDN на другом домене — нет.
    final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var redirects = 0
        private var rejection: Failure?

        var rejected: Failure? { lock.lock(); defer { lock.unlock() }; return rejection }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock()
            redirects += 1
            let count = redirects
            var verdict: Failure?
            if let url = request.url, SubscriptionFetcher.isSecureSubscriptionURL(url) {
                if count > SubscriptionFetcher.maxRedirects {
                    verdict = Failure(message: L.t("Слишком много перенаправлений при загрузке подписки.", "Too many redirects while loading the subscription."))
                }
            } else {
                verdict = Failure(message: L.t("Сервер подписки перенаправил на незащищённый адрес — запрос остановлен.", "The subscription server redirected to an insecure address — the request was stopped."))
            }
            if let verdict { rejection = verdict }
            lock.unlock()
            if verdict != nil {
                completionHandler(nil)
                task.cancel()
            } else {
                completionHandler(request)
            }
        }
    }

    private static func load(_ url: URL, userAgent: String, timeout: TimeInterval) async throws -> Payload {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Общий срок на всю загрузку вместе с перенаправлениями — не
        // обнуляется на каждом шаге цепочки.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        let delegate = SecureRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if let rejected = delegate.rejected { throw rejected }
            throw error
        }
        if let rejected = delegate.rejected { throw rejected }

        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: L.t("Сервер ответил не по HTTP.", "The server replied over something other than HTTP."))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(message: L.t("Сервер подписки ответил кодом \(http.statusCode).", "The subscription server replied with code \(http.statusCode)."))
        }
        // Байты уже распакованы URLSession — лимит считается по тому, что
        // реально попадёт в декодер.
        var bounded = BoundedBody()
        for try await byte in bytes { try bounded.append(byte) }
        guard let body = String(data: bounded.data, encoding: .utf8) else {
            throw Failure(message: L.t("Ответ подписки не читается как текст.", "The subscription reply is not readable as text."))
        }

        var payload = Payload()
        payload.links = try decodeBody(body)
        payload.title = header(http, "profile-title").flatMap(decodeHeaderValue)
        payload.announce = header(http, "announce").flatMap(decodeHeaderValue)
        if let info = header(http, "subscription-userinfo") {
            payload.rawUserInfo = info
            payload.userInfo = parseUserInfo(info)
        }
        if let value = header(http, "profile-update-interval") {
            payload.updateIntervalHours = parseUpdateIntervalHours(value)
        }
        return payload
    }

    /// Заголовок задаёт интервал в днях; храним в часах. Принимаем только
    /// положительное конечное значение, которое переводится в секунды без
    /// переполнения — Infinity не должен попасть ни в JSON, ни в таймер.
    static func parseUpdateIntervalHours(_ value: String) -> Double? {
        guard let days = Double(value.trimmingCharacters(in: .whitespaces)), days.isFinite, days > 0 else { return nil }
        let hours = days * 24
        let seconds = hours * 3600
        guard hours.isFinite, seconds.isFinite, seconds < Double(Int32.max) else { return nil }
        return hours
    }

    private static func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        let value = response.value(forHTTPHeaderField: name)
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    // MARK: - Разбор тела

    /// Возвращает строки-ссылки. Тело может быть простым текстом либо base64 —
    /// в том числе url-safe и без выравнивания.
    static func decodeBody(_ body: String) throws -> [String] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains("://") {
            return try links(in: trimmed)
        }
        if let decoded = decodeBase64(trimmed) {
            return try links(in: decoded)
        }
        return []
    }

    /// Строки разбираются по одной, без промежуточного массива всех строк:
    /// миллион пустых разделителей не превращается в миллион элементов.
    /// Переносы — любые, которые Swift считает переводом строки (CR, LF,
    /// CRLF и Unicode-переносы), порядок и дубликаты сохраняются.
    static func links(in text: String) throws -> [String] {
        var result: [String] = []
        var start = text.startIndex
        func appendLine(_ line: Substring) throws {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#"), value.contains("://") else { return }
            guard result.count < maxSubscriptionLinks else { throw tooManyLinks }
            result.append(value)
        }
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isNewline {
                try appendLine(text[start..<index])
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        try appendLine(text[start..<text.endIndex])
        return result
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
    ///
    /// Каждое число — неотрицательное Int64; иначе показатель неизвестен.
    /// Испорченное поле не превращается в ноль и не портит остальные.
    static func parseUserInfo(_ value: String) -> UserInfo {
        var fields: [String: Int64] = [:]
        var invalid: Set<String> = []
        for pair in value.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
            if let number = Int64(raw), number >= 0 {
                fields[key] = number
                invalid.remove(key)
            } else {
                fields[key] = nil
                invalid.insert(key)
            }
        }

        var info = UserInfo()
        let mentionsUsage = fields["upload"] != nil || fields["download"] != nil
            || invalid.contains("upload") || invalid.contains("download")
        // Если одно из явно переданных полей испорчено, сумма из второго
        // была бы ложным частичным итогом — оставляем «неизвестно».
        if mentionsUsage, !invalid.contains("upload"), !invalid.contains("download") {
            let (sum, overflow) = (fields["upload"] ?? 0).addingReportingOverflow(fields["download"] ?? 0)
            if !overflow { info.used = sum }
        }
        info.total = fields["total"]
        // expire=0 у панелей означает «бессрочно», а не 1970 год. Даты
        // дальше 9999 года считаем ошибкой панели, а не сроком.
        if let expire = fields["expire"], expire > 0, expire <= 253_402_300_799 {
            info.expiresAt = Date(timeIntervalSince1970: TimeInterval(expire))
        }
        return info
    }
}
