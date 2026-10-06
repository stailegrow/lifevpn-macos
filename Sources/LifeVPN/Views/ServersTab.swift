import AppKit
import SwiftUI

struct ServersTab: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var store: ServerStore

    /// Строка поиска из боковой панели: фильтрует узлы по названию.
    var query: String = ""

    @State private var renaming: Subscription?

    private func filtered(_ list: [ProxyConfig]) -> [ProxyConfig] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.s(14)) {
                ForEach(store.subscriptions) { subscription in
                    let members = filtered(store.servers(in: subscription))

                    group(title: subscription.displayName,
                          subtitle: subscriptionSubtitle(subscription),
                          servers: members) {
                        Menu {
                            Button(L.t("Переименовать…", "Rename…")) { renaming = subscription }
                            Button(L.t("Обновить", "Refresh")) { Task { await store.refresh(subscription) } }
                            Button(L.t("Скопировать ссылку", "Copy link")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(subscription.url, forType: .string)
                            }
                            Divider()
                            Button(L.t("Удалить подписку", "Delete subscription"), role: .destructive) {
                                store.removeSubscription(subscription.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(Typography.heading(12))
                                .foregroundStyle(palette.textSecondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22)
                    }

                    if !members.isEmpty {
                        LatencyCard(servers: members)
                    }
                }

                if !store.manualServers.isEmpty {
                    group(title: L.t("Добавлены вручную", "Added manually"),
                          subtitle: nil,
                          servers: filtered(store.manualServers)) { EmptyView() }
                }

                if store.servers.isEmpty && store.subscriptions.isEmpty {
                    Card(title: L.t("Пусто", "Empty")) {
                        Text(L.t("Список пуст", "The list is empty"))
                            .font(Typography.heading(13))
                            .foregroundStyle(palette.textPrimary)
                        Text(L.t("Добавь подписку или вставь vless:// ссылки.", "Add a subscription or paste vless:// links."))
                            .font(Typography.body(12))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, UI.s(14))
        }
        .scrollIndicators(.never)
        .onAppear { store.startAutoPing() }
        .onDisappear { store.stopAutoPing() }
        .sheet(item: $renaming) { subscription in
            RenameSubscriptionSheet(subscription: subscription)
                .environment(\.palette, palette)
        }
    }

    private func subscriptionSubtitle(_ subscription: Subscription) -> String? {
        if let error = subscription.lastError { return error }
        var parts: [String] = []
        if let traffic = subscription.trafficSummary { parts.append(traffic) }
        parts.append(L.t("обновлена \(Subscription.formatUpdated(subscription.lastUpdated))", "updated \(Subscription.formatUpdated(subscription.lastUpdated))"))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func group<Trailing: View>(title: String,
                                       subtitle: String?,
                                       servers: [ProxyConfig],
                                       @ViewBuilder trailing: () -> Trailing) -> some View {
        Card {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: UI.t(15), weight: .heavy))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.body(10))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                trailing()
            }

            if servers.isEmpty {
                Text(query.isEmpty ? L.t("Серверов нет", "No servers") : L.t("Ничего не найдено", "Nothing found"))
                    .font(Typography.body(11))
                    .foregroundStyle(palette.textSecondary)
            } else {
                VStack(spacing: Metrics.rowGap) {
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                        ServerRow(server: server,
                                  index: index,
                                  latency: store.pings[server.id],
                                  isActive: connection.activeServer?.id == server.id && connection.state.isConnected,
                                  isSelected: store.selectedID == server.id)
                            .onTapGesture { store.selectedID = server.id }
                            .contextMenu {
                                Button(L.t("Подключиться", "Connect")) {
                                    Task { await connection.connect(to: server) }
                                }
                                Button(L.t("Замерить задержку", "Measure latency")) {
                                    Task { await store.ping(server) }
                                }
                                if let link = server.sourceLink {
                                    Button(L.t("Скопировать ссылку", "Copy link")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(link, forType: .string)
                                    }
                                }
                                if server.subscriptionID == nil {
                                    Divider()
                                    Button(L.t("Удалить", "Delete"), role: .destructive) {
                                        store.remove([server.id])
                                    }
                                }
                            }
                    }
                }
            }
        }
    }
}
