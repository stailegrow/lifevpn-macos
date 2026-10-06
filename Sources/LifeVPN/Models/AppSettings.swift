import Foundation

/// Пользовательские настройки. Живут отдельно от списка серверов, чтобы
/// сброс одного не тянул за собой другое.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    @Published var paletteID: String { didSet { save() } }
    /// Язык применяется сразу: L.current читают все строки интерфейса.
    @Published var language: Lang { didSet { L.current = language; save() } }
    @Published var socksPort: Int { didSet { save() } }
    @Published var httpPort: Int { didSet { save() } }
    @Published var autoConnectOnLaunch: Bool { didSet { save() } }
    @Published var pingOnLaunch: Bool { didSet { save() } }
    @Published var backgroundAnimation: Bool { didSet { save() } }
    @Published var routing: RoutingConfig { didSet { save() } }

    var palette: Palette { .named(paletteID) }

    func applyRoutingPreset(_ preset: RoutingPreset) {
        routing = preset.make()
    }

    private struct Payload: Codable {
        var paletteID = Palette.ruby.id
        /// Отметка, что тема «Обсидиана» уже выставлена один раз. Дальше
        /// выбор пользователя не трогаем.
        var obsidianApplied: Bool?
        // Необязательное поле: старый файл настроек без языка должен
        // читаться, а не сбрасывать всё остальное к умолчаниям.
        var language: Lang?
        var socksPort = 10818
        var httpPort = 10819
        var autoConnectOnLaunch = false
        var pingOnLaunch = true
        var backgroundAnimation = true
        var routing = RoutingPreset.bypassRU.make()
    }

    private var isLoading = true

    init() {
        let payload = (try? Data(contentsOf: Paths.settings))
            .flatMap { try? JSONDecoder().decode(Payload.self, from: $0) } ?? Payload()

        // Редизайн «Обсидиан» нарисован под тёмную тему с красным акцентом:
        // при первом запуске новой версии переключаемся на неё один раз.
        let needsObsidian = payload.obsidianApplied != true
        paletteID = needsObsidian ? Palette.ruby.id : payload.paletteID
        language = payload.language ?? .system
        socksPort = payload.socksPort
        httpPort = payload.httpPort
        autoConnectOnLaunch = payload.autoConnectOnLaunch
        pingOnLaunch = payload.pingOnLaunch
        backgroundAnimation = payload.backgroundAnimation
        // В демо — нейтральная маршрутизация с выдуманными доменами: на
        // скриншотах не должно оказаться ничего из настоящих настроек.
        if DemoMode.isOn {
            var demoRouting = RoutingPreset.bypassRU.make()
            demoRouting.directDomains = ["mail.example.com", "wiki.example.com"]
            routing = demoRouting
        } else {
            routing = payload.routing
        }
        isLoading = false
        if needsObsidian { save() }

        // Только когда объект собран целиком: до этого обращаться к
        // собственным свойствам нельзя.
        L.current = language
    }

    private func save() {
        guard !isLoading, !DemoMode.isOn else { return }
        let payload = Payload(paletteID: paletteID,
                              obsidianApplied: true,
                              language: language,
                              socksPort: socksPort,
                              httpPort: httpPort,
                              autoConnectOnLaunch: autoConnectOnLaunch,
                              pingOnLaunch: pingOnLaunch,
                              backgroundAnimation: backgroundAnimation,
                              routing: routing)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Paths.settings, options: .atomic)
    }
}
