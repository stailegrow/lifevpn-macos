import Foundation

/// Сборка config.json для Xray-core.
///
/// Строим дерево словарей и сериализуем через JSONSerialization: конфиг Xray
/// разнородный, а параметр `extra` у XHTTP вообще произвольный JSON, который
/// надо влить в настройки транспорта как есть.
enum XrayConfigBuilder {

    struct Options: Sendable {
        var socksPort: Int = 10808
        var httpPort: Int = 10809
        var logLevel: String = "warning"
        var logPath: String?
        var routing: RoutingConfig = RoutingPreset.global.make()

        init(socksPort: Int = 10808, httpPort: Int = 10809,
             logLevel: String = "warning", logPath: String? = nil,
             routing: RoutingConfig = RoutingPreset.global.make()) {
            self.socksPort = socksPort
            self.httpPort = httpPort
            self.logLevel = logLevel
            self.logPath = logPath
            self.routing = routing
        }
    }

    static func makeJSON(for config: ProxyConfig, options: Options) throws -> Data {
        let root = makeTree(for: config, options: options)
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Дерево конфига

    static func makeTree(for config: ProxyConfig, options: Options) -> [String: Any] {
        var log: [String: Any] = ["loglevel": options.logLevel]
        if let path = options.logPath {
            log["error"] = path
        }

        var root: [String: Any] = [
            "log": log,
            "inbounds": inbounds(options),
            "outbounds": [outbound(for: config), directOutbound(), blockOutbound()],
            "routing": routing(options.routing)
        ]
        if let dns = dns(options.routing) {
            root["dns"] = dns
        }
        return root
    }

    private static func inbounds(_ options: Options) -> [[String: Any]] {
        let sniffing: [String: Any] = [
            "enabled": true,
            "destOverride": ["http", "tls", "quic"],
            // Без этого доменные правила роутинга не увидят имя хоста,
            // когда приложение уже само разрешило его в IP.
            "routeOnly": false
        ]
        return [
            [
                "tag": "socks",
                "listen": "127.0.0.1",
                "port": options.socksPort,
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": true],
                "sniffing": sniffing
            ],
            [
                "tag": "http",
                "listen": "127.0.0.1",
                "port": options.httpPort,
                "protocol": "http",
                "settings": [:] as [String: Any],
                "sniffing": sniffing
            ]
        ]
    }

    /// Стратегия резолва — в sockopt: в самом freedom она устарела с ядра 26.9,
    /// а sockopt понимают и прежние версии.
    private static func directOutbound() -> [String: Any] {
        ["tag": "direct", "protocol": "freedom",
         "settings": [:] as [String: Any],
         "streamSettings": ["sockopt": ["domainStrategy": "UseIP"]]]
    }

    private static func blockOutbound() -> [String: Any] {
        ["tag": "block", "protocol": "blackhole", "settings": [:] as [String: Any]]
    }

    /// Локальные адреса идут мимо туннеля.
    ///
    /// Диапазоны перечислены явно, а не через `geoip:private`: за именами
    /// geoip-групп ядро лезет в geoip.dat, и без базы падает при старте.
    /// Эти девять строк работают всегда и ни от чего не зависят.
    static let privateRanges = [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "100.64.0.0/10",
        "::1/128",
        "fc00::/7",
        "fe80::/10"
    ]

    /// Порядок правил — block, затем proxy, затем direct.
    ///
    /// Он важен: правила проверяются сверху вниз, и первое совпавшее
    /// побеждает. Реклама должна отсекаться раньше, чем сработает
    /// «весь российский трафик напрямую», иначе она поедет мимо фильтра.
    /// Всё, что не совпало ни с чем, уходит в первый outbound — то есть
    /// в туннель.
    static func routing(_ config: RoutingConfig) -> [String: Any] {
        var rules: [[String: Any]] = []

        // QUIC мимо туннеля не ходит. Наш канал всегда поверх TCP, а
        // ретрансляция UDP-443 через него ненадёжна: часть приложений и
        // игровых движков при подвисшем QUIC не откатывается на TCP сама и
        // просто зависает. Блокируем явно и первым правилом — почти все
        // клиенты после отказа спокойно уходят на HTTP/2 поверх TCP.
        rules.append(["type": "field", "network": "udp", "port": "443", "outboundTag": "block"])

        // Локальная сеть — мимо туннеля и следующим правилом.
        if config.bypassLAN {
            rules.append(["type": "field", "ip": privateRanges, "outboundTag": "direct"])
        }

        append(&rules, domains: config.blockSites, ips: config.blockIP, tag: "block")
        // Свои домены — раньше правил «через туннель»: список задан руками
        // и должен побеждать любые общие категории.
        append(&rules, domains: config.effectiveDirectDomains, ips: [], tag: "direct")
        append(&rules, domains: config.proxySites, ips: config.proxyIP, tag: "proxy")
        append(&rules, domains: config.directSites, ips: config.directIP, tag: "direct")

        return [
            "domainStrategy": config.domainStrategy,
            "rules": rules
        ]
    }

    private static func append(_ rules: inout [[String: Any]],
                               domains: [String],
                               ips: [String],
                               tag: String) {
        if !domains.isEmpty {
            rules.append(["type": "field", "domain": domains, "outboundTag": tag])
        }
        if !ips.isEmpty {
            rules.append(["type": "field", "ip": ips, "outboundTag": tag])
        }
    }

    /// Домены из списка «напрямую» резолвим местным DNS, остальные — удалённым.
    ///
    /// Без этого обход РФ работает наполовину: имя российского сайта уходит
    /// на зарубежный резолвер, тот отдаёт чужой адрес ближайшего узла CDN,
    /// и сайт открывается через туннель вопреки правилу.
    static func dns(_ config: RoutingConfig) -> [String: Any]? {
        guard !config.remoteDNS.isEmpty || !config.domesticDNS.isEmpty
                || !config.effectiveDirectDomains.isEmpty else { return nil }

        var servers: [Any] = []
        // Свои домены резолвит система: внутреннее имя знает только
        // корпоративный резолвер, публичные о нём не слышали.
        let localDomains = config.effectiveDirectDomains
        if !localDomains.isEmpty {
            servers.append([
                "address": "localhost",
                "domains": localDomains,
                "skipFallback": true
            ] as [String: Any])
        }
        if !config.domesticDNS.isEmpty, !config.directSites.isEmpty {
            servers.append([
                "address": config.domesticDNS,
                "domains": config.directSites,
                "skipFallback": true
            ] as [String: Any])
        }
        if !config.remoteDNS.isEmpty {
            servers.append(config.remoteDNS)
        }
        guard !servers.isEmpty else { return nil }

        var dns: [String: Any] = ["servers": servers]
        if !config.dnsHosts.isEmpty {
            dns["hosts"] = config.dnsHosts
        }
        return dns
    }

    // MARK: - Исходящее соединение

    static func outbound(for config: ProxyConfig) -> [String: Any] {
        var user: [String: Any] = [
            "id": config.userID,
            "encryption": config.encryption
        ]
        // Vision работает только поверх TCP; на XHTTP его быть не должно.
        if let flow = config.flow, !flow.isEmpty, config.transport == .tcp {
            user["flow"] = flow
        }

        let vnext: [String: Any] = [
            "address": config.address,
            "port": config.port,
            "users": [user]
        ]

        return [
            "tag": "proxy",
            "protocol": config.kind.rawValue,
            "settings": ["vnext": [vnext]],
            "streamSettings": streamSettings(for: config)
        ]
    }

    static func streamSettings(for config: ProxyConfig) -> [String: Any] {
        var stream: [String: Any] = [
            "network": config.transport.rawValue,
            "security": config.security == .none ? "none" : config.security.rawValue
        ]

        switch config.security {
        case .reality:
            stream["realitySettings"] = realitySettings(for: config)
        case .tls:
            stream["tlsSettings"] = tlsSettings(for: config)
        case .none:
            break
        }

        if let key = config.transport.settingsKey {
            stream[key] = transportSettings(for: config)
        }

        return stream
    }

    private static func realitySettings(for config: ProxyConfig) -> [String: Any] {
        var reality: [String: Any] = ["show": false]
        if let sni = config.sni { reality["serverName"] = sni }
        if let fp = config.fingerprint { reality["fingerprint"] = fp }
        if let pbk = config.publicKey { reality["publicKey"] = pbk }
        if let sid = config.shortID { reality["shortId"] = sid }
        if let spx = config.spiderX { reality["spiderX"] = spx }
        return reality
    }

    /// `allowInsecure` в конфиг не пишется: ядро 26.9 его удалило и при
    /// значении true отказывается стартовать. Взамен — закрепление
    /// сертификата по хешу (`pcs`) или проверка по заданному имени (`vcn`).
    private static func tlsSettings(for config: ProxyConfig) -> [String: Any] {
        var tls: [String: Any] = [:]
        if let pcs = config.pinnedPeerCertSha256 { tls["pinnedPeerCertSha256"] = pcs }
        if let vcn = config.verifyPeerCertByName { tls["verifyPeerCertByName"] = vcn }
        if let sni = config.sni { tls["serverName"] = sni }
        if let fp = config.fingerprint { tls["fingerprint"] = fp }
        if !config.alpn.isEmpty { tls["alpn"] = config.alpn }
        return tls
    }

    private static func transportSettings(for config: ProxyConfig) -> [String: Any] {
        switch config.transport {
        case .tcp:
            return [:]

        case .ws, .httpupgrade:
            var settings: [String: Any] = [:]
            if let path = config.path { settings["path"] = path }
            if let host = config.host { settings["host"] = host }
            return settings

        case .grpc:
            var settings: [String: Any] = [:]
            if let name = config.serviceName ?? config.path { settings["serviceName"] = name }
            return settings

        case .http:
            var settings: [String: Any] = [:]
            if let path = config.path { settings["path"] = path }
            if let host = config.host { settings["host"] = [host] }
            return settings

        case .xhttp:
            return xhttpSettings(for: config)
        }
    }

    /// XHTTP собирается в два слоя: сначала произвольный JSON из `extra`
    /// (там живут xmux, downloadSettings, scMaxEachPostBytes и прочее),
    /// затем поверх кладутся явные параметры ссылки. Брать что-то одно нельзя —
    /// панели дублируют часть полей и в extra, и в отдельных параметрах.
    static func xhttpSettings(for config: ProxyConfig) -> [String: Any] {
        var settings: [String: Any] = [:]

        if let json = config.xhttpExtraJSON,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        if let path = config.path { settings["path"] = path }
        if let host = config.host { settings["host"] = host }
        if let mode = config.xhttpMode { settings["mode"] = mode }
        if let padding = config.xPaddingBytes { settings["xPaddingBytes"] = padding }

        return settings
    }
}
