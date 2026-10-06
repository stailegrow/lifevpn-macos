import AppKit
import SwiftUI

/// Плавающая стеклянная панель «Обсидиана».
///
/// Сверху — знак и кнопки «добавить» и «свернуть», под ними карточка
/// текущего узла с кнопкой питания и поиск по узлам (⌘K). Ниже — разделы
/// меню: подсветка активного пункта перетекает между строками, а не
/// перепрыгивает. Добавление подписок и узлов — только через «плюс» в
/// шапке, отдельным разделом оно дублировало бы то же меню. Свёрнутая панель оставляет колонку значков с подсказками.
struct Sidebar: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var updater: Updater

    @Binding var tab: Tab
    @Binding var isCollapsed: Bool
    @Binding var searchText: String
    let isAdding: Bool
    let onAddTapped: () -> Void

    @Namespace private var selection
    @FocusState private var isSearchFocused: Bool

    static let expandedWidth: CGFloat = UI.s(188)
    static let collapsedWidth: CGFloat = UI.s(66)
    static func width(collapsed: Bool) -> CGFloat { collapsed ? collapsedWidth : expandedWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: UI.s(14)) {
            header
            profile
            search

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: UI.s(14)) {
                    section(L.t("Меню", "Menu")) {
                        navRow(.home)
                        navRow(.servers)
                        navRow(.routing)
                        navRow(.stats)
                    }
                    section(L.t("Общее", "General")) {
                        navRow(.settings)
                        actionRow(icon: "rectangle.portrait.and.arrow.right",
                                  title: L.t("Выход", "Quit"),
                                  tint: palette.bad) {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }

            if updater.hasUpdate {
                UpdateCard(isCollapsed: isCollapsed)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: updater.hasUpdate)
        .padding(.top, UI.s(40))
        .padding(.horizontal, UI.s(9))
        .padding(.bottom, UI.s(12))
        .frame(width: Self.width(collapsed: isCollapsed))
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(radius: UI.s(24), elevated: true)
        .background(shortcut)
    }

    // MARK: - Шапка

    private var header: some View {
        // Шапка обязана помещаться в ширину панели: раньше название было
        // зафиксировано по ширине, и в узком окне шапка распирала панель —
        // всё содержимое съезжало влево, а кнопки вылезали за край.
        HStack(spacing: UI.s(6)) {
            if !isCollapsed {
                AppMark(colors: [palette.accentStart, palette.accentEnd])
                    .frame(width: UI.s(20), height: UI.s(20))
                Text("Life VPN")
                    .font(.system(size: UI.t(14), weight: .heavy))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                roundButton(icon: isAdding ? "hourglass" : "plus",
                            help: L.t("Добавить подписку или узлы", "Add a subscription or nodes"),
                            action: onAddTapped)
                    .disabled(isAdding)
            }
            roundButton(icon: "sidebar.left",
                        help: isCollapsed ? L.t("Развернуть панель", "Expand the sidebar")
                                          : L.t("Свернуть панель", "Collapse the sidebar")) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { isCollapsed.toggle() }
            }
        }
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
        .padding(.horizontal, UI.s(2))
    }

    private func roundButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: UI.s(11.5), weight: .semibold))
                .foregroundStyle(palette.textPrimary.opacity(0.85))
                .frame(width: UI.s(25), height: UI.s(25))
                .background(palette.hoverFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }

    // MARK: - Текущий узел

    private var profile: some View {
        let server = store.selected
        return HStack(spacing: UI.s(7)) {
            ZStack(alignment: .bottomTrailing) {
                Text(server.map { ServerRow.countryCode(of: $0.displayName) } ?? "—")
                    .font(.system(size: UI.t(10.5), weight: .heavy))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: UI.s(32), height: UI.s(32))
                    .background(palette.accentGradient, in: Circle())
                Circle()
                    .fill(statusColor)
                    .frame(width: UI.s(10), height: UI.s(10))
                    .overlay(Circle().strokeBorder(palette.card, lineWidth: 2))
                    .offset(x: 1, y: 1)
            }

            if !isCollapsed {
                VStack(alignment: .leading, spacing: UI.s(1)) {
                    Text(server.map { ServerRow.title(of: $0.displayName) } ?? L.t("Нет узла", "No node"))
                        .font(Typography.heading(12))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    statusLine
                }
                Spacer(minLength: 2)
                powerButton(server)
            }
        }
        .padding(UI.s(isCollapsed ? 4 : 6))
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
        .background(palette.rowFill, in: RoundedRectangle(cornerRadius: UI.s(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: UI.s(14), style: .continuous)
            .strokeBorder(palette.glassEdge.opacity(0.7), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { select(.home) }
        .help(isCollapsed ? statusText : "")
    }

    private var statusLine: some View {
        Group {
            if connection.state.isConnected, let since = connection.connectedSince {
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    // Только время: «Подключено · 00:42:21» в узкой панели
                    // обрезалось, а состояние и так видно по зелёной точке.
                    Text(HeroConnectCard.uptime(from: since, to: clock.date))
                        .monospacedDigit()
                }
            } else {
                Text(statusText)
            }
        }
        .font(Typography.body(10.5))
        .foregroundStyle(palette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func powerButton(_ server: ProxyConfig?) -> some View {
        let isOn = connection.state.isConnected
        return Button {
            guard let server else { return }
            Task { await connection.toggle(server) }
        } label: {
            Image(systemName: "power")
                .font(.system(size: UI.s(12), weight: .bold))
                .foregroundStyle(isOn ? palette.onAccent : palette.textPrimary.opacity(0.85))
                .frame(width: UI.s(26), height: UI.s(26))
                .background(isOn ? AnyShapeStyle(palette.accentGradient) : AnyShapeStyle(palette.hoverFill), in: Circle())
                .shadow(color: palette.accent.opacity(isOn ? 0.45 : 0), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(server == nil || connection.state.isBusy)
        .help(isOn ? L.t("Отключить", "Disconnect") : L.t("Подключить", "Connect"))
    }

    private var statusText: String {
        switch connection.state {
        case .connected:    return L.t("Подключено", "Connected")
        case .connecting:   return L.t("Подключение…", "Connecting…")
        case .failed:       return L.t("Ошибка", "Error")
        case .disconnected: return L.t("Не подключено", "Not connected")
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

    // MARK: - Поиск

    @ViewBuilder
    private var search: some View {
        if isCollapsed {
            Button(action: focusSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: UI.s(12), weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: UI.s(34))
                    .background(palette.rowFill, in: RoundedRectangle(cornerRadius: UI.s(12), style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.t("Поиск узла (⌘K)", "Search nodes (⌘K)"))
        } else {
            HStack(spacing: UI.s(8)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: UI.s(11.5), weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                TextField("", text: $searchText,
                          prompt: Text(L.t("Поиск узла", "Search nodes")).foregroundColor(palette.textSecondary))
                    .textFieldStyle(.plain)
                    .font(Typography.body(11.5))
                    .foregroundStyle(palette.textPrimary)
                    .focused($isSearchFocused)
                if searchText.isEmpty {
                    Text("⌘K")
                        .font(Typography.code(9.5))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, UI.s(6))
                        .padding(.vertical, UI.s(2))
                        .background(palette.hoverFill, in: RoundedRectangle(cornerRadius: UI.s(6), style: .continuous))
                } else {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: UI.s(12)))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(L.t("Очистить", "Clear"))
                }
            }
            .padding(.horizontal, UI.s(10))
            .padding(.vertical, UI.s(9))
            .background(palette.rowFill, in: RoundedRectangle(cornerRadius: UI.s(12), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: UI.s(12), style: .continuous)
                .strokeBorder(isSearchFocused ? palette.accent.opacity(0.6) : palette.glassEdge.opacity(0.7), lineWidth: 1))
        }
    }

    /// Невидимая кнопка ради сочетания ⌘K: разворачивает панель, если она
    /// свёрнута, и ставит курсор в поиск.
    private var shortcut: some View {
        Button("", action: focusSearch)
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func focusSearch() {
        if isCollapsed {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { isCollapsed = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { isSearchFocused = true }
        } else {
            isSearchFocused = true
        }
    }

    // MARK: - Разделы

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: UI.s(2)) {
            if isCollapsed {
                Rectangle()
                    .fill(palette.glassEdge)
                    .frame(height: 1)
                    .padding(.horizontal, UI.s(10))
                    .padding(.bottom, UI.s(6))
            } else {
                SectionLabel(text: title)
                    .padding(.horizontal, UI.s(10))
                    .padding(.bottom, UI.s(5))
            }
            content()
        }
    }

    private func navRow(_ item: Tab, badge: Int? = nil) -> some View {
        SidebarRow(icon: item.icon, title: item.sidebarTitle, badge: badge,
                   isActive: tab == item, isCollapsed: isCollapsed, tint: nil,
                   namespace: selection) {
            select(item)
        }
    }

    private func actionRow(icon: String, title: String, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        SidebarRow(icon: icon, title: title, badge: nil,
                   isActive: false, isCollapsed: isCollapsed, tint: tint,
                   namespace: selection, action: action)
    }

    private func select(_ item: Tab) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { tab = item }
    }
}

/// Строка меню. Активную подсвечивает сплошная акцентная плашка; она одна
/// на всю панель и перетекает к новой строке через matchedGeometryEffect.
private struct SidebarRow: View {
    @Environment(\.palette) private var palette
    let icon: String
    let title: String
    let badge: Int?
    let isActive: Bool
    let isCollapsed: Bool
    let tint: Color?
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: UI.s(9)) {
                Image(systemName: icon)
                    .font(.system(size: UI.s(13), weight: .semibold))
                    .frame(width: UI.s(18))
                    .overlay(alignment: .topTrailing) {
                        if isCollapsed, let badge, badge > 0 {
                            Circle()
                                .fill(isActive ? palette.onAccent : palette.accent)
                                .frame(width: UI.s(6), height: UI.s(6))
                                .offset(x: UI.s(5), y: -UI.s(3))
                        }
                    }
                if !isCollapsed {
                    Text(title)
                        .font(.system(size: UI.t(11.5), weight: isActive ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(verbatim: "\(badge)")
                            .font(.system(size: UI.t(10), weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(isActive ? palette.accent : palette.onAccent)
                            .padding(.horizontal, UI.s(7))
                            .padding(.vertical, UI.s(1.5))
                            .background(isActive ? AnyShapeStyle(palette.onAccent) : AnyShapeStyle(palette.accentGradient),
                                        in: Capsule())
                    }
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, UI.s(10))
            .padding(.vertical, UI.s(9))
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: UI.s(12), style: .continuous)
                        .fill(palette.accentGradient)
                        .shadow(color: palette.accent.opacity(0.42), radius: 12, y: 5)
                        .matchedGeometryEffect(id: "active", in: namespace)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: UI.s(12), style: .continuous)
                        .fill(palette.hoverFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help(isCollapsed ? title : "")
    }

    private var foreground: Color {
        if isActive { return palette.onAccent }
        if let tint { return tint.opacity(isHovering ? 1 : 0.85) }
        return isHovering ? palette.textPrimary : palette.textSecondary
    }
}

/// Карточка «Доступна новая версия» внизу панели: кнопка обновления, а во
/// время загрузки — полоска прогресса. В свёрнутой панели остаётся круглая
/// кнопка со стрелкой.
private struct UpdateCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var updater: Updater
    let isCollapsed: Bool

    var body: some View {
        if isCollapsed {
            Button { Task { await updater.install() } } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: UI.s(18), weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: UI.s(36))
                    .background(palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: UI.s(12), style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help(title)
        } else {
            VStack(alignment: .leading, spacing: UI.s(8)) {
                HStack(spacing: UI.s(8)) {
                    Image(systemName: "sparkles")
                        .font(.system(size: UI.s(12), weight: .bold))
                        .foregroundStyle(palette.accent)
                    Text(title)
                        .font(Typography.heading(12))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                }
                switch updater.phase {
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(palette.accent)
                    Text(L.t("Загрузка… \(Int(fraction * 100))%", "Downloading… \(Int(fraction * 100))%"))
                        .font(Typography.body(10.5))
                        .foregroundStyle(palette.textSecondary)
                case .installing:
                    HStack(spacing: UI.s(6)) {
                        ProgressView().controlSize(.mini)
                        Text(L.t("Устанавливаю и перезапускаю…", "Installing and relaunching…"))
                            .font(Typography.body(10.5))
                            .foregroundStyle(palette.textSecondary)
                    }
                case .failed(let message):
                    Text(message)
                        .font(Typography.body(10.5))
                        .foregroundStyle(palette.bad)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    installButton(L.t("Повторить", "Retry"))
                default:
                    Text(L.t("VPN ненадолго отключится, приложение перезапустится само.",
                             "The VPN drops for a moment; the app relaunches by itself."))
                        .font(Typography.body(10.5))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    installButton(L.t("Обновить", "Update"))
                }
            }
            .padding(UI.s(11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: UI.s(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: UI.s(14), style: .continuous)
                .strokeBorder(palette.accent.opacity(0.4), lineWidth: 1))
        }
    }

    private var title: String {
        L.t("Доступна версия \(updater.latest?.version ?? "")", "Version \(updater.latest?.version ?? "") is out")
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private func installButton(_ label: String) -> some View {
        Button(label) { Task { await updater.install() } }
            .buttonStyle(AccentButtonStyle())
    }
}
