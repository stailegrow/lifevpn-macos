import AppKit
import SwiftUI

// MARK: - Маршрутизация

/// Что идёт через туннель, а что — напрямую. Раньше жило карточкой внутри
/// настроек; в «Обсидиане» это отдельный раздел боковой панели.
struct RoutingTab: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var settings: AppSettings

    @State private var isUpdatingGeo = false
    @State private var geoError: String?
    @State private var isEditingDomains = false

    var body: some View {
        ScrollView {
            VStack(spacing: UI.s(14)) {
                presetsCard
                HStack(alignment: .top, spacing: UI.s(14)) {
                    domainsCard
                    geoCard
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, UI.s(14))
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $isEditingDomains) {
            DirectDomainsSheet()
                .environmentObject(settings)
                .environment(\.palette, palette)
        }
    }

    private var presetsCard: some View {
        Card(title: L.t("Режим", "Mode")) {
            VStack(spacing: UI.s(8)) {
                ForEach(RoutingPreset.all) { preset in
                    let isOn = settings.routing.presetID == preset.id
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { settings.applyRoutingPreset(preset) }
                    } label: {
                        HStack(alignment: .center, spacing: UI.s(12)) {
                            ZStack {
                                Circle()
                                    .strokeBorder(isOn ? palette.accent : palette.textSecondary.opacity(0.5), lineWidth: 1.5)
                                if isOn {
                                    Circle().fill(palette.accentGradient).padding(UI.s(4))
                                }
                            }
                            .frame(width: UI.s(18), height: UI.s(18))

                            VStack(alignment: .leading, spacing: UI.s(2)) {
                                Text(preset.title)
                                    .font(Typography.heading(12.5))
                                    .foregroundStyle(palette.textPrimary)
                                Text(preset.subtitle)
                                    .font(Typography.body(10.5))
                                    .foregroundStyle(palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(UI.s(11))
                        .background(isOn ? palette.accent.opacity(0.12) : palette.rowFill,
                                    in: RoundedRectangle(cornerRadius: UI.s(14), style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: UI.s(14), style: .continuous)
                            .strokeBorder(isOn ? palette.accent.opacity(0.45) : palette.glassEdge.opacity(0.5), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var domainsSummary: String {
        let list = settings.routing.directDomains
        guard !list.isEmpty else { return L.t("не заданы", "not set") }
        if list.count <= 2 { return list.joined(separator: ", ") }
        return list.prefix(2).joined(separator: ", ") + L.t(" и ещё \(list.count - 2)", " and \(list.count - 2) more")
    }

    private var domainsCard: some View {
        Card(title: L.t("Свои домены напрямую", "Own domains direct")) {
            Text(domainsSummary)
                .font(Typography.code(10))
                .foregroundStyle(palette.textPrimary.opacity(0.85))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L.t("Изменить", "Edit")) { isEditingDomains = true }
                .buttonStyle(OutlineButtonStyle())
        }
        .frame(maxHeight: .infinity)
    }

    private var geoCard: some View {
        Card(title: L.t("Базы правил", "Rule databases")) {
            Text(geoError ?? GeoAssets.summary)
                .font(Typography.code(9.5))
                .foregroundStyle(geoError == nil ? palette.textPrimary.opacity(0.85) : palette.bad)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if isUpdatingGeo {
                ProgressView().controlSize(.small)
            } else {
                Button(L.t("Обновить", "Refresh")) { Task { await updateGeo() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func updateGeo() async {
        isUpdatingGeo = true
        geoError = nil
        defer { isUpdatingGeo = false }

        let routing = settings.routing
        do {
            try await GeoAssets.download(
                geositeURL: routing.geositeURL.isEmpty ? GeoAssets.defaultGeositeURL : routing.geositeURL,
                geoipURL: routing.geoipURL.isEmpty ? GeoAssets.defaultGeoipURL : routing.geoipURL)
        } catch {
            geoError = error.localizedDescription
        }
    }
}

// MARK: - Настройки

struct SettingsTab: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var core: CoreStatus
    @EnvironmentObject private var updater: Updater

    var body: some View {
        ScrollView {
            VStack(spacing: UI.s(14)) {
                themeCard
                behaviourCard
                languageCard
                aboutCard
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, UI.s(14))
        }
        .scrollIndicators(.never)
    }

    /// Темы двумя ровными рядами — тёмные и светлые, — каждая мини-превью
    /// окна в своих цветах. Одиннадцать кружков в сетке переносились на
    /// вторую строку, а белые светлые темы резали глаз на тёмном фоне.
    private var themeCard: some View {
        Card(title: L.t("Тема", "Theme")) {
            themeRow(L.t("Тёмные", "Dark"), Palette.all.filter(\.isDark))
            themeRow(L.t("Светлые", "Light"), Palette.all.filter { !$0.isDark })
        }
    }

    private func themeRow(_ title: String, _ options: [Palette]) -> some View {
        VStack(alignment: .leading, spacing: UI.s(7)) {
            Text(title)
                .font(Typography.label(10.5))
                .foregroundStyle(palette.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: UI.s(8)), count: 6),
                      spacing: UI.s(8)) {
                ForEach(options) { option in
                    ThemeTile(option: option, isOn: settings.paletteID == option.id) {
                        withAnimation(.easeOut(duration: 0.25)) { settings.paletteID = option.id }
                    }
                }
            }
        }
    }

    private var languageCard: some View {
        Card(title: L.t("Язык", "Language")) {
            HUDSegmented(selection: Binding(
                get: { settings.language },
                set: { settings.language = $0 }
            ), options: Lang.allCases.map { (value: $0, title: $0.title) })
        }
    }

    private var behaviourCard: some View {
        Card(title: L.t("Поведение", "Behaviour")) {
            Toggle(L.t("Обход локальной сети", "Bypass the local network"), isOn: Binding(
                get: { settings.routing.bypassLAN },
                set: { settings.routing.bypassLAN = $0 }
            ))
            Text(L.t("Принтеры, NAS, роутер и соседние машины остаются доступны, пока VPN включён.",
                     "Printers, NAS, the router and neighbouring machines stay reachable while the VPN is on."))
                .font(Typography.body(10))
                .foregroundStyle(palette.textSecondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L.t("Живой фон", "Animated background"), isOn: $settings.backgroundAnimation)
            Toggle(L.t("Замерять задержку при запуске", "Measure latency at launch"), isOn: $settings.pingOnLaunch)
            Toggle(L.t("Подключаться при запуске", "Connect at launch"), isOn: $settings.autoConnectOnLaunch)
            Spacer(minLength: 0)
        }
        .font(Typography.body(12))
        .foregroundStyle(palette.textPrimary)
        .toggleStyle(HUDToggleStyle())
        .frame(maxHeight: .infinity)
    }

    private var aboutCard: some View {
        Card(title: L.t("О программе", "About")) {
            row(L.t("Версия", "Version"), "Life VPN \(AppVersion.short)")
            row(L.t("Ядро", "Core"), coreVersion)
            Rectangle().fill(palette.glassEdge).frame(height: 1)
            HStack(alignment: .center, spacing: UI.s(10)) {
                VStack(alignment: .leading, spacing: UI.s(2)) {
                    Text(L.t("Обновления", "Updates"))
                        .font(Typography.body(11.5))
                        .foregroundStyle(palette.textSecondary)
                    Text(updateStatus)
                        .font(Typography.body(10.5))
                        .foregroundStyle(updateStatusIsError ? palette.bad : palette.textPrimary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if updater.phase == .checking {
                    ProgressView().controlSize(.small)
                } else if updater.phase == .available {
                    Button(L.t("Обновить", "Update")) { Task { await updater.install() } }
                        .buttonStyle(AccentButtonStyle())
                } else {
                    Button(L.t("Проверить", "Check")) { Task { await updater.check() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// «Xray 26.9.30» — без девиза, хеша сборки и версии Go: в окне это
    /// растягивалось на две строки и ничего не давало пользователю.
    private var coreVersion: String {
        if let full = core.xrayVersion {
            return full.split(separator: " ").prefix(2).joined(separator: " ")
        }
        return core.failure ?? L.t("проверяю…", "checking…")
    }

    private var updateStatus: String {
        switch updater.phase {
        case .idle:              return L.t("проверяются автоматически", "checked automatically")
        case .checking:          return L.t("проверяю…", "checking…")
        case .upToDate:          return L.t("установлена последняя версия", "you have the latest version")
        case .available:         return L.t("доступна версия \(updater.latest?.version ?? "")", "version \(updater.latest?.version ?? "") is out")
        case .downloading(let f): return L.t("загрузка \(Int(f * 100))%", "downloading \(Int(f * 100))%")
        case .installing:        return L.t("устанавливаю…", "installing…")
        case .failed(let m):     return m
        }
    }

    private var updateStatusIsError: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(Typography.body(11.5))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 10)
            Text(value)
                .font(Typography.body(11.5))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Статистика

/// Скорость, трафик и история задержки по каждому узлу.
struct StatsTab: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: ServerStore

    private var totalUsed: Int64 {
        store.subscriptions.compactMap(\.usedBytes).reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.s(14)) {
                HStack(alignment: .top, spacing: UI.s(14)) {
                    SpeedCard()
                        .frame(maxHeight: .infinity)
                    trafficCard
                }
                .fixedSize(horizontal: false, vertical: true)

                if store.servers.isEmpty {
                    Card(title: L.t("Задержка", "Latency")) {
                        Text(L.t("Узлов пока нет — добавьте подписку.", "No nodes yet — add a subscription."))
                            .font(Typography.body(11.5))
                            .foregroundStyle(palette.textSecondary)
                    }
                } else {
                    LatencyCard(servers: store.servers)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, UI.s(14))
        }
        .scrollIndicators(.never)
        .onAppear { store.startAutoPing() }
        .onDisappear { store.stopAutoPing() }
    }

    private var trafficCard: some View {
        Card(title: L.t("Трафик", "Traffic")) {
            BigBytes(bytes: totalUsed, caption: L.t("всего", "total"))
            ForEach(store.subscriptions) { subscription in
                HStack {
                    Text(subscription.displayName)
                        .font(Typography.body(11))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(subscription.trafficSummary ?? "—")
                        .font(Typography.code(10))
                        .foregroundStyle(palette.textPrimary.opacity(0.85))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Мини-превью темы: фон окна с отсветом акцента, акцентная плашка и две
/// строки «текста». Выбранная — рамка цвета текущей темы и галочка.
private struct ThemeTile: View {
    @Environment(\.palette) private var palette
    let option: Palette
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: UI.s(5)) {
                let shape = RoundedRectangle(cornerRadius: UI.s(11), style: .continuous)
                ZStack(alignment: .bottomLeading) {
                    shape.fill(option.background)
                    shape.fill(RadialGradient(colors: [option.accentStart.opacity(option.isDark ? 0.55 : 0.35), .clear],
                                              center: .topTrailing, startRadius: 0, endRadius: UI.s(48)))
                    VStack(alignment: .leading, spacing: UI.s(3.5)) {
                        Capsule().fill(option.accentGradient).frame(width: UI.s(22), height: UI.s(6))
                        Capsule().fill(option.textPrimary.opacity(0.4)).frame(width: UI.s(30), height: UI.s(3.5))
                        Capsule().fill(option.textPrimary.opacity(0.22)).frame(width: UI.s(19), height: UI.s(3.5))
                    }
                    .padding(UI.s(7))
                }
                .frame(height: UI.s(46))
                .overlay(shape.strokeBorder(isOn ? palette.accent : palette.glassEdge.opacity(isHovering ? 2 : 1),
                                            lineWidth: isOn ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: UI.s(7.5), weight: .black))
                            .foregroundStyle(palette.onAccent)
                            .frame(width: UI.s(15), height: UI.s(15))
                            .background(palette.accent, in: Circle())
                            .offset(x: UI.s(4), y: -UI.s(4))
                    }
                }
                .scaleEffect(isHovering && !isOn ? 1.04 : 1)

                Text(option.name)
                    .font(Typography.label(9.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(isOn ? palette.textPrimary : palette.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovering)
        .help(option.name)
    }
}
