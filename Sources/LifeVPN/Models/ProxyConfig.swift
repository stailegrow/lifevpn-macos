import Foundation

enum ProxyProtocol: String, Codable, Sendable, CaseIterable {
    case vless
}

enum Security: String, Codable, Sendable {
    case none
    case tls
    case reality
}

enum Transport: String, Codable, Sendable {
    case tcp
    case ws
    case grpc
    case http
    case xhttp
    case httpupgrade

    /// Имя ключа настроек транспорта в конфиге Xray.
    var settingsKey: String? {
        switch self {
        case .tcp:         return nil
        case .ws:          return "wsSettings"
        case .grpc:        return "grpcSettings"
        case .http:        return "httpSettings"
        case .xhttp:       return "xhttpSettings"
        case .httpupgrade: return "httpupgradeSettings"
        }
    }
}

/// Один сервер. Плоская структура — так проще сериализовать и сравнивать.
struct ProxyConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var kind: ProxyProtocol = .vless

    var address: String = ""
    var port: Int = 443
    var userID: String = ""
    var encryption: String = "none"
    var flow: String?

    var security: Security = .none
    var transport: Transport = .tcp

    // TLS и Reality
    var sni: String?
    var fingerprint: String?
    var publicKey: String?
    var shortID: String?
    var spiderX: String?
    var alpn: [String] = []
    /// Флаг из ссылки. В ядре с 26.9 параметр удалён: вместо «не проверять
    /// сертификат» сертификат теперь закрепляют — см. два поля ниже. Флаг
    /// храним только чтобы не терять его при разборе старых ссылок.
    var allowInsecure: Bool = false
    /// SHA-256 сертификата сервера (параметр ссылки `pcs`).
    var pinnedPeerCertSha256: String?
    /// Имя, по которому проверять сертификат (параметр ссылки `vcn`).
    var verifyPeerCertByName: String?

    // Транспорт
    var path: String?
    var host: String?
    var serviceName: String?
    var headerType: String?

    // XHTTP
    var xhttpMode: String?
    /// Сырой JSON из параметра `extra`. Хранится строкой, чтобы модель осталась
    /// Codable: при сборке конфига он разбирается и вливается в xhttpSettings.
    var xhttpExtraJSON: String?
    var xPaddingBytes: String?

    /// Ссылка-исходник — пригодится для показа QR и для отладки.
    var sourceLink: String?

    /// К какой подписке относится сервер. nil — добавлен вручную.
    var subscriptionID: UUID?

    /// Ключ, по которому сервер узнаётся при обновлении подписки. Имя в него
    /// не входит намеренно: переименование на панели не должно выглядеть как
    /// удаление старого сервера и появление нового.
    var identityKey: String {
        "\(kind.rawValue)|\(address)|\(port)|\(userID)|\(transport.rawValue)|\(path ?? "")"
    }

    var displayName: String {
        name.isEmpty ? "\(address):\(port)" : name
    }

    /// Короткое описание транспорта для интерфейса: "reality · xhttp".
    var summary: String {
        var parts: [String] = []
        if security != .none { parts.append(security.rawValue) }
        parts.append(transport.rawValue)
        if let flow, !flow.isEmpty { parts.append(flow) }
        if transport == .xhttp, let xhttpMode, !xhttpMode.isEmpty { parts.append(xhttpMode) }
        return parts.joined(separator: " · ")
    }
}
