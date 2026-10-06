import Foundation

/// Итог сверки списка серверов подписки с тем, что пришло с панели.
struct ServerMergeResult: Sendable {
    var servers: [ProxyConfig]
    var added: Int
    var removed: Int
    var kept: Int
}

/// Серверы и подписки на диске.
@MainActor
final class ServerStore: ObservableObject {

    /// Один экземпляр на приложение: автообновление подписок должно жить,
    /// пока живёт процесс, а не пока открыто окно.
    static let shared = ServerStore()

    @Published private(set) var servers: [ProxyConfig] = []
    @Published private(set) var subscriptions: [Subscription] = []
    @Published var selectedID: ProxyConfig.ID?
    @Published private(set) var refreshingIDs: Set<Subscription.ID> = []

    /// Задержка до сервера в миллисекундах. nil в значении — сервер не ответил.
    @Published private(set) var pings: [ProxyConfig.ID: Int?] = [:]
    /// История замеров для графиков. Хвост, самое свежее — последнее.
    @Published private(set) var pingHistory: [ProxyConfig.ID: [Int]] = [:]
    @Published private(set) var isPinging = false

    static let historyLength = 24

    private struct Payload: Codable {
        var version: Int = 2
        var servers: [ProxyConfig]
        var subscriptions: [Subscription] = []
        var selectedID: ProxyConfig.ID?
        /// Ключ — uuidString: словари с нестроковыми ключами Codable
        /// раскладывает в плоский массив, и файл становится нечитаемым.
        var pingHistory: [String: [Int]] = [:]
    }

    private var autoRefreshTask: Task<Void, Never>?
    private var autoPingTask: Task<Void, Never>?

    init() {
        if DemoMode.isOn { loadDemo() } else { load() }
    }

    private var demoStep = 0

    private func loadDemo() {
        let subscription = DemoMode.subscription()
        subscriptions = [subscription]
        servers = DemoMode.servers(in: subscription)
        selectedID = servers.first?.id
        for step in 0..<Self.historyLength {
            for server in servers { record(server.id, DemoMode.latency(for: server, step: step)) }
        }
        demoStep = Self.historyLength
    }

    /// Проверяет расписание раз в четверть часа. Сам интервал обновления
    /// у каждой подписки свой — здесь только тик, решает `isDue`.
    func startAutoRefresh() {
        guard autoRefreshTask == nil, !DemoMode.isOn else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    var selected: ProxyConfig? {
        guard let selectedID else { return nil }
        return servers.first { $0.id == selectedID }
    }

    func servers(in subscription: Subscription?) -> [ProxyConfig] {
        servers.filter { $0.subscriptionID == subscription?.id }
    }

    var manualServers: [ProxyConfig] { servers.filter { $0.subscriptionID == nil } }

    func subscription(for server: ProxyConfig) -> Subscription? {
        guard let id = server.subscriptionID else { return nil }
        return subscriptions.first { $0.id == id }
    }

    // MARK: - Ручное добавление

    @discardableResult
    func add(_ incoming: [ProxyConfig]) -> Int {
        var added = 0
        let existingKeys = Set(servers.map(\.identityKey))
        for config in incoming where !existingKeys.contains(config.identityKey) {
            servers.append(config)
            added += 1
        }
        if selectedID == nil { selectedID = servers.first?.id }
        if added > 0 { save() }
        return added
    }

    func remove(_ ids: Set<ProxyConfig.ID>) {
        servers.removeAll { ids.contains($0.id) }
        if let selectedID, ids.contains(selectedID) {
            self.selectedID = servers.first?.id
        }
        save()
    }

    // MARK: - Быстрое добавление

    enum QuickAddResult: Sendable {
        case subscription(name: String, servers: Int)
        case servers(Int)
        case failure(String)

        var message: String {
            switch self {
            case .subscription(let name, let count): return L.t("Подписка «\(name)» — узлов: \(count)", "Subscription “\(name)” — \(count) nodes")
            case .servers(let count):
                return count == 0 ? L.t("Новых узлов нет — всё это уже добавлено.", "No new nodes — all of this is already added.") : L.t("Добавлено узлов: \(count)", "Nodes added: \(count)")
            case .failure(let text): return text
            }
        }

        var isFailure: Bool { if case .failure = self { return true }; return false }
    }

    /// Разбирает произвольный текст и делает то, что он означает: ссылка на
    /// подписку — добавляет подписку, ссылки узлов — добавляет узлы.
    /// Гадать, куда вставлять, человеку не нужно.
    func quickAdd(_ raw: String) async -> QuickAddResult {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failure(L.t("Пусто — нечего добавлять.", "Empty — nothing to add.")) }

        let lowered = value.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            let subscription = addSubscription(url: value)
            let ok = await refresh(subscription)
            let stored = subscriptions.first { $0.id == subscription.id }
            guard ok, let stored else {
                let message = stored?.lastError ?? L.t("Не удалось загрузить подписку.", "Could not load the subscription.")
                removeSubscription(subscription.id)
                return .failure(message)
            }
            return .subscription(name: stored.displayName, servers: servers(in: stored).count)
        }

        if value.contains("://") {
            let parsed = LinkParser.parseMany(value)
            guard !parsed.configs.isEmpty else {
                return .failure(parsed.errors.first ?? L.t("Ссылки не распознались.", "The links were not recognised."))
            }
            return .servers(add(parsed.configs))
        }

        return .failure(L.t("Это не похоже ни на ссылку подписки, ни на ссылку узла.", "This looks like neither a subscription link nor a node link."))
    }

    // MARK: - Подписки

    func addSubscription(url: String, name: String = "") -> Subscription {
        var subscription = Subscription()
        subscription.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        subscription.name = name.trimmingCharacters(in: .whitespaces)
        subscriptions.append(subscription)
        save()
        return subscription
    }

    /// Удаляет подписку вместе с её серверами — иначе в списке остаются
    /// висяки, которые больше некому обновлять.
    func removeSubscription(_ id: Subscription.ID) {
        subscriptions.removeAll { $0.id == id }
        let orphans = Set(servers.filter { $0.subscriptionID == id }.map(\.id))
        servers.removeAll { orphans.contains($0.id) }
        if let selectedID, orphans.contains(selectedID) {
            self.selectedID = servers.first?.id
        }
        save()
    }

    func updateSubscription(_ subscription: Subscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index] = subscription
        save()
    }

    @discardableResult
    func refresh(_ subscription: Subscription) async -> Bool {
        if DemoMode.isOn { return true }
        guard !refreshingIDs.contains(subscription.id) else { return false }
        refreshingIDs.insert(subscription.id)
        defer { refreshingIDs.remove(subscription.id) }

        guard var stored = subscriptions.first(where: { $0.id == subscription.id }) else { return false }

        do {
            let payload = try await SubscriptionFetcher.fetch(stored.url)
            let parsed = LinkParser.parseMany(payload.links.joined(separator: "\n")).configs

            let result = Self.merge(existing: servers,
                                    fetched: parsed,
                                    subscriptionID: stored.id)
            servers = result.servers

            if stored.name.isEmpty, let title = payload.title { stored.name = title }
            stored.announce = payload.announce
            stored.rawUserInfo = payload.rawUserInfo
            stored.usedBytes = payload.userInfo.used
            stored.totalBytes = payload.userInfo.total
            stored.expiresAt = payload.userInfo.expiresAt
            if let hours = payload.updateIntervalHours, stored.updateIntervalHours > 0 {
                stored.updateIntervalHours = hours
            }
            stored.lastUpdated = Date()
            stored.lastError = nil

            if selectedID == nil || !servers.contains(where: { $0.id == selectedID }) {
                selectedID = servers.first?.id
            }
        } catch {
            stored.lastError = error.localizedDescription
        }

        if let index = subscriptions.firstIndex(where: { $0.id == stored.id }) {
            subscriptions[index] = stored
        }
        save()
        return stored.lastError == nil
    }

    /// Обновляет всё, что просрочено по расписанию. `force` — обновить всё подряд.
    func refreshDue(force: Bool = false) async {
        guard !DemoMode.isOn else { return }
        for subscription in subscriptions where force || subscription.isDue() {
            await refresh(subscription)
        }
    }

    /// Что происходит при запуске приложения.
    ///
    /// Сначала подписки — чтобы задержку мерить уже по актуальному списку,
    /// а не по узлам, которых на панели больше нет, — и только потом замер.
    /// Человек открывает окно и сразу видит, к какому узлу подключаться.
    func prepareOnLaunch(measureLatency: Bool = true) async {
        guard !DemoMode.isOn else { return }
        await refreshDue(force: true)
        guard measureLatency else { return }
        await pingAll()
    }

    // MARK: - Пинги

    /// Задержка меряется напрямую от этой машины до узла, а не через
    /// поднятый туннель.
    ///
    /// Смысл цифры в списке — «как далеко отсюда до этого узла», и ответ не
    /// должен меняться от того, подключены мы сейчас или нет. Замер через
    /// активное соединение отвечал бы на другой вопрос: «как далеко от
    /// текущего сервера до остальных», и выбирать по такому списку нельзя.
    ///
    /// `light` — режим фонового опроса: одно подключение на узел вместо
    /// четырёх (прогрев плюс три замера) у ручного. На списке в пару
    /// десятков узлов это разница между заметным фоновым трафиком и
    /// незаметным; точность ручного замера при этом не страдает.
    func pingAll(light: Bool = false) async {
        guard !isPinging, !servers.isEmpty else { return }
        if DemoMode.isOn {
            demoStep += 1
            for server in servers { record(server.id, DemoMode.latency(for: server, step: demoStep)) }
            return
        }

        // Фоновый опрос не зажигает индикатор занятости: иначе кнопка
        // ручного замера мигала бы каждые десять секунд сама по себе. И
        // гасить чужой индикатор на выходе он тоже не должен.
        let showsBusy = !light
        if showsBusy { isPinging = true }
        defer { if showsBusy { isPinging = false } }

        let batch = 4
        for chunk in stride(from: 0, to: servers.count, by: batch) {
            let slice = Array(servers[chunk..<min(chunk + batch, servers.count)])
            await withTaskGroup(of: (ProxyConfig.ID, Int?).self) { group in
                for server in slice {
                    let (id, host, port) = (server.id, server.address, server.port)
                    group.addTask {
                        let value = light
                            ? await PingTester.latency(host: host, port: port, samples: 1, warmup: false)
                            : await PingTester.latency(host: host, port: port)
                        return (id, value)
                    }
                }
                for await (id, value) in group { record(id, value) }
            }
        }
        save()
    }

    /// Фоновый опрос, пока открыт экран со списком узлов.
    func startAutoPing(every interval: Duration = .seconds(10)) {
        guard autoPingTask == nil else { return }
        autoPingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.servers.isEmpty {
                    await self.pingAll(light: true)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopAutoPing() {
        autoPingTask?.cancel()
        autoPingTask = nil
    }

    func ping(_ server: ProxyConfig) async {
        if DemoMode.isOn { record(server.id, DemoMode.latency(for: server, step: demoStep)); return }
        let value = await PingTester.latency(host: server.address, port: server.port)
        record(server.id, value)
        save()
    }

    private func record(_ id: ProxyConfig.ID, _ value: Int?) {
        pings.updateValue(value, forKey: id)
        guard let value else { return }
        var history = pingHistory[id] ?? []
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
        pingHistory[id] = history
    }

    // MARK: - Диск

    func save() {
        guard !DemoMode.isOn else { return }
        var history: [String: [Int]] = [:]
        for (id, values) in pingHistory { history[id.uuidString] = values }

        let payload = Payload(servers: servers,
                              subscriptions: subscriptions,
                              selectedID: selectedID,
                              pingHistory: history)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Paths.servers, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.servers),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        servers = payload.servers
        subscriptions = payload.subscriptions
        selectedID = payload.selectedID ?? payload.servers.first?.id

        var history: [ProxyConfig.ID: [Int]] = [:]
        for (key, values) in payload.pingHistory {
            if let id = UUID(uuidString: key) { history[id] = values }
        }
        pingHistory = history
    }
}


extension ServerStore {

    /// Приводит серверы подписки к тому, что пришло с панели.
    ///
    /// Уцелевшим серверам сохраняем id: иначе при каждом обновлении слетал бы
    /// выбор в списке, а активное соединение указывало бы на сервер, которого
    /// с точки зрения приложения больше нет. Остальные поля обновляем —
    /// переименование и смена ключей на панели должны доезжать до клиента.
    ///
    /// nonisolated намеренно: функция чистая, и её гоняют внутренние проверки
    /// вне главного актора.
    nonisolated static func merge(existing: [ProxyConfig],
                                  fetched: [ProxyConfig],
                                  subscriptionID: UUID) -> ServerMergeResult {

        let mine = existing.filter { $0.subscriptionID == subscriptionID }
        var others = existing.filter { $0.subscriptionID != subscriptionID }

        var byKey: [String: ProxyConfig] = [:]
        for server in mine { byKey[server.identityKey] = server }

        var rebuilt: [ProxyConfig] = []
        var added = 0
        var kept = 0
        var matchedKeys: Set<String> = []

        for var incoming in fetched {
            incoming.subscriptionID = subscriptionID
            if let old = byKey[incoming.identityKey] {
                incoming.id = old.id
                matchedKeys.insert(incoming.identityKey)
                kept += 1
            } else {
                added += 1
            }
            rebuilt.append(incoming)
        }

        let removed = mine.filter { !matchedKeys.contains($0.identityKey) }.count

        others.append(contentsOf: rebuilt)
        return ServerMergeResult(servers: others, added: added, removed: removed, kept: kept)
    }
}
