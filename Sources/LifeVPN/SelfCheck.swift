import Foundation
import CryptoKit
import Darwin

/// Внутренние проверки вместо XCTest.
///
/// XCTest поставляется только с Xcode, а проект должен жить на голых
/// Command Line Tools. Поэтому проверки собраны в само приложение и
/// запускаются флагом: `swift run LifeVPN --self-check`.
enum SelfCheck {

    // MARK: - Мини-каркас

    struct Failure: Error { let message: String }

    private nonisolated(unsafe) static var passed = 0
    private nonisolated(unsafe) static var failures: [String] = []

    private static func check(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
        } catch let failure as Failure {
            failures.append("\(name): \(failure.message)")
        } catch {
            failures.append("\(name): \(error.localizedDescription)")
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private static func equal<T: Equatable>(_ actual: T?, _ expected: T?, _ label: String) throws {
        guard actual == expected else {
            throw Failure(message: "\(label): ожидалось \(String(describing: expected)), получено \(String(describing: actual))")
        }
    }

    private static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw Failure(message: "\(label): значение отсутствует") }
        return value
    }

    // MARK: - Образцы ссылок

    /// Выдуманные ссылки той же структуры, что у настоящих. Ни одно значение
    /// не взято с реальных серверов: адреса, ключи, shortId, пути и порты —
    /// заглушки, потому что код лежит в публичном репозитории.
    private enum Sample {
        static let realityTCP = """
        vless://00000000-0000-4000-8000-000000000001@nl.example.org:443\
        ?encryption=none&flow=xtls-rprx-vision&fp=firefox\
        &pbk=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK\
        &security=reality&sid=0123456789ab&sni=www.example.com\
        &spx=%2Fsample-path-one&type=tcp#%F0%9F%87%B3%F0%9F%87%B1%20Netherlands
        """

        static let realityXHTTP = """
        vless://00000000-0000-4000-8000-000000000002@de.example.org:8443\
        ?encryption=none\
        &extra=%7B%22mode%22%3A%22stream-up%22%2C%22xPaddingBytes%22%3A%22100-1000%22%7D\
        &fp=firefox&host=&mode=stream-up&path=%2Fsample%2Fxhttp\
        &pbk=LLLLMMMMNNNNOOOOPPPPQQQQRRRRSSSSTTTTUUUUVVV\
        &security=reality&sid=ab&sni=cdn.example.com\
        &spx=%2Fsample-path-two&type=xhttp&x_padding_bytes=100-1000\
        #%F0%9F%87%A9%F0%9F%87%AA%20Germany
        """
    }

    // MARK: - Запуск

    static func runAndExit() -> Never {
        passed = 0
        failures = []

        checkLinkParser()
        checkConfigBuilder()
        checkSubscriptionDecoding()
        checkStoreSync()
        checkRouting()
        checkPingStatistics()
        checkSecurityHardening()

        print("")
        if failures.isEmpty {
            print("Проверок пройдено: \(passed). Все зелёные.")
            exit(0)
        }
        print("Пройдено: \(passed), провалено: \(failures.count)")
        for failure in failures { print("  ✗ \(failure)") }
        exit(1)
    }

    // MARK: - Парсер ссылок

    private static func checkLinkParser() {
        check("vless/reality поверх tcp разбирается") {
            let config = try LinkParser.parse(Sample.realityTCP)
            try equal(config.address, "nl.example.org", "адрес")
            try equal(config.port, 443, "порт")
            try equal(config.security, .reality, "тип защиты")
            try equal(config.transport, .tcp, "транспорт")
            try equal(config.flow, "xtls-rprx-vision", "flow")
            try equal(config.sni, "www.example.com", "sni")
            try equal(config.spiderX, "/sample-path-one", "spiderX")
        }

        check("имя с эмодзи декодируется") {
            let config = try LinkParser.parse(Sample.realityTCP)
            try equal(config.name, "🇳🇱 Netherlands", "имя")
        }

        check("xhttp разбирается со всеми параметрами") {
            let config = try LinkParser.parse(Sample.realityXHTTP)
            try equal(config.transport, .xhttp, "транспорт")
            try equal(config.xhttpMode, "stream-up", "режим")
            try equal(config.path, "/sample/xhttp", "путь")
            try equal(config.xPaddingBytes, "100-1000", "padding")
            try expect(config.flow == nil, "у xhttp-ссылки не должно быть flow")
            try expect(config.xhttpExtraJSON != nil, "extra потерялся")
        }

        check("пустой host не превращается в пустую строку") {
            let config = try LinkParser.parse(Sample.realityXHTTP)
            try expect(config.host == nil, "host должен быть nil")
        }

        check("короткий shortId сохраняется") {
            let config = try LinkParser.parse(Sample.realityXHTTP)
            try equal(config.shortID, "ab", "shortId")
        }

        check("splithttp считается тем же xhttp") {
            let link = Sample.realityXHTTP.replacingOccurrences(of: "type=xhttp", with: "type=splithttp")
            try equal(try LinkParser.parse(link).transport, .xhttp, "транспорт")
        }

        check("неизвестная схема отвергается") {
            do {
                _ = try LinkParser.parse("ss://whatever@host:443")
                throw Failure(message: "ошибки не было, хотя схема не поддерживается")
            } catch let error as LinkParser.Failure {
                try equal(error, .unsupportedScheme("ss"), "тип ошибки")
            }
        }

        check("многострочный разбор пропускает пустое и мусор") {
            let text = """
            # комментарий

            \(Sample.realityTCP)
            \(Sample.realityXHTTP)
            мусор
            """
            let result = LinkParser.parseMany(text)
            try equal(result.configs.count, 2, "разобранных ссылок")
            try equal(result.errors.count, 1, "ошибок")
        }
    }

    // MARK: - Сборщик конфига

    private static func checkConfigBuilder() {
        check("reality-блок собирается для tcp") {
            let config = try LinkParser.parse(Sample.realityTCP)
            let stream = XrayConfigBuilder.streamSettings(for: config)
            try equal(stream["network"] as? String, "tcp", "network")
            try equal(stream["security"] as? String, "reality", "security")
            let reality = try unwrap(stream["realitySettings"] as? [String: Any], "realitySettings")
            try equal(reality["serverName"] as? String, "www.example.com", "serverName")
            try equal(reality["shortId"] as? String, "0123456789ab", "shortId")
        }

        check("vision доживает до конфига на tcp") {
            let config = try LinkParser.parse(Sample.realityTCP)
            let user = try firstUser(in: XrayConfigBuilder.outbound(for: config))
            try equal(user["flow"] as? String, "xtls-rprx-vision", "flow")
        }

        check("vision вырезается на xhttp") {
            var config = try LinkParser.parse(Sample.realityXHTTP)
            config.flow = "xtls-rprx-vision"
            let user = try firstUser(in: XrayConfigBuilder.outbound(for: config))
            try expect(user["flow"] == nil, "flow не должен попадать в xhttp-конфиг")
        }

        check("xhttpSettings — слияние extra и явных параметров") {
            let config = try LinkParser.parse(Sample.realityXHTTP)
            let settings = XrayConfigBuilder.xhttpSettings(for: config)
            try equal(settings["mode"] as? String, "stream-up", "mode")
            try equal(settings["xPaddingBytes"] as? String, "100-1000", "xPaddingBytes")
            try equal(settings["path"] as? String, "/sample/xhttp", "path")
            try expect(settings["host"] == nil, "пустой host не должен попадать в конфиг")
        }

        check("незнакомые поля из extra не теряются") {
            var config = try LinkParser.parse(Sample.realityXHTTP)
            config.xhttpExtraJSON = #"{"mode":"packet-up","xmux":{"maxConcurrency":8}}"#
            let settings = XrayConfigBuilder.xhttpSettings(for: config)
            try expect(settings["xmux"] != nil, "xmux потерялся")
            try equal(settings["mode"] as? String, "stream-up", "явный параметр должен перекрывать extra")
        }

        check("конфиг сериализуется и имеет ожидаемую форму") {
            let config = try LinkParser.parse(Sample.realityXHTTP)
            let data = try XrayConfigBuilder.makeJSON(for: config, options: .init())
            let root = try unwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "корень")
            let inbounds = try unwrap(root["inbounds"] as? [[String: Any]], "inbounds")
            try equal(inbounds.count, 2, "число входящих")
            let outbounds = try unwrap(root["outbounds"] as? [[String: Any]], "outbounds")
            try equal(outbounds.compactMap { $0["tag"] as? String }, ["proxy", "direct", "block"], "теги исходящих")
        }

        check("роутинг не ссылается на geo-базы") {
            let config = try LinkParser.parse(Sample.realityTCP)
            let tree = XrayConfigBuilder.makeTree(for: config, options: .init())
            let routing = try unwrap(tree["routing"] as? [String: Any], "routing")
            let rules = try unwrap(routing["rules"] as? [[String: Any]], "rules")
            for rule in rules {
                for value in (rule["ip"] as? [String]) ?? [] {
                    try expect(!value.hasPrefix("geoip:"),
                               "правило ссылается на \(value), а geoip.dat в свежей установке нет")
                }
                for value in (rule["domain"] as? [String]) ?? [] {
                    try expect(!value.hasPrefix("geosite:"),
                               "правило ссылается на \(value), а geosite.dat в свежей установке нет")
                }
            }
            try expect(!rules.isEmpty, "локальные адреса должны идти мимо туннеля")
        }

        check("порты из настроек доезжают до входящих") {
            let config = try LinkParser.parse(Sample.realityTCP)
            let tree = XrayConfigBuilder.makeTree(for: config,
                                                  options: .init(socksPort: 11080, httpPort: 11081))
            let inbounds = try unwrap(tree["inbounds"] as? [[String: Any]], "inbounds")
            try equal(inbounds[0]["port"] as? Int, 11080, "socks-порт")
            try equal(inbounds[1]["port"] as? Int, 11081, "http-порт")
        }
    }

    private static func firstUser(in outbound: [String: Any]) throws -> [String: Any] {
        let settings = try unwrap(outbound["settings"] as? [String: Any], "settings")
        let vnext = try unwrap((settings["vnext"] as? [[String: Any]])?.first, "vnext")
        return try unwrap((vnext["users"] as? [[String: Any]])?.first, "users")
    }

    // MARK: - Подписки

    private static func checkSubscriptionDecoding() {
        check("base64-тело подписки разворачивается") {
            let plain = "\(Sample.realityTCP)\n\(Sample.realityXHTTP)"
            let encoded = Data(plain.utf8).base64EncodedString()
            let links = try SubscriptionFetcher.decodeBody(encoded)
            try equal(links.count, 2, "число ссылок")
        }

        check("base64 без выравнивания и в url-safe виде тоже разворачивается") {
            let plain = "\(Sample.realityTCP)"
            let encoded = Data(plain.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            try equal(try SubscriptionFetcher.decodeBody(encoded).count, 1, "число ссылок")
        }

        check("обычный текст остаётся текстом") {
            let plain = "\(Sample.realityTCP)\n\(Sample.realityXHTTP)"
            try equal(try SubscriptionFetcher.decodeBody(plain).count, 2, "число ссылок")
        }

        check("заголовок subscription-userinfo разбирается") {
            let info = SubscriptionFetcher.parseUserInfo("upload=100; download=200; total=1000; expire=1767225600")
            try equal(info.used, 300, "израсходовано")
            try equal(info.total, 1000, "всего")
            try equal(info.expiresAt, Date(timeIntervalSince1970: 1767225600), "срок")
        }

        check("expire=0 означает бессрочную подписку") {
            let info = SubscriptionFetcher.parseUserInfo("upload=0; download=0; total=0; expire=0")
            try expect(info.expiresAt == nil, "нулевой expire не должен превращаться в дату")
        }

        check("base64-заголовок profile-title декодируется") {
            let encoded = "base64:" + Data("Мой сервис".utf8).base64EncodedString()
            try equal(SubscriptionFetcher.decodeHeaderValue(encoded), "Мой сервис", "название")
        }
    }

    // MARK: - Статистика замеров

    private static func checkPingStatistics() {
        check("медиана игнорирует единичный выброс") {
            // Ровно тот случай, который ломал прошлую версию: один ложный
            // нулевой замер обнулял результат, когда бралcя минимум.
            try equal(PingTester.median([54, 0, 56]), 54, "медиана")
        }

        check("медиана чётного числа замеров — среднее середины") {
            try equal(PingTester.median([10, 20, 30, 40]), 25, "медиана")
        }

        check("пустой набор замеров даёт nil") {
            try expect(PingTester.median([]) == nil, "мерить нечего")
        }
    }

    // MARK: - Маршрутизация

    private static func checkRouting() {
        check("глобальный пресет обходится без geo-баз") {
            let config = RoutingPreset.global.make()
            try expect(!config.needsGeoAssets, "глобальному режиму базы не нужны")
        }

        check("пресет обхода РФ требует geo-базы") {
            let config = RoutingPreset.bypassRU.make()
            try expect(config.needsGeoAssets, "правила geosite: без баз не работают")
        }

        check("блокировки идут раньше правила «российское напрямую»") {
            let config = RoutingPreset.bypassRU.make()
            let routing = XrayConfigBuilder.routing(config)
            let rules = try unwrap(routing["rules"] as? [[String: Any]], "rules")
            let tags = rules.compactMap { $0["outboundTag"] as? String }

            let block = try unwrap(tags.firstIndex(of: "block"), "правило block")
            let direct = try unwrap(tags.lastIndex(of: "direct"), "правило direct")
            try expect(block < direct, "реклама обязана отсекаться до общего правила direct")
        }

        check("счётчики без своего порта и только для своего процесса") {
            let config = try LinkParser.parse(Sample.realityTCP)
            let tree = XrayConfigBuilder.makeTree(for: config,
                                                  options: .init(metrics: true, selfProcess: ["/Applications/LifeVPN.app/Contents/MacOS/LifeVPN"]))
            let metrics = try unwrap(tree["metrics"] as? [String: Any], "metrics")
            try expect(metrics["listen"] == nil, "у metrics не должно быть своего порта")
            try equal(metrics["tag"] as? String, "metrics", "тег metrics")
            let inbounds = try unwrap(tree["inbounds"] as? [[String: Any]], "inbounds")
            try equal(inbounds.count, 2, "только socks и http")
            let routing = try unwrap(tree["routing"] as? [String: Any], "routing")
            let rules = try unwrap(routing["rules"] as? [[String: Any]], "rules")
            try equal(rules[0]["outboundTag"] as? String, "metrics", "первое правило — счётчики")
            try equal(rules[0]["process"] as? [String], ["/Applications/LifeVPN.app/Contents/MacOS/LifeVPN"], "только свой процесс")
            try equal(rules[1]["outboundTag"] as? String, "block", "остальным служебное имя закрыто")
            try expect(rules[1]["process"] == nil, "закрыто для всех процессов")
        }

        check("изоляция MAX — только в «Обходе РФ» и когда включена") {
            try expect(IsolatedApps.processes(for: RoutingPreset.bypassRU.make(), enabled: true).contains("MAX"), "MAX в списке")
            try expect(IsolatedApps.processes(for: RoutingPreset.bypassRU.make(), enabled: false).isEmpty, "выключено")
            try expect(IsolatedApps.processes(for: RoutingPreset.global.make(), enabled: true).isEmpty, "не в «Глобально»")
            let options = XrayConfigBuilder.Options(isolatedProcesses: ["MAX"], routing: RoutingPreset.bypassRU.make())
            let rules = try unwrap(XrayConfigBuilder.routing(options.routing, extra: options)["rules"] as? [[String: Any]], "rules")
            try equal(rules[0]["process"] as? [String], ["MAX"], "изоляция первым правилом")
            try equal(rules[0]["outboundTag"] as? String, "direct", "напрямую")
        }

        check("QUIC блокируется самым первым правилом") {
            let routing = XrayConfigBuilder.routing(RoutingPreset.bypassRU.make())
            let rules = try unwrap(routing["rules"] as? [[String: Any]], "rules")
            let first = try unwrap(rules.first, "первое правило")
            try equal(first["network"] as? String, "udp", "сеть")
            try equal(first["port"] as? String, "443", "порт")
            try equal(first["outboundTag"] as? String, "block", "тег первого правила")
        }

        check("локальная сеть уходит напрямую сразу за блоком QUIC") {
            let routing = XrayConfigBuilder.routing(RoutingPreset.bypassRU.make())
            let rules = try unwrap(routing["rules"] as? [[String: Any]], "rules")
            try expect(rules.count > 1, "правил должно быть больше одного")
            let lan = rules[1]
            try equal(lan["outboundTag"] as? String, "direct", "тег правила локальной сети")
            let ips = try unwrap(lan["ip"] as? [String], "диапазоны")
            try expect(ips.contains("192.168.0.0/16"), "домашняя сеть должна идти мимо туннеля")
        }

        check("выключенный обход LAN убирает правило локальной сети") {
            var config = RoutingPreset.bypassRU.make()
            config.bypassLAN = false
            let routing = XrayConfigBuilder.routing(config)
            let rules = try unwrap(routing["rules"] as? [[String: Any]], "rules")
            let hasPrivate = rules.contains { ($0["ip"] as? [String])?.contains("192.168.0.0/16") == true }
            try expect(!hasPrivate, "правило локальной сети должно исчезнуть")
        }

        check("свои домены идут напрямую и раньше правил туннеля") {
            var config = RoutingPreset.bypassRU.make()
            config.directDomains = ["mail.example.com"]
            let routing = XrayConfigBuilder.routing(config)
            let rules = try unwrap(routing["rules"] as? [[String: Any]], "rules")

            let mine = try unwrap(rules.firstIndex { rule in
                (rule["domain"] as? [String])?.contains("mail.example.com") ?? false
            }, "правило со своим доменом")
            let firstProxy = try unwrap(rules.firstIndex { ($0["outboundTag"] as? String) == "proxy" },
                                        "первое правило туннеля")
            try expect(mine < firstProxy, "свой домен обязан побеждать общие категории")
            try equal(rules[mine]["outboundTag"] as? String, "direct", "тег правила")
        }

        check("свои домены резолвятся системным DNS") {
            var config = RoutingPreset.bypassRU.make()
            config.directDomains = ["mail.example.com"]
            let dns = try unwrap(XrayConfigBuilder.dns(config), "блок dns")
            let servers = try unwrap(dns["servers"] as? [Any], "серверы")
            let first = try unwrap(servers.first as? [String: Any], "первый сервер")
            try equal(first["address"] as? String, "localhost", "резолвер")
            let domains = try unwrap(first["domains"] as? [String], "домены")
            try expect(domains.contains("mail.example.com"), "домен должен быть в списке")
        }

        check("при обходе LAN добавляются имена без точки и зона .local") {
            var config = RoutingPreset.bypassRU.make()
            config.bypassLAN = true
            let domains = config.effectiveDirectDomains
            try expect(domains.contains("domain:local"), "зона .local")
            try expect(domains.contains("regexp:^[^.]+$"), "внутренние имена без точки")
        }

        check("российские домены резолвятся местным DNS") {
            let config = RoutingPreset.bypassRU.make()
            let dns = try unwrap(XrayConfigBuilder.dns(config), "блок dns")
            let servers = try unwrap(dns["servers"] as? [Any], "серверы")

            // Ищем по адресу, а не по позиции: перед местным резолвером может
            // стоять системный для своих доменов, и порядок ещё изменится.
            let domestic = try unwrap(servers.compactMap { $0 as? [String: Any] }
                .first { ($0["address"] as? String) == "https://77.88.8.8/dns-query" },
                                      "местный резолвер")
            let domains = try unwrap(domestic["domains"] as? [String], "домены")
            try expect(domains.contains("geosite:category-ru"), "российская категория должна быть в списке")
        }

        check("системный резолвер стоит раньше публичных") {
            var config = RoutingPreset.bypassRU.make()
            config.directDomains = ["intranet.example.com"]
            let dns = try unwrap(XrayConfigBuilder.dns(config), "блок dns")
            let servers = try unwrap(dns["servers"] as? [Any], "серверы")
            let first = try unwrap(servers.first as? [String: Any], "первый сервер")
            try equal(first["address"] as? String, "localhost", "первым обязан идти системный")
        }

        check("без списков и без обхода LAN блока dns нет") {
            var config = RoutingPreset.global.make()
            config.bypassLAN = false
            try expect(XrayConfigBuilder.dns(config) == nil,
                       "разделять резолверы незачем, когда делить нечего")
        }

        check("domainStrategy у обхода — IPIfNonMatch") {
            let routing = XrayConfigBuilder.routing(RoutingPreset.bypassRU.make())
            try equal(routing["domainStrategy"] as? String, "IPIfNonMatch", "стратегия")
        }
    }

    // MARK: - Синхронизация подписки

    private static func checkStoreSync() {
        check("синхронизация сохраняет id уцелевших серверов") {
            let subscriptionID = UUID()
            var first = try LinkParser.parse(Sample.realityTCP)
            var second = try LinkParser.parse(Sample.realityXHTTP)
            first.subscriptionID = subscriptionID
            second.subscriptionID = subscriptionID

            let existing = [first, second]
            let fetched = [try LinkParser.parse(Sample.realityXHTTP)]

            let result = ServerStore.merge(existing: existing,
                                           fetched: fetched,
                                           subscriptionID: subscriptionID)
            try equal(result.servers.count, 1, "осталось серверов")
            try equal(result.servers[0].id, second.id, "id уцелевшего сервера должен сохраниться")
            try equal(result.removed, 1, "удалено")
            try equal(result.added, 0, "добавлено")
        }

        check("новые серверы из подписки добавляются") {
            let subscriptionID = UUID()
            var existing = try LinkParser.parse(Sample.realityTCP)
            existing.subscriptionID = subscriptionID

            let fetched = [try LinkParser.parse(Sample.realityTCP),
                           try LinkParser.parse(Sample.realityXHTTP)]

            let result = ServerStore.merge(existing: [existing],
                                           fetched: fetched,
                                           subscriptionID: subscriptionID)
            try equal(result.servers.count, 2, "стало серверов")
            try equal(result.added, 1, "добавлено")
            try equal(result.removed, 0, "удалено")
        }

        check("переименование на сервере подхватывается без потери id") {
            let subscriptionID = UUID()
            var existing = try LinkParser.parse(Sample.realityTCP)
            existing.subscriptionID = subscriptionID
            existing.name = "Старое имя"

            let fetched = [try LinkParser.parse(Sample.realityTCP)]
            let result = ServerStore.merge(existing: [existing],
                                           fetched: fetched,
                                           subscriptionID: subscriptionID)
            try equal(result.servers[0].id, existing.id, "id")
            try equal(result.servers[0].name, "🇳🇱 Netherlands", "имя должно обновиться")
        }

        check("ручные серверы не трогаются синхронизацией подписки") {
            let subscriptionID = UUID()
            let manual = try LinkParser.parse(Sample.realityTCP)   // subscriptionID == nil
            let result = ServerStore.merge(existing: [manual],
                                           fetched: [],
                                           subscriptionID: subscriptionID)
            try equal(result.servers.count, 1, "ручной сервер должен уцелеть")
            try equal(result.removed, 0, "удалено")
        }
    }

    // MARK: - Безопасность (3.1.5)

    private static func checkSecurityHardening() {
        let sample = Sample.realityTCP

        check("подписка: ровно 10 000 ссылок принимается") {
            let text = Array(repeating: sample, count: SubscriptionFetcher.maxSubscriptionLinks).joined(separator: "\n")
            try equal(try SubscriptionFetcher.decodeBody(text).count, 10_000, "число ссылок")
        }

        check("подписка: 10 001 ссылка отклоняется, а не обрезается") {
            let text = Array(repeating: sample, count: SubscriptionFetcher.maxSubscriptionLinks + 1).joined(separator: "\n")
            do {
                _ = try SubscriptionFetcher.decodeBody(text)
                throw Failure(message: "лишняя ссылка принята")
            } catch is SubscriptionFetcher.Failure {}
        }

        check("подписка: 10 001 ссылка в base64 тоже отклоняется") {
            let text = Array(repeating: sample, count: SubscriptionFetcher.maxSubscriptionLinks + 1).joined(separator: "\n")
            let encoded = Data(text.utf8).base64EncodedString()
            do {
                _ = try SubscriptionFetcher.decodeBody(encoded)
                throw Failure(message: "лишняя ссылка принята")
            } catch is SubscriptionFetcher.Failure {}
        }

        check("подписка: CR, CRLF, Unicode-перенос, комментарии и дубликаты") {
            let text = "# c\r\n\(sample)\r\(sample)\u{2028}\n\n\(sample)"
            try equal(try SubscriptionFetcher.decodeBody(text).count, 3, "число ссылок")
        }

        check("подписка: много пустых разделителей между ссылками") {
            let text = sample + String(repeating: "\n", count: 200_000) + sample
            try equal(try SubscriptionFetcher.decodeBody(text).count, 2, "число ссылок")
        }

        check("подписка: тело ровно 8 МиБ принимается, 8 МиБ + 1 — нет") {
            var body = SubscriptionFetcher.BoundedBody(limit: 8)
            for byte in [UInt8](repeating: 65, count: 8) { try body.append(byte) }
            do {
                try body.append(65)
                throw Failure(message: "лишний байт принят")
            } catch is SubscriptionFetcher.Failure {}
            try equal(SubscriptionFetcher.maxSubscriptionBytes, 8_388_608, "лимит")
        }

        check("подписка: битый base64 и не-UTF-8 не роняют разбор") {
            try equal(try SubscriptionFetcher.decodeBody("!!!не base64***"), [], "ссылок")
            try expect(SubscriptionFetcher.decodeBase64(Data([0xff, 0xfe, 0xfd]).base64EncodedString()) == nil, "не-UTF-8")
        }

        check("подписка: только https, http отклоняется и для локальных адресов") {
            try expect(SubscriptionFetcher.isSecureSubscriptionURL(URL(string: "https://example.org/s")!), "https")
            try expect(!SubscriptionFetcher.isSecureSubscriptionURL(URL(string: "http://example.org/s")!), "http")
            try expect(!SubscriptionFetcher.isSecureSubscriptionURL(URL(string: "http://192.168.1.2/s")!), "локальный http")
            try expect(!SubscriptionFetcher.isSecureSubscriptionURL(URL(string: "https:///s")!), "пустой хост")
        }

        check("userinfo: 100 + 200 = 300, отсутствующее поле не мешает") {
            try equal(SubscriptionFetcher.parseUserInfo("upload=100; download=200").used, 300, "used")
            try equal(SubscriptionFetcher.parseUserInfo("download=200; total=5").used, 200, "used")
        }

        check("userinfo: отрицательное и переполненное значение — неизвестно") {
            let negative = SubscriptionFetcher.parseUserInfo("upload=-1; download=200; total=-5")
            try expect(negative.used == nil, "used при битом upload")
            try expect(negative.total == nil, "отрицательный total")
            let overflow = SubscriptionFetcher.parseUserInfo("upload=9223372036854775807; download=1")
            try expect(overflow.used == nil, "переполнение суммы")
            let huge = SubscriptionFetcher.parseUserInfo("upload=99999999999999999999; download=1")
            try expect(huge.used == nil, "переполнение Int64")
        }

        check("userinfo: недопустимая и нулевая дата") {
            try expect(SubscriptionFetcher.parseUserInfo("expire=0").expiresAt == nil, "expire=0")
            try expect(SubscriptionFetcher.parseUserInfo("expire=abc").expiresAt == nil, "текст")
            try expect(SubscriptionFetcher.parseUserInfo("expire=9223372036854775807").expiresAt == nil, "огромная дата")
        }

        check("profile-update-interval: только положительное конечное") {
            try equal(SubscriptionFetcher.parseUpdateIntervalHours("1"), 24, "1 день")
            for bad in ["0", "-1", "inf", "Infinity", "nan", "1e308", "abc"] {
                try expect(SubscriptionFetcher.parseUpdateIntervalHours(bad) == nil, "интервал \(bad)")
            }
        }

        check("ссылка с неизвестным security отклоняется") {
            let bad = sample.replacingOccurrences(of: "security=reality", with: "security=quantum")
            do {
                _ = try LinkParser.parse(bad)
                throw Failure(message: "неизвестный security принят")
            } catch is LinkParser.Failure {}
        }

        check("журнал прокси: новый, legacy и повреждённый формат") {
            let snapshot = SystemProxy.ServiceSnapshot(
                socks: .init(enabled: false, server: "", port: "0", authenticated: false),
                web: .init(enabled: true, server: "corp.example", port: "3128", authenticated: false),
                secureWeb: .init(enabled: false, server: "", port: "0", authenticated: nil),
                bypass: ["*.corp"], serviceID: "ABC")
            let data = try JSONEncoder().encode(SystemProxy.State(services: ["Wi-Fi": snapshot]))
            guard case .snapshots(let state) = try SystemProxy.decodeRecord(data) else { throw Failure(message: "новый формат") }
            try equal(state.services["Wi-Fi"], snapshot, "снимок")
            // Формат 3.1.4 — без serviceID и authenticated.
            let v314 = #"{"services":{"Wi-Fi":{"socks":{"enabled":false,"server":"","port":"0"},"web":{"enabled":false,"server":"","port":"0"},"secureWeb":{"enabled":false,"server":"","port":"0"},"bypass":[]}}}"#
            guard case .snapshots = try SystemProxy.decodeRecord(Data(v314.utf8)) else { throw Failure(message: "формат 3.1.4") }
            guard case .legacy(let names) = try SystemProxy.decodeRecord(Data(#"["Wi-Fi"]"#.utf8)) else { throw Failure(message: "legacy") }
            try equal(names, ["Wi-Fi"], "legacy-имена")
            for broken in ["", "{", "[]", #"{"services":{}}"#, "null"] {
                do {
                    _ = try SystemProxy.decodeRecord(Data(broken.utf8))
                    throw Failure(message: "повреждённый журнал принят: \(broken)")
                } catch is SystemProxy.Failure {}
            }
        }

        check("networksetup: распознаётся прокси с паролем") {
            let entry = SystemProxy.parseEntry("Enabled: Yes\nServer: p.example\nPort: 8080\nAuthenticated Proxy Enabled: 1")
            try expect(entry.enabled && entry.authenticated == true, "authenticated")
        }

        check("загрузка обновления повторяется только при сбоях сети и 408/429/5xx") {
            for code in [408, 429, 500, 502, 503, 504] {
                try expect(Updater.isRetryable(UpdateError("x", retryable: UpdateError.isRetryableStatus(code))), "код \(code) — повтор")
            }
            for code in [200, 301, 403, 404] {
                try expect(!UpdateError.isRetryableStatus(code), "код \(code) — без повтора")
            }
            try expect(Updater.isRetryable(URLError(.timedOut)), "таймаут — повтор")
            try expect(Updater.isRetryable(URLError(.networkConnectionLost)), "обрыв — повтор")
            try expect(!Updater.isRetryable(URLError(.cancelled)), "отмена — без повтора")
            try expect(!Updater.isRetryable(UpdateError("подпись")), "ошибка подписи — без повтора")
        }

        check("подпись обновления: верная принимается, чужая и подменённая — нет") {
            let key = Curve25519.Signing.PrivateKey()
            let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
            let sha = String(repeating: "a", count: 64)
            let message = UpdateSignature.message(product: "lifevpn-macos", version: "3.1.5", sha256: sha)
            let signature = try key.signature(for: message)
            try expect(UpdateSignature.verify(signature, product: "lifevpn-macos", version: "3.1.5", sha256: sha, publicKey: publicKey), "верная")
            try expect(!UpdateSignature.verify(signature, product: "lifevpn-macos", version: "3.1.6", sha256: sha, publicKey: publicKey), "другая версия")
            try expect(!UpdateSignature.verify(signature, product: "lifevpn-windows", version: "3.1.5", sha256: sha, publicKey: publicKey), "другой продукт")
            try expect(!UpdateSignature.verify(signature, product: "lifevpn-macos", version: "3.1.5", sha256: sha), "чужой ключ")
        }

        check("каталог данных: 0700/0600, ACL снят, файл 000 читается, ссылка отклонена") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifevpn-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("servers.json")
            try Data("test".utf8).write(to: file)
            let chmodACL = Process()
            chmodACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodACL.arguments = ["+a", "everyone allow read,search", root.path]
            try chmodACL.run(); chmodACL.waitUntilExit()
            chmod(file.path, 0)
            try Paths.secureDirectory(root)
            var info = stat()
            stat(root.path, &info); try equal(info.st_mode & 0o777, 0o700, "права каталога")
            stat(file.path, &info); try equal(info.st_mode & 0o777, 0o600, "права файла")
            try equal(try String(contentsOf: file, encoding: .utf8), "test", "содержимое")
            if let acl = acl_get_file(root.path, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                try expect(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0, "ACL снят")
            }
            // Атомарная запись сохраняет 0600.
            try Paths.writePrivate(Data("new".utf8), to: file)
            stat(file.path, &info); try equal(info.st_mode & 0o777, 0o600, "права после записи")
            // Жёсткая ссылка на секретный файл отклоняется.
            let hard = root.appendingPathComponent("outside")
            try expect(link(file.path, hard.path) == 0, "hardlink создан")
            do { try Paths.secureDirectory(root); throw Failure(message: "hardlink принят") } catch is Paths.Failure {}
            try FileManager.default.removeItem(at: hard)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
            do { try Paths.secureDirectory(root); throw Failure(message: "symlink принят") } catch is Paths.Failure {}
        }
    }
}
