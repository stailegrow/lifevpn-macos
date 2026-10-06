import Foundation

/// Доступ к бандленному бинарнику Xray-core.
///
/// Бинарник лежит в ресурсном бандле SwiftPM, который `package-app.sh` кладёт
/// внутрь `LifeVPN.app/Contents/Resources/`. Здесь же снимаем карантин и
/// возвращаем право на исполнение — после копирования .app на другую машину
/// Gatekeeper иначе откажется запускать вложенный бинарник.
enum XrayBinary {

    enum Failure: LocalizedError {
        case notBundled
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return L.t("Бинарник xray не найден в бандле. Запусти Scripts/fetch-xray.sh и пересобери.", "The xray binary is missing from the bundle. Run Scripts/fetch-xray.sh and rebuild.")
            case .launchFailed(let message):
                return L.t("Не удалось запустить xray: \(message)", "Could not start xray: \(message)")
            }
        }
    }

    static var url: URL? {
        Bundle.module.url(forResource: "xray", withExtension: nil)
    }

    /// Готовит бинарник к запуску: +x и снятие com.apple.quarantine.
    static func prepare() throws {
        guard let url else { throw Failure.notBundled }

        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if mode & 0o111 == 0 {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        // Карантин переживает копирование .app через AirDrop и интернет.
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-d", "com.apple.quarantine", url.path]
        strip.standardOutput = FileHandle.nullDevice
        strip.standardError = FileHandle.nullDevice
        try? strip.run()
        strip.waitUntilExit()
    }

    /// Синхронно выполняет `xray` с заданными аргументами и возвращает stdout.
    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        try prepare()
        guard let url else { throw Failure.notBundled }

        let process = Process()
        process.executableURL = url
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Первая строка вывода `xray version` — например "Xray 26.6.1 (Xray, Penetrates Everything.)".
    static func version() throws -> String {
        let output = try run(["version"])
        let first = output.split(separator: "\n").first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespaces)
    }
}
