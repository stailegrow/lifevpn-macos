import SwiftUI

struct HomeTab: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var settings: AppSettings

    @Binding var sheet: AddSheet.Mode?
    let onPaste: () -> Void

    private var isEmpty: Bool { store.subscriptions.isEmpty && store.servers.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.s(12)) {
                notes

                HeroConnectCard()

                // Подписка и скорость живут в «Статистике», а действия с
                // подпиской — в «Узлах»: на главной — только подключение и узлы.
                if isEmpty {
                    emptyState
                }

                if !isEmpty {
                    serverGrid
                }

                if case .failed(let message) = connection.state {
                    failureCard(message)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, UI.s(14))
        }
        .scrollIndicators(.never)
    }

    // MARK: - Заметки

    @ViewBuilder
    private var notes: some View {
        if connection.isPreparingRules {
            inlineNote(icon: "arrow.down.circle", tint: palette.warn,
                       text: L.t("Загружаю базы правил маршрутизации…", "Loading the routing databases…"))
        }
        if let notice = connection.routingNotice {
            inlineNote(icon: "exclamationmark.circle", tint: palette.warn, text: notice)
        }
        if connection.recoveredFromCrash {
            inlineNote(icon: "arrow.uturn.backward.circle", tint: palette.warn,
                       text: L.t("Прошлый запуск завершился некорректно — системный прокси снят.", "The previous run ended abnormally — the system proxy has been cleared."))
        }
    }

    private func inlineNote(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: UI.s(8)) {
            Image(systemName: icon)
                .font(.system(size: UI.s(11), weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(Typography.body(11))
                .foregroundStyle(palette.textPrimary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UI.s(12))
        .padding(.vertical, UI.s(9))
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: UI.s(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: UI.s(14), style: .continuous)
            .strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Подписка и узлы

    private var currentSubscription: Subscription? {
        if let selected = store.selected, let found = store.subscription(for: selected) { return found }
        return store.subscriptions.first
    }

    private var visibleServers: [ProxyConfig] {
        let list = store.servers(in: currentSubscription)
        return list.isEmpty ? store.servers : list
    }

    private var serverGrid: some View {
        VStack(alignment: .leading, spacing: UI.s(10)) {
            HStack {
                SectionLabel(text: L.t("Узлы · \(visibleServers.count) доступно", "Nodes · \(visibleServers.count) available"))
                Spacer()
                if store.isPinging {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await store.pingAll() }
                    } label: {
                        Label(L.t("Замерить", "Measure"), systemImage: "speedometer")
                            .font(Typography.label(10.5))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(L.t("Замерить задержку", "Measure latency"))
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: UI.s(8)),
                                GridItem(.flexible(), spacing: UI.s(8))],
                      spacing: UI.s(8)) {
                ForEach(Array(visibleServers.enumerated()), id: \.element.id) { index, server in
                    ServerRow(server: server,
                              index: index,
                              latency: store.pings[server.id],
                              isActive: connection.activeServer?.id == server.id && connection.state.isConnected,
                              isSelected: store.selectedID == server.id)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { store.selectedID = server.id }
                        }
                }
            }
        }
        .padding(UI.s(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }

    private var emptyState: some View {
        Card(title: L.t("Начало", "Getting started")) {
            Text(L.t("Здесь пока пусто", "Nothing here yet"))
                .font(.system(size: UI.t(17), weight: .heavy))
                .foregroundStyle(palette.textPrimary)
            Text(L.t("Добавьте подписку — узлы подтянутся сами и будут обновляться, когда вы меняете их на панели.",
                     "Add a subscription — the nodes come in by themselves and keep updating as you change them on the panel."))
                .font(Typography.body(11.5))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: UI.s(8)) {
                Button(L.t("Добавить подписку", "Add subscription")) { sheet = .subscription }
                    .buttonStyle(AccentButtonStyle())
                Button(L.t("Из буфера", "From clipboard")) { onPaste() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Лог ядра бывает на десятки строк — прячем его в свою прокрутку.
    private func failureCard(_ message: String) -> some View {
        Card(title: L.t("Ошибка", "Error")) {
            Label(L.t("Соединение не поднялось", "The connection did not come up"), systemImage: "exclamationmark.triangle.fill")
                .font(Typography.heading(12))
                .foregroundStyle(palette.bad)

            ScrollView {
                Text(message)
                    .font(Typography.code(9))
                    .foregroundStyle(palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
    }
}
