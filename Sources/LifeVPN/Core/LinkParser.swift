import Foundation

/// Разбор share-ссылок. Пока только `vless://`; остальные протоколы
/// добавляются сюда же на этапе 2.
enum LinkParser {

    enum Failure: LocalizedError, Equatable {
        case unsupportedScheme(String)
        case malformed(String)
        case missingUser
        case missingHost
        case missingPort

        var errorDescription: String? {
            switch self {
            case .unsupportedScheme(let scheme):
                return L.t("Протокол \(scheme):// пока не поддерживается.", "The \(scheme):// protocol is not supported yet.")
            case .malformed(let link):
                return L.t("Не удалось разобрать ссылку: \(link.prefix(48))…", "Could not parse the link: \(link.prefix(48))…")
            case .missingUser:   return L.t("В ссылке нет идентификатора пользователя.", "The link has no user id.")
            case .missingHost:   return L.t("В ссылке нет адреса сервера.", "The link has no server address.")
            case .missingPort:   return L.t("В ссылке нет порта.", "The link has no port.")
            }
        }
    }

    /// Разбирает многострочный текст: пустые строки и комментарии пропускает,
    /// нераспознанные строки возвращает отдельным списком, чтобы интерфейс мог
    /// показать, что именно не взлетело.
    static func parseMany(_ text: String) -> (configs: [ProxyConfig], errors: [String]) {
        var configs: [ProxyConfig] = []
        var errors: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            do {
                configs.append(try parse(line))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return (configs, errors)
    }

    static func parse(_ link: String) throws -> ProxyConfig {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = trimmed.split(separator: ":").first.map(String.init)?.lowercased() else {
            throw Failure.malformed(trimmed)
        }
        switch scheme {
        case "vless": return try parseVLESS(trimmed)
        default:      throw Failure.unsupportedScheme(scheme)
        }
    }

    // MARK: - VLESS

    private static func parseVLESS(_ link: String) throws -> ProxyConfig {
        guard let components = URLComponents(string: link) else {
            throw Failure.malformed(link)
        }
        guard let user = components.user, !user.isEmpty else { throw Failure.missingUser }
        guard let host = components.host, !host.isEmpty else { throw Failure.missingHost }
        guard let port = components.port else { throw Failure.missingPort }

        let query = queryDictionary(components)

        var config = ProxyConfig()
        config.kind = .vless
        config.userID = user
        config.address = host
        config.port = port
        config.sourceLink = link
        config.name = components.fragment?.removingPercentEncoding
            ?? components.fragment
            ?? ""

        config.encryption = query["encryption"] ?? "none"
        config.flow = nonEmpty(query["flow"])

        config.security = Security(rawValue: query["security"]?.lowercased() ?? "none") ?? .none
        config.transport = Transport(rawValue: normalizedTransport(query)) ?? .tcp

        config.sni = nonEmpty(query["sni"]) ?? nonEmpty(query["peer"])
        config.fingerprint = nonEmpty(query["fp"])
        config.publicKey = nonEmpty(query["pbk"])
        config.shortID = nonEmpty(query["sid"])
        config.spiderX = nonEmpty(query["spx"])
        config.allowInsecure = ["1", "true"].contains(query["allowInsecure"]?.lowercased() ?? "")
        config.pinnedPeerCertSha256 = nonEmpty(query["pcs"])
        config.verifyPeerCertByName = nonEmpty(query["vcn"])
        if let alpn = nonEmpty(query["alpn"]) {
            config.alpn = alpn.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }

        config.path = nonEmpty(query["path"])
        config.host = nonEmpty(query["host"])
        config.serviceName = nonEmpty(query["serviceName"])
        config.headerType = nonEmpty(query["headerType"])

        if config.transport == .xhttp {
            config.xhttpMode = nonEmpty(query["mode"])
            config.xhttpExtraJSON = nonEmpty(query["extra"])
            // В ссылках параметр приходит в snake_case, в конфиге Xray он xPaddingBytes.
            config.xPaddingBytes = nonEmpty(query["x_padding_bytes"]) ?? nonEmpty(query["xPaddingBytes"])
        }

        return config
    }

    /// `type` — основное имя параметра; `splithttp` — прежнее имя XHTTP,
    /// ссылки со старых панелей всё ещё им пользуются.
    private static func normalizedTransport(_ query: [String: String]) -> String {
        let raw = (query["type"] ?? query["net"] ?? "tcp").lowercased()
        return raw == "splithttp" ? "xhttp" : raw
    }

    private static func queryDictionary(_ components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
