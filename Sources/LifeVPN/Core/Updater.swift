import AppKit
import Foundation

/// Обновление из релизов GitHub.
///
/// Раз в несколько часов (и по кнопке в настройках) спрашивает у GitHub
/// последний релиз. Если его версия новее установленной, интерфейс
/// предлагает обновиться. Обновление — скачать архив релиза, распаковать,
/// проверить, что внутри то же приложение нужной версии, и подменить бандл
/// на месте. Подмену делает маленький скрипт, который ждёт, пока
/// приложение закроется (при выходе снимается системный прокси), кладёт
/// новую копию на место старой и запускает её.
///
/// Репозиторий обязан быть публичным: приложение спрашивает GitHub без
/// токена, а встраивать токен в программу нельзя.
@MainActor
final class Updater: ObservableObject {

    static let shared = Updater()

    static let repository = "stailegrow/lifevpn-macos"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let archive: URL
        let size: Int64
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: Release?
    @Published private(set) var lastChecked: Date?

    private var loop: Task<Void, Never>?

    /// Есть ли что предложить пользователю прямо сейчас.
    var hasUpdate: Bool {
        switch phase {
        case .available, .downloading, .installing: return true
        case .failed: return latest != nil
        default: return false
        }
    }

    /// Фоновая проверка: через полминуты после запуска, чтобы не мешать
    /// замеру задержки, и дальше каждые шесть часов.
    func startAutomaticChecks() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: - Проверка

    func check() async {
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        phase = .checking

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LifeVPN/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastChecked = Date()
            if status == 404 {
                // Релизов ещё нет — это не ошибка, просто обновляться не на что.
                latest = nil
                phase = .upToDate
                return
            }
            guard status == 200 else {
                phase = .failed(L.t("GitHub ответил кодом \(status)", "GitHub answered with code \(status)"))
                return
            }

            let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let version = payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            guard let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let archive = URL(string: asset.browser_download_url),
                  let page = URL(string: payload.html_url) else {
                phase = .upToDate
                return
            }

            let release = Release(version: version, notes: payload.body ?? "",
                                  page: page, archive: archive, size: asset.size)
            if Self.isNewer(version, than: AppVersion.short) {
                latest = release
                phase = .available
            } else {
                latest = nil
                phase = .upToDate
            }
        } catch {
            lastChecked = Date()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Сравнение «2.10.0» > «2.9.3» по числам, а не по строкам. Сборка без
    /// Info.plist («dev», запуск через swift run) обновлений не предлагает —
    /// иначе разработческий запуск вечно просил бы обновиться.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard current != "dev" else { return false }
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Установка

    func install() async {
        guard let release = latest else { return }

        let target = Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent()
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: folder.path) else {
            // Нет прав на папку с приложением — отдаём релиз браузеру.
            NSWorkspace.shared.open(release.page)
            phase = .failed(L.t("Нет прав на папку с приложением — архив открыт в браузере.",
                                "No write access to the app's folder — the release opened in the browser."))
            return
        }

        do {
            phase = .downloading(0)
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("LifeVPN-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let zip = work.appendingPathComponent("LifeVPN.zip")
            try await Downloader.fetch(release.archive, to: zip) { [weak self] fraction in
                Task { @MainActor in self?.phase = .downloading(fraction) }
            }

            phase = .installing
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

            guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError(L.t("в архиве нет приложения", "the archive holds no app"))
            }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw UpdateError(L.t("в архиве чужое приложение", "the archive holds a different app"))
            }
            guard info?["CFBundleShortVersionString"] as? String == release.version else {
                throw UpdateError(L.t("версия в архиве не совпадает с релизом", "the archive's version does not match the release"))
            }
            try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            try Self.launchSwap(newApp: app, target: target)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Скрипт подмены живёт отдельно от приложения: ждёт, пока процесс
    /// закроется, переносит старую копию в сторону, ставит новую и запускает
    /// её. Если что-то пошло не так — возвращает старую копию на место.
    private static func launchSwap(newApp: URL, target: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let backup = target.path + ".previous"
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf \(quoted(backup))
        if mv \(quoted(target.path)) \(quoted(backup)) && mv \(quoted(newApp.path)) \(quoted(target.path)); then
          rm -rf \(quoted(backup))
          xattr -dr com.apple.quarantine \(quoted(target.path)) 2>/dev/null
        else
          [ -d \(quoted(backup)) ] && [ ! -d \(quoted(target.path)) ] && mv \(quoted(backup)) \(quoted(target.path))
        fi
        open \(quoted(target.path))
        """
        let scriptURL = newApp.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // nohup и фон: скрипт не должен умереть вместе с приложением.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/bash \(quoted(scriptURL.path)) >/dev/null 2>&1 &"]
        try process.run()
        process.waitUntilExit()
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(L.t("\(URL(fileURLWithPath: tool).lastPathComponent) завершился с ошибкой",
                                  "\(URL(fileURLWithPath: tool).lastPathComponent) failed"))
        }
    }

    private struct ReleasePayload: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64
        }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Скачивание с прогрессом. Обычный async-вариант URLSession прогресса не
/// отдаёт, а архив весит десятки мегабайт — без полоски кажется, что всё
/// зависло.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Downloader(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError(L.t("сервер ответил кодом \(http.statusCode)", "the server answered with code \(http.statusCode)"))
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
