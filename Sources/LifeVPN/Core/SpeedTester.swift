import Foundation

/// Замер скорости скачивания.
///
/// Меряем не «сколько заняла загрузка файла», а установившуюся скорость
/// потока. Разница принципиальная: в время загрузки небольшого файла
/// попадают резолв имени, рукопожатие TLS и разгон TCP, и на быстром
/// канале они занимают бо́льшую часть замера — цифра выходит заниженной
/// и пляшет от раза к разу.
///
/// Поэтому: запрашиваем заведомо большой поток, первые секунды выбрасываем,
/// считаем скорость на оставшемся окне и обрываем загрузку. Данные при этом
/// нигде не копятся — счётчик видит их на лету.
enum SpeedTester {

    struct Result: Sendable, Equatable {
        var mbps: Double
        var bytes: Int
        var seconds: Double
        var throughProxy: Bool
        var source: String
        var measuredAt: Date

        var display: String { String(format: "%.1f", mbps) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Разгон выбрасываем, затем меряем на этом окне.
    private static let warmUp: Duration = .milliseconds(900)
    private static let window: Duration = .seconds(4)

    private struct Source: Sendable {
        let name: String
        let url: String
    }

    /// Три источника, которые дополняют друг друга, и порядок здесь важен.
    ///
    /// Cloudflare первым: сам сервис в России не блокируют, но его защита
    /// от ботов режет запросы с адресов дата-центров — то есть он почти
    /// всегда проходит без туннеля и может не пройти через него. Hetzner —
    /// ровно наоборот: его подсети massово используют под прокси и часть
    /// операторов рубит их напрямую, зато через туннель запрос приходит
    /// из дата-центра и проблем не встречает. CacheFly — третий, на случай
    /// если оба первых откажут разом на конкретной сети.
    ///
    /// Объёмы заведомо избыточные — до конца мы их всё равно не качаем.
    private static let sources = [
        Source(name: "Cloudflare", url: "https://speed.cloudflare.com/__down?bytes=104857600"),
        Source(name: "Hetzner", url: "https://fsn1-speed.hetzner.com/100MB.bin"),
        Source(name: "CacheFly", url: "https://cachefly.cachefly.net/100mb.test")
    ]

    static func measure(viaHTTPProxyPort port: Int?) async throws -> Result {
        var lastMessage = L.t("Ни одно зеркало не ответило.", "No mirror responded.")

        for source in sources {
            guard let url = URL(string: source.url) else { continue }
            do {
                return try await run(url: url, source: source, port: port)
            } catch let failure as Failure {
                lastMessage = "\(source.name): \(failure.message)"
            } catch {
                lastMessage = "\(source.name): \(error.localizedDescription)"
            }
        }
        throw Failure(message: lastMessage)
    }

    private static func run(url: URL, source: Source, port: Int?) async throws -> Result {
        let counter = Counter()
        let session = URLSession(configuration: configuration(port: port),
                                 delegate: counter,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // Строка агента — обычная браузерная, без имени приложения.
        // Cloudflare (и не он один) блокирует незнакомые сигнатуры клиентов
        // раньше, чем запрос доходит до раздачи тестовых байт: собственное
        // имя в User-Agent стабильно давало 403.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                         + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request)
        task.resume()

        try? await Task.sleep(for: warmUp)
        let base = counter.snapshot

        // Ждём окно, но не дольше, чем длится сама загрузка.
        var waited: Duration = .zero
        let step: Duration = .milliseconds(200)
        while waited < window, !counter.isFinished {
            try? await Task.sleep(for: step)
            waited += step
        }

        let end = counter.snapshot
        task.cancel()

        if let status = counter.statusCode, !(200..<300).contains(status) {
            throw Failure(message: L.t("ответ с кодом \(status)", "replied with code \(status)"))
        }

        let bytes = end.bytes - base.bytes
        let seconds = end.at - base.at

        guard bytes > 0, seconds > 0.4 else {
            throw Failure(message: counter.errorMessage ?? L.t("поток оборвался, мерить нечего", "the stream broke off, nothing to measure"))
        }

        return Result(mbps: Double(bytes) * 8 / seconds / 1_000_000,
                      bytes: bytes,
                      seconds: seconds,
                      throughProxy: port != nil,
                      source: source.name,
                      measuredAt: Date())
    }

    private static func configuration(port: Int?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Перебор источников имеет смысл только если отказ виден быстро:
        // заблокированный хост обычно молчит, и ждать на нём двадцать
        // секунд — значит потратить минуту на три источника. Шесть секунд
        // без единого байта — уже отказ; на живой, пусть и медленной сети
        // байты идут чаще.
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = false
        if let port {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port
            ]
        } else {
            configuration.connectionProxyDictionary = [:]
        }
        return configuration
    }

    /// Считает байты на лету и никуда их не складывает.
    ///
    /// Делегат зовут с фоновой очереди, поэтому состояние закрыто замком,
    /// а сам класс помечен @unchecked: компилятор этого сам не докажет.
    private final class Counter: NSObject, URLSessionDataDelegate, @unchecked Sendable {

        struct Snapshot {
            var bytes: Int
            /// Секунды с момента старта отсчёта.
            var at: Double
        }

        private let lock = NSLock()
        private let started = DispatchTime.now()
        private var received = 0
        private var finished = false
        private var status: Int?
        private var failure: String?

        var snapshot: Snapshot {
            lock.lock(); defer { lock.unlock() }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
            return Snapshot(bytes: received, at: elapsed / 1_000_000_000)
        }

        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        var statusCode: Int? { lock.lock(); defer { lock.unlock() }; return status }
        var errorMessage: String? { lock.lock(); defer { lock.unlock() }; return failure }

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                lock.lock(); status = http.statusCode; lock.unlock()
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            received += data.count
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            finished = true
            // Отмену считаем штатным завершением: мы сами обрываем поток.
            if let error, (error as NSError).code != NSURLErrorCancelled {
                failure = error.localizedDescription
            }
            lock.unlock()
        }
    }
}
