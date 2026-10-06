import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case home, servers, routing, stats, settings
    var id: String { rawValue }

    var sidebarTitle: String {
        switch self {
        case .home:     return L.t("Главная", "Home")
        case .servers:  return L.t("Узлы", "Nodes")
        case .routing:  return L.t("Маршрутизация", "Routing")
        case .stats:    return L.t("Статистика", "Statistics")
        case .settings: return L.t("Настройки", "Settings")
        }
    }

    var icon: String {
        switch self {
        case .home:     return "house"
        case .servers:  return "server.rack"
        case .routing:  return "arrow.up.arrow.down"
        case .stats:    return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var core: CoreStatus

    @State private var tab: Tab = .home
    @State private var activeSheet: RootSheet?
    @State private var isAddMenuOpen = false
    @State private var notice: String?
    @State private var noticeIsError = false
    @State private var isAdding = false
    @State private var isLaunching = true
    @State private var searchText = ""
    @AppStorage("sidebarCollapsed") private var isSidebarCollapsed = false

    /// Все модальные окна корня — через одно состояние и один модификатор.
    ///
    /// Два .sheet на одном представлении SwiftUI сводит между собой при
    /// каждом пересчёте тела: обновления ServerStore (авто-пинг раз в пять
    /// секунд) закрывали окно сканера сами собой. Один источник истины
    /// такой сводки не допускает.
    private enum RootSheet: Identifiable {
        case add(AddSheet.Mode)
        case scanner

        var id: String {
            switch self {
            case .add(let mode): return "add-" + mode.id
            case .scanner:       return "scanner"
            }
        }
    }

    /// Вкладкам по-прежнему нужен привычный AddSheet.Mode? — отдаём вид на
    /// общее состояние, а не отдельное хранилище.
    private var addSheet: Binding<AddSheet.Mode?> {
        Binding(
            get: {
                if case .add(let mode) = activeSheet { return mode }
                return nil
            },
            set: { activeSheet = $0.map(RootSheet.add) }
        )
    }

    private var palette: Palette { settings.palette }

    var body: some View {
        ZStack {
            ObsidianBackground(isAnimated: settings.backgroundAnimation)

            HStack(spacing: UI.s(14)) {
                Sidebar(tab: $tab,
                        isCollapsed: $isSidebarCollapsed,
                        searchText: $searchText,
                        isAdding: isAdding,
                        onAddTapped: { isAddMenuOpen.toggle() })

                VStack(spacing: UI.s(12)) {
                    PageHeader(tab: tab, searchText: searchText)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, UI.s(10))

                    Group {
                        switch tab {
                        case .home:     HomeTab(sheet: addSheet, onPaste: paste)
                        case .servers:  ServersTab(query: searchText)
                        case .routing:  RoutingTab()
                        case .stats:    StatsTab()
                        case .settings: SettingsTab()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .id(tab)
                }
                .overlay(alignment: .bottom) {
                    // Уведомление снизу: сверху оно закрывало заголовок раздела.
                    if let notice {
                        NoticeBanner(text: notice, isError: noticeIsError)
                            .frame(maxWidth: UI.s(460))
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.bottom, UI.s(6))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(UI.s(12))
        }
        .onChange(of: searchText) { _, new in
            if !new.isEmpty && tab != .servers {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { tab = .servers }
            }
        }
        .environment(\.palette, palette)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .sheet(item: $activeSheet) { which in
            Group {
                switch which {
                case .add(let mode):
                    AddSheet(mode: mode)
                case .scanner:
                    QRScannerSheet { code in add(code) }
                }
            }
            .environment(\.palette, palette)
        }
        .overlay {
            // Меню рисуем сами внутри окна, а не системным popover: его
            // скруглённая оправа живёт по своим правилам, и подсветка строк
            // лезла за её углы. Своя панель — своя геометрия. Якорь теперь
            // у кнопки «плюс» в сайдбаре (верхний левый угол), а не у
            // прежней шапки сверху-справа.
            if isAddMenuOpen {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { isAddMenuOpen = false }
                    HUDMenuPanel(items: addMenuItems)
                        .environment(\.palette, palette)
                        .padding(.top, UI.s(78))
                        .padding(.leading, UI.s(12) + Sidebar.width(collapsed: isSidebarCollapsed) - UI.s(64))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isAddMenuOpen)
        .animation(.easeOut(duration: 0.2), value: notice)
        .overlay {
            // Заставка живёт поверх всего окна и уходит сама — так первый
            // кадр приложения выглядит собранным, а не полупустым окном,
            // пока подтягиваются узлы и задержка.
            if isLaunching {
                LaunchSplash()
                    .environment(\.palette, palette)
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(LaunchSplash.duration))
            withAnimation(.easeOut(duration: 0.45)) { isLaunching = false }
        }
    }

    /// Всё добавление — одним кликом из меню, без промежуточного окна там,
    /// где оно не нужно: буфер и QR несут готовую ссылку.
    private var addMenuItems: [HUDMenuItem] {
        [
            HUDMenuItem(icon: "doc.on.clipboard",
                        title: L.t("Вставить из буфера", "Paste from clipboard"),
                        subtitle: L.t("добавится сразу", "added right away")) {
                isAddMenuOpen = false
                paste()
            },
            HUDMenuItem(icon: "qrcode.viewfinder",
                        title: L.t("Сканировать QR", "Scan QR"),
                        subtitle: L.t("камерой", "by camera")) {
                isAddMenuOpen = false
                activeSheet = .scanner
            },
            HUDMenuItem(icon: "photo",
                        title: L.t("QR с картинки", "QR from an image"),
                        subtitle: L.t("из файла", "from a file")) {
                isAddMenuOpen = false
                readQRFromFile()
            },
            HUDMenuItem(icon: "link",
                        title: L.t("Ссылка на подписку", "Subscription link"),
                        separatorAbove: true) {
                isAddMenuOpen = false
                activeSheet = .add(.subscription)
            },
            HUDMenuItem(icon: "text.alignleft",
                        title: L.t("Ввести ссылки вручную", "Enter links manually")) {
                isAddMenuOpen = false
                activeSheet = .add(.links)
            }
        ]
    }

    private func paste() {
        guard let clipboard = NSPasteboard.general.string(forType: .string),
              !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // В буфере может лежать картинка со скриншотом кода.
            if let code = QRCode.decodeFromClipboard().first {
                add(code)
            } else {
                show(L.t("В буфере нет ни ссылки, ни картинки с QR-кодом.", "The clipboard holds neither a link nor an image with a QR code."), isError: true)
            }
            return
        }
        add(clipboard)
    }

    private func readQRFromFile() {
        if let code = QRCode.decodeFromChosenFile().first {
            add(code)
        } else {
            show(L.t("В этой картинке QR-код не распознался.", "No QR code was recognised in this image."), isError: true)
        }
    }

    private func add(_ raw: String) {
        isAdding = true
        Task {
            let result = await store.quickAdd(raw)
            isAdding = false
            show(result.message, isError: result.isFailure)
        }
    }

    private func show(_ text: String, isError: Bool) {
        notice = text
        noticeIsError = isError
        Task {
            try? await Task.sleep(for: .seconds(isError ? 7 : 4))
            if notice == text { notice = nil }
        }
    }
}

/// Заголовок раздела над контентом: крупное имя, строка пояснения и плашка
/// состояния справа — как на макете «Обсидиана».
private struct PageHeader: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var settings: AppSettings
    let tab: Tab
    let searchText: String

    var body: some View {
        HStack(alignment: .center, spacing: UI.s(12)) {
            VStack(alignment: .leading, spacing: UI.s(2)) {
                Text(tab.sidebarTitle)
                    .font(.system(size: UI.t(20), weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(palette.textPrimary)
                Text(subtitle)
                    .font(Typography.body(11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            statusChip
        }
    }

    private var subtitle: String {
        switch tab {
        case .home:
            if connection.state.isConnected {
                let preset = settings.routing.preset?.title ?? L.t("свои правила", "custom rules")
                return L.t("Туннель поднят · маршрутизация «\(preset)»", "Tunnel is up · routing “\(preset)”")
            }
            return L.t("Выберите узел и подключитесь", "Pick a node and connect")
        case .servers:
            return searchText.isEmpty ? L.t("Все узлы и задержка до них", "All nodes and their latency")
                                      : L.t("Поиск: «\(searchText)»", "Search: “\(searchText)”")
        case .routing:
            return L.t("Что идёт через туннель, а что — напрямую", "What goes through the tunnel and what goes direct")
        case .stats:
            return L.t("Скорость, трафик и история задержки", "Speed, traffic and latency history")
        case .settings:
            return L.t("Тема, язык и поведение", "Theme, language and behaviour")
        }
    }

    private var statusChip: some View {
        HStack(spacing: UI.s(7)) {
            Circle()
                .fill(statusColor)
                .frame(width: UI.s(8), height: UI.s(8))
                .shadow(color: statusColor.opacity(0.9), radius: 5)
            Text(statusText)
                .font(Typography.heading(11.5))
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.horizontal, UI.s(13))
        .padding(.vertical, UI.s(8))
        .glass(radius: UI.s(20))
        .animation(.easeOut(duration: 0.25), value: connection.state)
    }

    private var statusText: String {
        switch connection.state {
        case .connected:    return L.t("Защищено", "Protected")
        case .connecting:   return L.t("Подключение…", "Connecting…")
        case .failed:       return L.t("Сбой", "Fault")
        case .disconnected: return L.t("Не защищено", "Not protected")
        }
    }

    private var statusColor: Color {
        switch connection.state {
        case .connected:    return palette.good
        case .connecting:   return palette.warn
        case .failed:       return palette.bad
        case .disconnected: return palette.textSecondary
        }
    }
}
