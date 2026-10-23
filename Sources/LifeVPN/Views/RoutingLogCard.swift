import SwiftUI

/// Окно журнала маршрутизации на экране «Статистика»: видно, какой адрес
/// ушёл в туннель, какой — напрямую, а какой отсечён. Кнопка «Выгрузить»
/// сохраняет журнал всей сессии в .txt.
struct RoutingLogCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var connection: ConnectionManager
    @ObservedObject private var log = RoutingLog.shared

    @State private var filter: RoutingLog.Route?

    private var shown: [RoutingLog.Entry] {
        guard let filter else { return log.entries }
        return log.entries.filter { $0.route == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UI.s(10)) {
            HStack(spacing: UI.s(8)) {
                SectionLabel(text: L.t("Журнал маршрутизации", "Routing log"))
                Spacer(minLength: UI.s(6))
                Button(action: { log.export() }) {
                    Label(L.t("Выгрузить", "Export"), systemImage: "square.and.arrow.up")
                        .font(.system(size: UI.t(10.5), weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, UI.s(11))
                        .padding(.vertical, UI.s(6))
                        .background(palette.hoverFill, in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.glassEdge, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(log.entries.isEmpty)
                .opacity(log.entries.isEmpty ? 0.45 : 1)
                .help(L.t("Сохранить журнал сессии в текстовый файл", "Save the session log as a text file"))
            }

            HStack(spacing: UI.s(6)) {
                chip(nil, title: L.t("Все", "All"), count: log.counts.values.reduce(0, +))
                ForEach([RoutingLog.Route.proxy, .direct, .block], id: \.self) { route in
                    chip(route, title: route.title, count: log.counts[route] ?? 0)
                }
                Spacer(minLength: 0)
            }

            if shown.isEmpty {
                Text(emptyText)
                    .font(Typography.body(11))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: UI.s(2)) {
                        ForEach(shown) { entry in
                            row(entry)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(UI.s(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass()
    }

    private var emptyText: String {
        if !connection.state.isConnected {
            return L.t("Подключитесь — здесь появится, куда идёт каждое соединение",
                       "Connect to see where each connection goes")
        }
        return filter == nil
            ? L.t("Соединений пока нет", "No connections yet")
            : L.t("В этой группе пока пусто", "Nothing here yet")
    }

    private func color(_ route: RoutingLog.Route) -> Color {
        switch route {
        case .proxy:  return palette.accent
        case .direct: return palette.good
        case .block:  return palette.bad
        case .other:  return palette.textSecondary
        }
    }

    private func chip(_ route: RoutingLog.Route?, title: String, count: Int) -> some View {
        let isOn = filter == route
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { filter = route }
        } label: {
            HStack(spacing: UI.s(5)) {
                if let route {
                    Circle().fill(color(route)).frame(width: UI.s(6), height: UI.s(6))
                }
                Text(title)
                Text(verbatim: "\(count)")
                    .foregroundStyle(isOn ? palette.textPrimary : palette.textSecondary.opacity(0.8))
                    .monospacedDigit()
            }
            .font(.system(size: UI.t(10), weight: .semibold))
            .foregroundStyle(isOn ? palette.textPrimary : palette.textSecondary)
            .padding(.horizontal, UI.s(9))
            .padding(.vertical, UI.s(5))
            .background(isOn ? palette.hoverFill.opacity(1.8) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? palette.glassEdge : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func row(_ entry: RoutingLog.Entry) -> some View {
        HStack(spacing: UI.s(9)) {
            Text(entry.time)
                .font(Typography.code(9.5))
                .foregroundStyle(palette.textSecondary.opacity(0.8))
                .monospacedDigit()

            Text(entry.route.title)
                .font(.system(size: UI.t(9), weight: .bold))
                .foregroundStyle(color(entry.route))
                .frame(width: UI.s(64))
                .padding(.vertical, UI.s(2.5))
                .background(color(entry.route).opacity(0.14), in: Capsule())

            (Text(entry.host).foregroundStyle(palette.textPrimary)
             + Text(verbatim: ":\(entry.port)").foregroundStyle(palette.textSecondary.opacity(0.7)))
                .font(Typography.code(10.5))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if entry.network == "UDP" {
                Text("UDP")
                    .font(Typography.code(9))
                    .foregroundStyle(palette.textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, UI.s(8))
        .padding(.vertical, UI.s(4))
        .background(palette.rowFill, in: RoundedRectangle(cornerRadius: UI.s(8), style: .continuous))
        .help(entry.byDefault
              ? L.t("Ни одно правило не совпало — маршрут по умолчанию", "No rule matched — default route")
              : L.t("Сработало правило маршрутизации", "Matched a routing rule"))
    }
}
