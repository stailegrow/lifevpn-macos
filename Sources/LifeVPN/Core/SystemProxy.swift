import Foundation
import SystemConfiguration

/// Управление системными настройками прокси через `networksetup`.
///
/// Перед любыми изменениями на диск пишется журнал восстановления
/// (proxy-state.json) со снимком прежних настроек каждой службы. Журнал
/// удаляется только после того, как ВСЕ шаги восстановления прошли: если
/// приложение упадёт или восстановление не удастся, при следующем запуске
/// или повторном отключении мы вернём именно исходные настройки.
enum SystemProxy {

    private static let bypass = [
        "127.0.0.1", "localhost", "*.local",
        "169.254/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"
    ]

    private static var stateFile: URL {
        Paths.appSupport.appendingPathComponent("proxy-state.json")
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Журнал есть — значит, прежние настройки ещё не возвращены (или файл
    /// повреждён и требует внимания). Пока он есть, новое подключение
    /// не начинается.
    static var hasPendingRecovery: Bool {
        FileManager.default.fileExists(atPath: stateFile.path)
    }

    static var recoveryFailure: String {
        L.t("Не удалось вернуть прежние настройки системного прокси. Запись восстановления сохранена — повторите отключение. Новое подключение возможно только после успешного восстановления.",
            "Could not restore the previous system proxy settings. The recovery record is kept — retry disconnecting. A new connection is possible only after a successful restore.")
    }

    // MARK: - Прежние настройки

    /// Настройки одного вида прокси (SOCKS, HTTP или HTTPS) до подключения.
    struct ProxyEntry: Codable, Equatable {
        var enabled: Bool
        var server: String
        var port: String
        /// Был ли включён вход по паролю. Пароль хранится в Keychain, и
        /// networksetup вернуть его не может — такие службы не трогаем.
        var authenticated: Bool?
    }

    /// Всё, что меняем у одного сетевого сервиса, — чтобы вернуть как было:
    /// корпоративный прокси или свои исключения пользователя не должны
    /// пропадать после отключения VPN.
    struct ServiceSnapshot: Codable, Equatable {
        var socks: ProxyEntry
        var web: ProxyEntry
        var secureWeb: ProxyEntry
        var bypass: [String]
        /// Стабильный идентификатор службы SystemConfiguration (с 3.1.5).
        /// Имя службы могут переименовать во время сессии — восстанавливаем
        /// по идентификатору, имя лишь запасной вариант.
        var serviceID: String?
    }

    /// Содержимое proxy-state.json. До 3.1.4 там лежал просто список
    /// сервисов (`[String]`), в 3.1.4 — `services` без идентификаторов.
    /// Оба формата читаются.
    struct State: Codable {
        var services: [String: ServiceSnapshot]
    }

    /// Что лежит в журнале восстановления.
    enum Record {
        case none
        case snapshots(State)
        /// Формат до 3.1.4: известны только имена служб, прежних значений
        /// там никогда не было — вернуть можно лишь «выключено».
        case legacy([String])
    }

    // MARK: - Включение и выключение

    static func enable(socksPort: Int, httpPort: Int) throws {
        // Сначала — незавершённое восстановление прошлой сессии. Повреждённый
        // журнал не даёт права затереть исходные настройки новыми.
        if hasPendingRecovery {
            try restore()
        }

        let services = try enabledServices()
        guard !services.isEmpty else {
            throw Failure(message: L.t("Не найдено ни одного активного сетевого сервиса.", "No active network service was found."))
        }

        var state = State(services: [:])
        let ids = serviceIDsByName()
        for service in services {
            var snapshot = try snapshot(of: service)
            snapshot.serviceID = ids[service]
            if [snapshot.socks, snapshot.web, snapshot.secureWeb].contains(where: { $0.enabled && $0.authenticated == true }) {
                throw Failure(message: L.t("У службы «\(service)» включён прокси с паролем. Вернуть его без пароля нельзя, поэтому системный прокси не меняется.",
                                           "Service “\(service)” uses a password-protected proxy. It cannot be restored without the password, so the system proxy is left unchanged."))
            }
            state.services[service] = snapshot
        }
        // Снимок пишется ДО любых изменений. Не записался — ничего не меняем.
        try persist(state)

        do {
            for service in services {
                try run(["-setsocksfirewallproxy", service, "127.0.0.1", String(socksPort)])
                try run(["-setsocksfirewallproxystate", service, "on"])
                try run(["-setwebproxy", service, "127.0.0.1", String(httpPort)])
                try run(["-setwebproxystate", service, "on"])
                try run(["-setsecurewebproxy", service, "127.0.0.1", String(httpPort)])
                try run(["-setsecurewebproxystate", service, "on"])
                try run(["-setproxybypassdomains", service] + mergedBypass(state.services[service]?.bypass ?? []))
            }
        } catch {
            // Часть команд уже могла пройти — возвращаем всё как было.
            do {
                try restore()
            } catch let restoreError {
                throw Failure(message: "\(error.localizedDescription)\n\(restoreError.localizedDescription)\n\(recoveryFailure)")
            }
            throw error
        }
    }

    /// Возвращает настройки прокси к тем, что были до подключения. Журнал
    /// удаляется только после успеха всех шагов; при любой ошибке он
    /// остаётся на месте байт в байт, а ошибка уходит наверх.
    static func restore() throws {
        let record = try loadRecord()
        var errors: [String] = []

        switch record {
        case .none:
            return
        case .snapshots(let state):
            let current = Set(try allServices())
            let namesByID = serviceNamesByID()
            for (name, snapshot) in state.services.sorted(by: { $0.key < $1.key }) {
                // Ищем службу по стабильному ID — её могли переименовать.
                let target = snapshot.serviceID.flatMap { namesByID[$0] } ?? name
                guard current.contains(target) else {
                    errors.append(L.t("Служба «\(name)» больше не найдена.", "Service “\(name)” no longer exists."))
                    continue
                }
                errors += restore(snapshot, on: target)
            }
        case .legacy(let services):
            for service in services {
                for option in ["-setsocksfirewallproxystate", "-setwebproxystate", "-setsecurewebproxystate"] {
                    do { try run([option, service, "off"]) } catch { errors.append(error.localizedDescription) }
                }
            }
        }

        guard errors.isEmpty else {
            throw Failure(message: errors.joined(separator: "\n"))
        }
        do {
            try FileManager.default.removeItem(at: stateFile)
        } catch {
            throw Failure(message: L.t("Настройки возвращены, но запись восстановления не удалилась: \(error.localizedDescription)",
                                       "Settings were restored, but the recovery record could not be removed: \(error.localizedDescription)"))
        }
    }

    /// Прошлый запуск оставил журнал — прибираемся на старте. Возвращает
    /// `true`, если что-то было восстановлено; ошибка — наверх.
    static func cleanUpAfterCrash() throws -> Bool {
        guard hasPendingRecovery else { return false }
        try restore()
        return true
    }

    // MARK: - Журнал

    /// Отсутствующий файл и повреждённый — разные вещи: первый значит «нечего
    /// восстанавливать», второй — ошибку, и никаких догадок вроде «выключить
    /// прокси у всех активных служб».
    static func loadRecord() throws -> Record {
        guard hasPendingRecovery else { return .none }
        let data: Data
        do {
            data = try Data(contentsOf: stateFile)
        } catch {
            throw Failure(message: L.t("Запись восстановления прокси не читается: \(error.localizedDescription)",
                                       "The proxy recovery record cannot be read: \(error.localizedDescription)"))
        }
        return try decodeRecord(data)
    }

    static func decodeRecord(_ data: Data) throws -> Record {
        if let state = try? JSONDecoder().decode(State.self, from: data) {
            guard !state.services.isEmpty else { throw corrupted }
            return .snapshots(state)
        }
        if let services = try? JSONDecoder().decode([String].self, from: data) {
            guard !services.isEmpty, services.allSatisfy({ !$0.isEmpty }) else { throw corrupted }
            return .legacy(services)
        }
        throw corrupted
    }

    private static var corrupted: Failure {
        Failure(message: L.t("Запись восстановления прокси повреждена. Она сохранена в proxy-state.json; проверьте настройки прокси в «Системных настройках» → «Сеть».",
                             "The proxy recovery record is damaged. It is kept in proxy-state.json; check the proxy settings in System Settings → Network."))
    }

    // MARK: - Снимок и восстановление

    private static func snapshot(of service: String) throws -> ServiceSnapshot {
        ServiceSnapshot(
            socks: parseEntry(try run(["-getsocksfirewallproxy", service])),
            web: parseEntry(try run(["-getwebproxy", service])),
            secureWeb: parseEntry(try run(["-getsecurewebproxy", service])),
            bypass: parseBypass(try run(["-getproxybypassdomains", service]))
        )
    }

    /// Ответ networksetup вида «Enabled: Yes / Server: … / Port: … /
    /// Authenticated Proxy Enabled: 0».
    static func parseEntry(_ output: String) -> ProxyEntry {
        var entry = ProxyEntry(enabled: false, server: "", port: "0", authenticated: false)
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": entry.enabled = parts[1].lowercased() == "yes"
            case "Server":  entry.server = parts[1]
            case "Port":    entry.port = parts[1]
            case "Authenticated Proxy Enabled": entry.authenticated = parts[1] == "1" || parts[1].lowercased() == "yes"
            default: break
            }
        }
        return entry
    }

    /// Список исключений или фраза «There aren't any bypass domains set…».
    static func parseBypass(_ output: String) -> [String] {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count == 1, lines[0].contains(" ") { return [] }
        return lines.filter { !$0.contains(" ") }
    }

    /// Наши исключения плюс те, что пользователь уже настроил сам.
    private static func mergedBypass(_ existing: [String]) -> [String] {
        var result = bypass
        for domain in existing where !result.contains(domain) { result.append(domain) }
        return result
    }

    /// Возвращает ошибки всех шагов, не обрывая остальные: лучше вернуть
    /// всё, что получается, и честно сказать, что не получилось.
    private static func restore(_ snapshot: ServiceSnapshot, on service: String) -> [String] {
        var errors: [String] = []
        errors += restore(snapshot.socks, set: "-setsocksfirewallproxy", state: "-setsocksfirewallproxystate", on: service)
        errors += restore(snapshot.web, set: "-setwebproxy", state: "-setwebproxystate", on: service)
        errors += restore(snapshot.secureWeb, set: "-setsecurewebproxy", state: "-setsecurewebproxystate", on: service)
        do {
            try run(["-setproxybypassdomains", service] + (snapshot.bypass.isEmpty ? ["Empty"] : snapshot.bypass))
        } catch {
            errors.append(error.localizedDescription)
        }
        return errors
    }

    /// Сервер возвращаем, только если он был задан: команда установки
    /// сервера сама включает прокси, поэтому состояние выставляем после неё.
    private static func restore(_ entry: ProxyEntry, set: String, state: String, on service: String) -> [String] {
        var errors: [String] = []
        if !entry.server.isEmpty {
            do { try run([set, service, entry.server, entry.port]) } catch { errors.append(error.localizedDescription) }
        }
        do { try run([state, service, entry.enabled ? "on" : "off"]) } catch { errors.append(error.localizedDescription) }
        return errors
    }

    // MARK: - Сетевые сервисы

    /// Активные сервисы. Отключённые networksetup помечает звёздочкой.
    static func enabledServices() throws -> [String] {
        try listedServices().filter { !$0.hasPrefix("*") }
    }

    /// Все сервисы, включая выключенные (без звёздочки в имени).
    private static func allServices() throws -> [String] {
        try listedServices().map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
    }

    private static func listedServices() throws -> [String] {
        let output = try run(["-listallnetworkservices"])
        return output
            .split(whereSeparator: \.isNewline)
            .dropFirst()                       // строка-заголовок
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Имя → стабильный ID службы. Только чтение, без авторизации.
    private static func serviceIDsByName() -> [String: String] {
        Dictionary(serviceList().map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    private static func serviceNamesByID() -> [String: String] {
        Dictionary(serviceList().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private static func serviceList() -> [(id: String, name: String)] {
        guard let prefs = SCPreferencesCreate(nil, "LifeVPN" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [] }
        return services.compactMap { service in
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let name = SCNetworkServiceGetName(service) as String? else { return nil }
            return (id, name)
        }
    }

    // MARK: - Служебное

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw Failure(message: L.t("Не удалось запустить networksetup: \(error.localizedDescription)", "Could not run networksetup: \(error.localizedDescription)"))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw Failure(message: output.isEmpty
                ? L.t("networksetup вернул код \(process.terminationStatus).", "networksetup returned code \(process.terminationStatus).")
                : output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // networksetup иногда печатает ошибку и всё равно выходит с кодом 0.
        if output.contains("** Error") {
            throw Failure(message: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func persist(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        try Paths.writePrivate(data, to: stateFile)
    }
}
