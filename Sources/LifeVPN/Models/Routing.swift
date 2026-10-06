import Foundation

/// Правила маршрутизации: что идёт в туннель, что мимо, что режется.
struct RoutingConfig: Codable, Hashable, Sendable {

    var presetID: String = "global"

    var directSites: [String] = []
    var directIP: [String] = []
    var proxySites: [String] = []
    var proxyIP: [String] = []
    var blockSites: [String] = []
    var blockIP: [String] = []

    /// Локальная сеть мимо туннеля: принтеры, NAS, роутер, соседние машины.
    /// Выключать стоит только сознательно — иначе всё домашнее окружение
    /// станет недоступно, пока VPN включён.
    var bypassLAN: Bool = true

    /// Домены, которые всегда идут мимо туннеля и резолвятся системным DNS.
    ///
    /// Ради корпоративных ресурсов. Одного правила маршрутизации мало:
    /// внутреннего имени нет ни на одном публичном резолвере, а мы отправляли
    /// все неизвестные домены на 8.8.8.8 через туннель — оттуда приходил
    /// отказ, и до правил дело просто не доходило.
    var directDomains: [String] = []

    /// Что добавляется к списку автоматически при включённом обходе LAN:
    /// имена без точки (внутренние хосты вроде `mail`, `wiki`) и зона .local.
    static let localDomainPatterns = ["regexp:^[^.]+$", "domain:local"]

    var effectiveDirectDomains: [String] {
        let manual = directDomains
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return bypassLAN ? manual + Self.localDomainPatterns : manual
    }

    /// IPIfNonMatch — если по домену правило не нашлось, домен резолвится
    /// и правила прогоняются ещё раз уже по IP. Без этого «обход РФ» дырявый:
    /// приложение, которое ходит сразу по адресу, мимо правил проскочит.
    var domainStrategy: String = "IPIfNonMatch"

    /// DNS для доменов из списка «напрямую» — свой, местный.
    var domesticDNS: String = "https://77.88.8.8/dns-query"
    /// Для всего остального — через туннель, иначе провайдер видит запросы.
    var remoteDNS: String = "https://8.8.8.8/dns-query"
    var dnsHosts: [String: String] = [:]

    var geositeURL: String = ""
    var geoipURL: String = ""

    /// Нужны ли geo-базы. Правила вида `geosite:` и `geoip:` ядро читает
    /// из файлов, и без них оно падает при старте.
    var needsGeoAssets: Bool {
        let all = directSites + proxySites + blockSites + directIP + proxyIP + blockIP
        return all.contains { $0.hasPrefix("geosite:") || $0.hasPrefix("geoip:") }
    }

    var preset: RoutingPreset? { RoutingPreset.all.first { $0.id == presetID } }
}

struct RoutingPreset: Identifiable, Sendable {
    let id: String
    let titleRU: String
    let titleEN: String
    let subtitleRU: String
    let subtitleEN: String
    let make: @Sendable () -> RoutingConfig

    // Пресеты — константы, они создаются раньше, чем известен язык.
    // Поэтому перевод выбирается при чтении, а не при создании.
    var title: String { L.t(titleRU, titleEN) }
    var subtitle: String { L.t(subtitleRU, subtitleEN) }

    static let global = RoutingPreset(
        id: "global",
        titleRU: "Глобально",
        titleEN: "Global",
        subtitleRU: "Весь трафик через VPN, мимо идут только локальные адреса",
        subtitleEN: "All traffic through the VPN; only local addresses go around it",
        make: {
            var config = RoutingConfig()
            config.presetID = "global"
            config.domainStrategy = "AsIs"
            config.domesticDNS = ""
            config.remoteDNS = ""
            return config
        }
    )

    /// Рабочая схема для России: местные сервисы и часть игровых площадок
    /// идут напрямую — так они быстрее и не ломаются на геоблокировках, —
    /// заблокированное идёт через туннель, реклама и телеметрия режутся.
    static let bypassRU = RoutingPreset(
        id: "bypass-ru",
        titleRU: "Обход РФ",
        titleEN: "Bypass RU",
        subtitleRU: "Российские сайты и сервисы идут мимо VPN, остальное — через",
        subtitleEN: "Russian sites and services go around the VPN, the rest goes through it",
        make: {
            var config = RoutingConfig()
            config.presetID = "bypass-ru"
            config.directSites = [
                "geosite:private",
                "geosite:category-ru",
                "geosite:whitelist",
                "geosite:microsoft",
                "geosite:apple",
                "geosite:epicgames",
                "geosite:riot",
                "geosite:escapefromtarkov",
                "geosite:steam",
                "geosite:twitch",
                "geosite:pinterest",
                "geosite:faceit"
            ]
            config.directIP = ["geoip:private", "geoip:direct"]
            config.proxySites = [
                "geosite:google-play",
                "geosite:github",
                "geosite:twitch-ads",
                "geosite:youtube",
                "geosite:telegram"
            ]
            config.blockSites = [
                "geosite:win-spy",
                "geosite:torrent",
                "geosite:category-ads"
            ]
            config.dnsHosts = [
                "lkfl2.nalog.ru": "213.24.64.175",
                "lknpd.nalog.ru": "213.24.64.181"
            ]
            config.geositeURL = GeoAssets.defaultGeositeURL
            config.geoipURL = GeoAssets.defaultGeoipURL
            return config
        }
    )

    static let all: [RoutingPreset] = [.bypassRU, .global]
}
