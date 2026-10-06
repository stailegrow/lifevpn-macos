import Foundation

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var isBusy: Bool { self == .connecting }
    var isConnected: Bool { self == .connected }
}

/// Стейт-машина подключения.
///
/// Интерфейс знает только про `state`, `activeServer` и `externalIP`. Как
/// именно заворачивается трафик — системный прокси сейчас, TUN на этапе 4 —
/// прячется здесь и наверх не протекает.
@MainActor
final class ConnectionManager: ObservableObject {

    /// Один экземпляр на приложение: снимать системный прокси при выходе
    /// приходится из делегата NSApplication, у которого нет доступа к SwiftUI-окружению.
    static let shared = ConnectionManager()

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var activeServer: ProxyConfig?
    @Published private(set) var externalIP: String?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var recoveredFromCrash = false
    /// Заметка о том, что правила применились не полностью, — показываем
    /// её отдельно от ошибки: соединение при этом рабочее.
    @Published private(set) var routingNotice: String?
    @Published private(set) var isPreparingRules = false

    @Published private(set) var speed: SpeedTester.Result?
    @Published private(set) var speedError: String?
    @Published private(set) var isMeasuringSpeed = false

    /// Порты живут в настройках; здесь только снимок на время сессии,
    /// чтобы правка настроек не рвала уже поднятое соединение.
    private(set) var socksPort: Int = 10808
    private(set) var httpPort: Int = 10809

    private let core = XrayProcess()
    private var proxyApplied = false

    init() {
        core.onUnexpectedExit = { [weak self] code in
            self?.handleCoreCrash(code: code)
        }
        // Прошлый запуск мог оставить системный прокси включённым.
        // В демо системный прокси не трогаем вовсе: рядом может работать
        // настоящая копия приложения с поднятым туннелем.
        recoveredFromCrash = DemoMode.isOn ? false : SystemProxy.cleanUpAfterCrash()
    }

    // MARK: - Подключение

    func connect(to server: ProxyConfig) async {
        if DemoMode.isOn {
            state = .connecting
            try? await Task.sleep(for: .seconds(1.2))
            activeServer = server
            connectedSince = Date().addingTimeInterval(-2_537)
            state = .connected
            return
        }
        if state.isConnected || state.isBusy { await disconnect() }

        socksPort = AppSettings.shared.socksPort
        httpPort = AppSettings.shared.httpPort

        state = .connecting
        activeServer = server
        externalIP = nil
        routingNotice = nil
        speed = nil
        speedError = nil

        let routing = await resolvedRouting()

        do {
            let options = XrayConfigBuilder.Options(
                socksPort: socksPort,
                httpPort: httpPort,
                logLevel: "warning",
                logPath: Paths.coreLog.path,
                routing: routing
            )
            let json = try XrayConfigBuilder.makeJSON(for: server, options: options)
            try json.write(to: Paths.generatedConfig, options: .atomic)

            try core.start(configPath: Paths.generatedConfig, logPath: Paths.coreLog)

            // Ядро с битым конфигом умирает почти мгновенно — ловим это здесь,
            // чтобы не успеть перевести систему на неработающий прокси.
            try await Task.sleep(for: .milliseconds(700))
            guard core.isRunning else {
                let log = XrayProcess.readLog(at: Paths.coreLog)
                throw XrayProcess.Failure.exitedImmediately(code: 1, log: log)
            }

            let ip = await IPChecker.externalIP(viaHTTPProxyPort: httpPort)
            guard let ip else {
                let log = XrayProcess.readLog(at: Paths.coreLog)
                throw Failure.noTunnel(log: log)
            }

            try SystemProxy.enable(socksPort: socksPort, httpPort: httpPort)
            proxyApplied = true

            externalIP = ip
            connectedSince = Date()
            state = .connected

        } catch {
            await tearDown()
            connectedSince = nil
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        if DemoMode.isOn {
            state = .disconnected
            activeServer = nil
            connectedSince = nil
            return
        }
        await tearDown()
        state = .disconnected
        externalIP = nil
        connectedSince = nil
        speed = nil
        speedError = nil
    }

    func toggle(_ server: ProxyConfig) async {
        if state.isConnected, activeServer?.id == server.id {
            await disconnect()
        } else {
            await connect(to: server)
        }
    }

    /// Вызывается при выходе из приложения: системный прокси обязан быть снят,
    /// иначе пользователь останется без интернета.
    func shutdownSynchronously() {
        if proxyApplied {
            SystemProxy.disable()
            proxyApplied = false
        }
        core.stop()
    }

    // MARK: - Скорость

    /// Меряем через прокси, когда туннель поднят, и напрямую, когда нет —
    /// так одна и та же кнопка отвечает на оба вопроса: какой канал вообще
    /// и сколько от него остаётся под VPN.
    func measureSpeed() async {
        if DemoMode.isOn {
            isMeasuringSpeed = true
            try? await Task.sleep(for: .seconds(1.5))
            speed = SpeedTester.Result(mbps: 487.3, bytes: 243_650_000, seconds: 4.0,
                                       throughProxy: state.isConnected, source: "Cloudflare",
                                       measuredAt: Date())
            speedError = nil
            isMeasuringSpeed = false
            return
        }
        guard !isMeasuringSpeed else { return }
        isMeasuringSpeed = true
        speedError = nil
        defer { isMeasuringSpeed = false }

        do {
            speed = try await SpeedTester.measure(viaHTTPProxyPort: state.isConnected ? httpPort : nil)
        } catch {
            speed = nil
            speedError = error.localizedDescription
        }
    }

    /// Возвращает правила, с которыми реально можно стартовать.
    ///
    /// Пресет с обходом РФ опирается на geo-базы. Если их нет, пробуем
    /// скачать; не вышло — честно откатываемся на глобальный режим и
    /// говорим об этом, вместо того чтобы уронить ядро на отсутствующем файле.
    private func resolvedRouting() async -> RoutingConfig {
        let requested = AppSettings.shared.routing
        guard requested.needsGeoAssets, !GeoAssets.isReady else { return requested }

        isPreparingRules = true
        defer { isPreparingRules = false }

        do {
            try await GeoAssets.download(geositeURL: requested.geositeURL.isEmpty
                                            ? GeoAssets.defaultGeositeURL : requested.geositeURL,
                                         geoipURL: requested.geoipURL.isEmpty
                                            ? GeoAssets.defaultGeoipURL : requested.geoipURL)
            return requested
        } catch {
            routingNotice = L.t("Базы правил не загрузились (\(error.localizedDescription)). ", "Routing databases failed to load (\(error.localizedDescription)). ")
                + L.t("Подключаюсь без обхода — весь трафик пойдёт через VPN.", "Connecting without bypass — all traffic will go through the VPN.")
            return RoutingPreset.global.make()
        }
    }

    // MARK: - Служебное

    private func tearDown() async {
        if proxyApplied {
            SystemProxy.disable()
            proxyApplied = false
        }
        core.stop()
    }

    private func handleCoreCrash(code: Int32) {
        guard state.isConnected || state.isBusy else { return }
        if proxyApplied {
            SystemProxy.disable()
            proxyApplied = false
        }
        let log = XrayProcess.readLog(at: Paths.coreLog, lines: 8)
        externalIP = nil
        connectedSince = nil
        state = .failed(log.isEmpty
            ? L.t("Ядро неожиданно завершилось (код \(code)).", "The core exited unexpectedly (code \(code)).")
            : L.t("Ядро неожиданно завершилось (код \(code)):\n\(log)", "The core exited unexpectedly (code \(code)):\n\(log)"))
    }

    enum Failure: LocalizedError {
        case noTunnel(log: String)

        var errorDescription: String? {
            switch self {
            case .noTunnel(let log):
                let tail = log.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
                let base = L.t("Ядро запустилось, но трафик через него не идёт — внешний IP получить не удалось.", "The core started, but no traffic goes through it — the external IP could not be obtained.")
                return tail.isEmpty ? base : base + "\n\n" + tail
            }
        }
    }
}
