import Foundation

/// Управление системными настройками прокси через `networksetup`.
///
/// Список задействованных сервисов запоминаем на диске: если приложение
/// упадёт с включённым прокси, при следующем запуске мы должны знать, где
/// его выключать, иначе пользователь останется без интернета.
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

    // MARK: - Прежние настройки

    /// Настройки одного вида прокси (SOCKS, HTTP или HTTPS) до подключения.
    struct ProxyEntry: Codable, Equatable {
        var enabled: Bool
        var server: String
        var port: String
    }

    /// Всё, что меняем у одного сетевого сервиса, — чтобы вернуть как было:
    /// корпоративный прокси или свои исключения пользователя не должны
    /// пропадать после отключения VPN.
    struct ServiceSnapshot: Codable, Equatable {
        var socks: ProxyEntry
        var web: ProxyEntry
        var secureWeb: ProxyEntry
        var bypass: [String]
    }

    /// Содержимое proxy-state.json. До 3.1.4 там лежал просто список
    /// сервисов — такой файл тоже читается (тогда прокси просто выключаются).
    struct State: Codable {
        var services: [String: ServiceSnapshot]
    }

    // MARK: - Включение и выключение

    static func enable(socksPort: Int, httpPort: Int) throws {
        let services = try enabledServices()
        guard !services.isEmpty else {
            throw Failure(message: L.t("Не найдено ни одного активного сетевого сервиса.", "No active network service was found."))
        }

        // Снимок прежних настроек пишем ДО любых изменений: если процесс
        // умрёт на середине, при следующем запуске будет что восстановить.
        // Если файл уже есть (прошлый сеанс не прибрался), в нём настоящие
        // исходные настройки — поверх них наши значения не записываем.
        var state = (try? persistedState()) ?? State(services: [:])
        for service in services where state.services[service] == nil {
            state.services[service] = try snapshot(of: service)
        }
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
            // Часть команд уже могла пройти — возвращаем всё как было, чтобы
            // после остановки ядра не остаться с прокси в пустоту.
            disable()
            throw error
        }
    }

    /// Возвращает настройки прокси к тем, что были до подключения.
    static func disable() {
        if let state = try? persistedState() {
            for (service, snapshot) in state.services {
                restore(snapshot, on: service)
            }
        } else {
            // Старый формат файла или его нет: просто выключаем наши прокси.
            let services = (try? legacyPersistedServices()) ?? []
            let targets = services.isEmpty ? ((try? enabledServices()) ?? []) : services
            for service in targets {
                _ = try? run(["-setsocksfirewallproxystate", service, "off"])
                _ = try? run(["-setwebproxystate", service, "off"])
                _ = try? run(["-setsecurewebproxystate", service, "off"])
            }
        }
        try? FileManager.default.removeItem(at: stateFile)
    }

    /// Прошлый запуск оставил прокси включённым — прибираемся на старте.
    static func cleanUpAfterCrash() -> Bool {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return false }
        disable()
        return true
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

    /// Ответ networksetup вида «Enabled: Yes / Server: … / Port: …».
    static func parseEntry(_ output: String) -> ProxyEntry {
        var entry = ProxyEntry(enabled: false, server: "", port: "0")
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": entry.enabled = parts[1].lowercased() == "yes"
            case "Server":  entry.server = parts[1]
            case "Port":    entry.port = parts[1]
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

    private static func restore(_ snapshot: ServiceSnapshot, on service: String) {
        restore(snapshot.socks, set: "-setsocksfirewallproxy", state: "-setsocksfirewallproxystate", on: service)
        restore(snapshot.web, set: "-setwebproxy", state: "-setwebproxystate", on: service)
        restore(snapshot.secureWeb, set: "-setsecurewebproxy", state: "-setsecurewebproxystate", on: service)
        _ = try? run(["-setproxybypassdomains", service] + (snapshot.bypass.isEmpty ? ["Empty"] : snapshot.bypass))
    }

    /// Сервер возвращаем, только если он был задан: команда установки
    /// сервера сама включает прокси, поэтому состояние выставляем после неё.
    private static func restore(_ entry: ProxyEntry, set: String, state: String, on service: String) {
        if !entry.server.isEmpty {
            _ = try? run([set, service, entry.server, entry.port])
        }
        _ = try? run([state, service, entry.enabled ? "on" : "off"])
    }

    // MARK: - Сетевые сервисы

    /// Активные сервисы. Отключённые networksetup помечает звёздочкой.
    static func enabledServices() throws -> [String] {
        let output = try run(["-listallnetworkservices"])
        return output
            .split(whereSeparator: \.isNewline)
            .dropFirst()                       // строка-заголовок
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
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
        return output
    }

    private static func persist(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateFile, options: .atomic)
    }

    private static func persistedState() throws -> State {
        let data = try Data(contentsOf: stateFile)
        return try JSONDecoder().decode(State.self, from: data)
    }

    private static func legacyPersistedServices() throws -> [String] {
        let data = try Data(contentsOf: stateFile)
        return try JSONDecoder().decode([String].self, from: data)
    }
}
