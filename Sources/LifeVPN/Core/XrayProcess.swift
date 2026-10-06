import Foundation

/// Запуск и остановка бандленного ядра.
///
/// Вывод уводим прямо в файл, без обработчиков на фоновой очереди: так проще
/// и не приходится тащить не-Sendable FileHandle через границы акторов.
@MainActor
final class XrayProcess {

    enum Failure: LocalizedError {
        case alreadyRunning
        case exitedImmediately(code: Int32, log: String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return L.t("Ядро уже запущено.", "The core is already running.")
            case .exitedImmediately(let code, let log):
                let tail = log.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
                return tail.isEmpty
                    ? L.t("Ядро завершилось сразу с кодом \(code).", "The core exited immediately with code \(code).")
                    : L.t("Ядро завершилось сразу с кодом \(code):\n\(tail)", "The core exited immediately with code \(code):\n\(tail)")
            }
        }
    }

    private var process: Process?
    private var logHandle: FileHandle?

    /// Номер запуска. Обработчик завершения получает его копией и молчит,
    /// если ядро к тому моменту уже перезапустили или остановили сами —
    /// сам объект Process в замыкание тащить нельзя, он не Sendable.
    private var generation = 0

    var isRunning: Bool { process?.isRunning ?? false }

    /// Вызывается, когда ядро упало само — не по нашей команде.
    var onUnexpectedExit: ((Int32) -> Void)?

    func start(configPath: URL, logPath: URL) throws {
        guard !isRunning else { throw Failure.alreadyRunning }

        try XrayBinary.prepare()
        guard let binary = XrayBinary.url else { throw XrayBinary.Failure.notBundled }

        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logPath)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-c", configPath.path]
        process.currentDirectoryURL = Paths.appSupport
        process.standardOutput = handle
        process.standardError = handle

        var environment = ProcessInfo.processInfo.environment
        environment["XRAY_LOCATION_ASSET"] = Paths.geoDir.path
        process.environment = environment

        generation += 1
        let token = generation
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.clear()
                self.onUnexpectedExit?(code)
            }
        }

        try process.run()
        self.process = process
        self.logHandle = handle
    }

    func stop() {
        generation += 1                     // обработчик завершения теперь молчит
        guard let process, process.isRunning else {
            clear()
            return
        }
        self.process = nil

        process.terminate()
        // Даём ядру закрыть соединения; если не успело — добиваем.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        clear()
    }

    private func clear() {
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    /// Хвост лога — то, что показываем при ошибке подключения.
    static func readLog(at url: URL, lines: Int = 40) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}
