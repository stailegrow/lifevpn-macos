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

    // MARK: - Включение и выключение

    static func enable(socksPort: Int, httpPort: Int) throws {
        let services = try enabledServices()
        guard !services.isEmpty else {
            throw Failure(message: L.t("Не найдено ни одного активного сетевого сервиса.", "No active network service was found."))
        }

        // Пишем состояние ДО применения: если процесс умрёт на середине,
        // след останется и мы сможем убрать за собой.
        try? persist(services)

        for service in services {
            try run(["-setsocksfirewallproxy", service, "127.0.0.1", String(socksPort)])
            try run(["-setsocksfirewallproxystate", service, "on"])
            try run(["-setwebproxy", service, "127.0.0.1", String(httpPort)])
            try run(["-setwebproxystate", service, "on"])
            try run(["-setsecurewebproxy", service, "127.0.0.1", String(httpPort)])
            try run(["-setsecurewebproxystate", service, "on"])
            try run(["-setproxybypassdomains", service] + bypass)
        }
    }

    static func disable() {
        let services = (try? persistedServices()) ?? []
        let targets = services.isEmpty ? ((try? enabledServices()) ?? []) : services

        for service in targets {
            _ = try? run(["-setsocksfirewallproxystate", service, "off"])
            _ = try? run(["-setwebproxystate", service, "off"])
            _ = try? run(["-setsecurewebproxystate", service, "off"])
        }
        try? FileManager.default.removeItem(at: stateFile)
    }

    /// Прошлый запуск оставил прокси включённым — прибираемся на старте.
    static func cleanUpAfterCrash() -> Bool {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return false }
        disable()
        return true
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

    private static func persist(_ services: [String]) throws {
        let data = try JSONEncoder().encode(services)
        try data.write(to: stateFile, options: .atomic)
    }

    private static func persistedServices() throws -> [String] {
        let data = try Data(contentsOf: stateFile)
        return try JSONDecoder().decode([String].self, from: data)
    }
}
