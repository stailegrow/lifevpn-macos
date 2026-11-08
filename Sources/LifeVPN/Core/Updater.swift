import AppKit
import CryptoKit
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
        let checksum: URL
        /// Подпись издателя (`<архив>.sig`). Без неё автоматическая
        /// установка не выполняется.
        let signature: URL?
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

    /// Проверка сразу при запуске — чтобы ещё до подключения человек увидел,
    /// что программу нужно обновить, — и дальше каждые шесть часов.
    func startAutomaticChecks() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
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
            // Без контрольной суммы обновление не ставим: архив нечем сверить.
            guard let sumAsset = payload.assets.first(where: { $0.name == asset.name + ".sha256" }),
                  let checksum = URL(string: sumAsset.browser_download_url),
                  Self.isOwnReleaseAsset(archive), Self.isOwnReleaseAsset(checksum) else {
                phase = .upToDate
                return
            }

            let signature = payload.assets.first(where: { $0.name == asset.name + ".sig" })
                .flatMap { URL(string: $0.browser_download_url) }
                .flatMap { Self.isOwnReleaseAsset($0) ? $0 : nil }
            let release = Release(version: version, notes: payload.body ?? "",
                                  page: page, archive: archive, checksum: checksum,
                                  signature: signature, size: asset.size)
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
    /// Скачиваем только файлы релизов нашего репозитория и только по https.
    static func isOwnReleaseAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(repository)/releases/download/")
    }

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

        // Контрольная сумма лежит в том же релизе, что и архив, — от подмены
        // релиза она не защищает. Устанавливаем сами только то, что подписано
        // ключом издателя, закреплённым в этой программе.
        guard let signatureURL = release.signature else {
            NSWorkspace.shared.open(release.page)
            phase = .failed(L.t("У релиза нет подписи издателя — автоматическая установка отключена. Страница релиза открыта в браузере.",
                                "The release has no publisher signature — automatic install is disabled. The release page opened in the browser."))
            return
        }

        do {
            phase = .downloading(0)
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("LifeVPN-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let zip = work.appendingPathComponent("LifeVPN.zip")
            let direct: Bool
            do {
                direct = try await downloadWithRetries(release.archive, to: zip)
            } catch {
                // Все попытки исчерпаны — даём скачать вручную.
                NSWorkspace.shared.open(release.page)
                throw UpdateError(L.t("Не удалось скачать обновление (\(error.localizedDescription)). Страница релиза открыта в браузере — можно скачать вручную.",
                                      "Could not download the update (\(error.localizedDescription)). The release page opened in the browser — you can download it manually."))
            }

            phase = .installing

            // Сверяем архив с опубликованной контрольной суммой: битую или
            // подменённую загрузку не распаковываем.
            let (sumData, sumResponse) = try await Self.fetchSmall(release.checksum, direct: direct)
            guard (sumResponse as? HTTPURLResponse)?.statusCode == 200,
                  let expected = String(data: sumData, encoding: .utf8)?
                    .split(whereSeparator: { $0.isWhitespace }).first.map({ $0.lowercased() }),
                  expected.count == 64 else {
                throw UpdateError(L.t("не удалось получить контрольную сумму архива", "could not fetch the archive checksum"))
            }
            let actual = try Self.sha256(of: zip)
            guard actual == expected else {
                throw UpdateError(L.t("контрольная сумма архива не совпала — обновление не установлено",
                                      "the archive checksum does not match — the update was not installed"))
            }
            let (sigData, sigResponse) = try await Self.fetchSmall(signatureURL, direct: direct)
            guard (sigResponse as? HTTPURLResponse)?.statusCode == 200,
                  let sigText = String(data: sigData, encoding: .utf8),
                  let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  UpdateSignature.verify(signature, product: "lifevpn-macos", version: release.version, sha256: actual) else {
                throw UpdateError(L.t("подпись издателя не прошла проверку — обновление не установлено",
                                      "the publisher signature did not verify — the update was not installed"))
            }

            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

            let apps = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                .filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first,
                  let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true else {
                throw UpdateError(L.t("в архиве нет приложения", "the archive holds no app"))
            }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw UpdateError(L.t("в архиве чужое приложение", "the archive holds a different app"))
            }
            guard info?["CFBundleShortVersionString"] as? String == release.version else {
                throw UpdateError(L.t("версия в архиве не совпадает с релизом", "the archive's version does not match the release"))
            }
            // Подпись приложения должна быть целой: если в нём что-то поменяли
            // после сборки, codesign это заметит.
            do {
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            } catch {
                throw UpdateError(L.t("подпись приложения в архиве нарушена", "the app's signature in the archive is broken"))
            }
            try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            try Self.launchSwap(newApp: app, target: target)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Хранилище файлов GitHub временами отвечает 503/504 или не отвечает
    /// вовсе, а путь через VPN-сервер может быть хуже прямого. Поэтому:
    /// две попытки обычным путём (через системный прокси, если VPN включён),
    /// затем две — напрямую, мимо прокси, с паузами между ними. Подлинность
    /// не зависит от пути: архив всё равно сверяется с подписью издателя.
    /// Возвращает, был ли успешный путь прямым.
    private func downloadWithRetries(_ url: URL, to destination: URL) async throws -> Bool {
        let plan: [(direct: Bool, delay: UInt64)] = [(false, 0), (false, 2), (true, 3), (true, 6)]
        var lastError: Error = UpdateError(L.t("загрузка не удалась", "the download failed"))
        for step in plan {
            if step.delay > 0 { try await Task.sleep(nanoseconds: step.delay * 1_000_000_000) }
            phase = .downloading(0)
            do {
                try await Downloader.fetch(url, to: destination, direct: step.direct) { [weak self] fraction in
                    Task { @MainActor in self?.phase = .downloading(fraction) }
                }
                return step.direct
            } catch {
                lastError = error
                guard Self.isRetryable(error) else { throw error }
            }
        }
        throw lastError
    }

    /// Повторяем только сетевые сбои и ответы 408/429/5xx.
    nonisolated static func isRetryable(_ error: Error) -> Bool {
        if let update = error as? UpdateError { return update.retryable }
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
             .badServerResponse, .resourceUnavailable, .internationalRoamingOff:
            return true
        default:
            return false
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

    /// Маленький файл релиза (контрольная сумма, подпись): только HTTPS на
    /// каждом перенаправлении и не больше 64 КиБ.
    private static func fetchSmall(_ url: URL, direct: Bool = false) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        if direct { configuration.connectionProxyDictionary = [:] }
        let session = URLSession(configuration: configuration,
                                 delegate: SubscriptionFetcher.SecureRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard data.count <= 64 * 1024 else { throw UpdateError(L.t("файл релиза слишком большой", "the release file is too large")) }
        return (data, response)
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
    /// Сбой на стороне сервера/сети, который имеет смысл повторить.
    var retryable = false
    init(_ message: String, retryable: Bool = false) {
        self.message = message
        self.retryable = retryable
    }

    /// Ответ сервера, который стоит повторить: 408, 429 и 5xx.
    static func isRetryableStatus(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500...599).contains(code)
    }
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

    /// `direct` — мимо системного прокси (то есть мимо VPN, если он включён).
    static func fetch(_ url: URL, to destination: URL, direct: Bool = false,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Downloader(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.default
        // Нет данных минуту — считаем соединение зависшим и идём на повтор.
        configuration.timeoutIntervalForRequest = 60
        if direct { configuration.connectionProxyDictionary = [:] }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    /// Перенаправления GitHub на хранилище файлов — только по HTTPS.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
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
                throw UpdateError(L.t("сервер ответил кодом \(http.statusCode)", "the server answered with code \(http.statusCode)"),
                                  retryable: UpdateError.isRetryableStatus(http.statusCode))
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

/// Подпись обновлений ключом издателя Life VPN (Ed25519).
///
/// Публичный ключ закреплён в программе; закрытый хранится у издателя и в
/// секрете сборочного workflow. Ключ, пришедший вместе с обновлением,
/// доверием не считается. Подписывается строка
/// `LifeVPN-update-v1\n<продукт>\n<версия>\n<sha256 архива>\n`.
enum UpdateSignature {
    static let publicKeyBase64 = "z96lge0uLd3Kmr/kGidg+hI9cH0f5IblP3ukfi32VHs="

    static func message(product: String, version: String, sha256: String) -> Data {
        Data("LifeVPN-update-v1\n\(product)\n\(version)\n\(sha256.lowercased())\n".utf8)
    }

    static func verify(_ signature: Data, product: String, version: String, sha256: String,
                       publicKey: String = publicKeyBase64) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: message(product: product, version: version, sha256: sha256))
    }
}
