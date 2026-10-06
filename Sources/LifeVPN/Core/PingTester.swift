import Darwin
import Foundation

/// Замер задержки до сервера обычным TCP-подключением.
///
/// Это не ICMP-пинг: меряем время до установления TCP-соединения с портом
/// сервера. Для прокси такой замер честнее — он проверяет ровно тот порт,
/// через который пойдёт трафик, и не требует прав.
enum PingTester {

    /// Одиночный замер врёт: в первую попытку попадает резолв имени, а
    /// параллельные замеры мешают друг другу. Поэтому греем соединение,
    /// делаем несколько попыток и берём медиану.
    ///
    /// Именно медиану, а не минимум: минимум максимально чувствителен к
    /// единственному ложному замеру, и одна нулевая попытка обнуляла бы
    /// весь результат. Медиана такой выброс просто игнорирует.
    /// `warmup` и `samples` снижаются для фонового опроса: там важнее не
    /// греть сеть каждые десять секунд, чем выжать последнюю миллисекунду
    /// точности. Ручной замер идёт в полном режиме.
    static func latency(host: String,
                        port: Int,
                        samples: Int = 3,
                        timeout: TimeInterval = 4,
                        warmup: Bool = true) async -> Int? {

        // Прогрев: его результат выбрасываем, он оплачивает резолв имени.
        if warmup {
            _ = await attempt(host: host, port: port, timeout: timeout)
        }

        var values: [Int] = []
        for index in 0..<max(1, samples) {
            if Task.isCancelled { break }
            if let value = await attempt(host: host, port: port, timeout: timeout), value >= 1 {
                values.append(value)
            }
            if index < samples - 1 {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        guard !values.isEmpty else { return nil }
        return median(values)
    }

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func attempt(host: String, port: Int, timeout: TimeInterval) async -> Int? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: connect(host: host, port: port, timeout: timeout))
            }
        }
    }

    /// Подключение самым низким уровнем, какой есть: сокет BSD.
    ///
    /// Высокоуровневые клиенты на маке уважают системные настройки прокси —
    /// а его как раз включает наше собственное подключение. В результате
    /// «замер до узла» на деле мерил путь до локального порта прокси и
    /// показывал всем узлам одинаковые две-три миллисекунды. Голый сокет
    /// про прокси не знает ничего и идёт ровно туда, куда сказано.
    private static func connect(host: String, port: Int, timeout: TimeInterval) -> Int? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            if let elapsed = connect(to: address.pointee, timeout: timeout) { return elapsed }
            candidate = address.pointee.ai_next
        }
        return nil
    }

    /// Неблокирующее подключение с ожиданием на poll: обычный connect не
    /// умеет тайм-аута короче системного, а он измеряется десятками секунд.
    private static func connect(to address: addrinfo, timeout: TimeInterval) -> Int? {
        let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var enabled: Int32 = 1
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }

        let started = DispatchTime.now()
        let result = Darwin.connect(descriptor, address.ai_addr, address.ai_addrlen)

        if result == 0 { return milliseconds(since: started) }
        guard errno == EINPROGRESS else { return nil }

        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = withUnsafeMutablePointer(to: &descriptorSet) {
            poll($0, 1, Int32(timeout * 1000))
        }
        guard ready > 0 else { return nil }

        // poll сообщает только «можно писать»; удалось ли подключение —
        // спрашиваем у самого сокета.
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 else {
            return nil
        }
        return milliseconds(since: started)
    }

    private static func milliseconds(since start: DispatchTime) -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return max(1, Int(elapsed / 1_000_000))
    }
}

/// Как красить значение задержки.
enum PingQuality {
    case good, fair, poor

    init(ms: Int) {
        switch ms {
        case ..<120:  self = .good
        case ..<250:  self = .fair
        default:      self = .poor
        }
    }
}
