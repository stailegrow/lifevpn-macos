import SwiftUI

// MARK: - Панель

/// Стеклянная карточка с необязательной подписью раздела сверху.
struct Card<Content: View>: View {
    @Environment(\.palette) private var palette
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: UI.s(10)) {
            if let title {
                SectionLabel(text: title)
            }
            content
        }
        .padding(UI.s(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass()
    }
}

// MARK: - Круглая кнопка

struct CircleIconButton: View {
    @Environment(\.palette) private var palette
    let systemImage: String
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: UI.s(11.5), weight: .semibold))
                .foregroundStyle(isHovering ? palette.textPrimary : palette.textSecondary)
                .frame(width: UI.s(28), height: UI.s(28))
                .background(isHovering ? palette.hoverFill.opacity(1.6) : palette.hoverFill, in: Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(help)
    }
}

// MARK: - Переключатель

/// Свой переключатель вместо системного: системный на macOS заметно крупнее
/// всего остального в этом интерфейсе и перетягивает внимание на себя.
struct HUDToggleStyle: ToggleStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 10) {
            configuration.label
            Spacer(minLength: 8)
            track(isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { configuration.isOn.toggle() }
        }
    }

    private func track(isOn: Bool) -> some View {
        let width = UI.s(34.0)
        let height = UI.s(19.0)
        let knob = height - UI.s(5)

        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(palette.accentGradient) : AnyShapeStyle(palette.hoverFill.opacity(1.8)))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .frame(width: knob, height: knob)
                .padding(.horizontal, UI.s(2.5))
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Пинг

/// Задержка — моноширинным числом цвета качества. Без полосок: цифра и
/// цвет читаются быстрее.
struct PingBadge: View {
    @Environment(\.palette) private var palette
    /// Внешний optional — замера не было; внутренний — сервер не ответил.
    let latency: Int??

    var body: some View {
        switch latency {
        case .none:
            EmptyView()
        case .some(.none):
            Text(L.t("Н/Д", "N/A"))
                .font(Typography.code(10.5))
                .foregroundStyle(palette.bad)
        case .some(.some(let ms)):
            Text(verbatim: "\(ms) " + L.t("мс", "ms"))
                .font(Typography.code(10.5))
                .foregroundStyle(PingBadge.color(for: ms, palette: palette))
        }
    }

    static func color(for ms: Int, palette: Palette) -> Color {
        switch PingQuality(ms: ms) {
        case .good: return palette.good
        case .fair: return palette.warn
        case .poor: return palette.bad
        }
    }
}

// MARK: - Строка сервера

struct ServerRow: View {
    @Environment(\.palette) private var palette
    let server: ProxyConfig
    let index: Int
    let latency: Int??
    let isActive: Bool
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: UI.s(8)) {
            CodeBadge(name: server.displayName, isHighlighted: isSelected || isActive)

            VStack(alignment: .leading, spacing: UI.s(2)) {
                Text(ServerRow.title(of: server.displayName))
                    .font(Typography.heading(12))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(ServerRow.transportLine(of: server))
                    .font(Typography.code(8))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 2)

            VStack(alignment: .trailing, spacing: UI.s(2)) {
                PingBadge(latency: latency)
                    .fixedSize()
                if isActive {
                    Text(L.t("активен", "active"))
                        .font(Typography.label(9))
                        .foregroundStyle(palette.accent)
                }
            }
        }
        .padding(.horizontal, UI.s(9))
        .padding(.vertical, UI.s(9))
        .background(RoundedRectangle(cornerRadius: UI.s(14), style: .continuous).fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: UI.s(14), style: .continuous)
                .strokeBorder(isSelected ? palette.accent.opacity(0.5) : palette.glassEdge.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var background: Color {
        if isSelected { return palette.accent.opacity(0.14) }
        if isHovering { return palette.hoverFill }
        return palette.rowFill
    }

    /// «TCP · REALITY», «XHTTP · REALITY» — транспорт и защита. Протокол
    /// пишется, только если это не VLESS: у почти всех узлов он одинаковый,
    /// а в узком окне длинная строка обрезалась.
    static func transportLine(of server: ProxyConfig) -> String {
        var parts: [String] = []
        if server.kind != .vless { parts.append(server.kind.rawValue.uppercased()) }
        parts.append(server.transport.rawValue.uppercased())
        if server.security != .none { parts.append(server.security.rawValue.uppercased()) }
        return parts.joined(separator: " · ")
    }

    /// Флаг из имени уезжает в отдельный значок — в заголовке он лишний.
    ///
    /// Определяем его не по свойствам эмодзи: флаг составлен из региональных
    /// индикаторов, и проверка isEmojiPresentation на них не срабатывает.
    /// Надёжнее считать флагом всё нечитаемое, что стоит перед первой буквой.
    static func title(of name: String) -> String {
        let rest = name.drop { !$0.isLetter && !$0.isNumber }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    static func flag(of name: String) -> String? {
        var flag = ""
        for character in name {
            if character.isLetter || character.isNumber { break }
            if character.isWhitespace {
                if flag.isEmpty { continue }
                break
            }
            flag.append(character)
        }
        return flag.isEmpty ? nil : flag
    }

    /// Двухбуквенный код страны: из флага (региональные индикаторы — это
    /// буквы A–Z, сдвинутые в отдельный блок Юникода), а без флага — первые
    /// буквы названия.
    static func countryCode(of name: String) -> String {
        if let flag = flag(of: name) {
            let letters = flag.unicodeScalars.compactMap { scalar -> Character? in
                guard (0x1F1E6...0x1F1FF).contains(scalar.value),
                      let ascii = Unicode.Scalar(scalar.value - 0x1F1E6 + 65) else { return nil }
                return Character(ascii)
            }
            if letters.count == 2 { return String(letters) }
        }
        let title = title(of: name).filter { $0.isLetter }
        return String(title.prefix(2)).uppercased()
    }
}

/// Квадратик с кодом страны вместо флага: эмодзи-флаги на тёмном стекле
/// выглядят пёстро, буквы — спокойно и одинаково на любой системе.
struct CodeBadge: View {
    @Environment(\.palette) private var palette
    let name: String
    let isHighlighted: Bool
    var size: CGFloat = UI.s(25)

    var body: some View {
        Text(ServerRow.countryCode(of: name))
            .font(.system(size: size * 0.37, weight: .heavy))
            .foregroundStyle(palette.textPrimary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.33, style: .continuous)
                    .fill(isHighlighted ? palette.accent.opacity(0.28) : palette.hoverFill)
            )
    }
}

// MARK: - Строка технических данных

/// Моноширинная строка мелким кеглем.
struct TelemetryLine: View {
    @Environment(\.palette) private var palette
    let items: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·").foregroundStyle(palette.textSecondary.opacity(0.4))
                }
                Text(item)
            }
        }
        .font(Typography.code(8.5))
        .tracking(0.3)
        .foregroundStyle(palette.textSecondary.opacity(0.75))
        .lineLimit(1)
    }
}

// MARK: - Трафик подписки

/// Индикатор трафика.
///
/// Когда лимита нет, шкале нечего показывать: залитая на всю ширину полоса
/// выглядит как исчерпанный лимит, хотя означает ровно обратное. Поэтому
/// при безлимите полосы нет вовсе.
struct TrafficMeter: View {
    @Environment(\.palette) private var palette
    let used: Int64?
    let total: Int64?

    private var fraction: Double? {
        guard let used, let total, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    var body: some View {
        if let fraction {
            VStack(alignment: .leading, spacing: UI.s(5)) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.hoverFill)
                        Capsule()
                            .fill(palette.accentGradient)
                            .frame(width: max(4, geometry.size.width * fraction))
                    }
                }
                .frame(height: UI.s(6))
                HStack {
                    Text(L.t("из \(Subscription.formatBytes(total ?? 0))", "of \(Subscription.formatBytes(total ?? 0))"))
                    Spacer()
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                        .foregroundStyle(fraction > 0.9 ? palette.bad : palette.textSecondary)
                }
                .font(Typography.code(9))
                .foregroundStyle(palette.textSecondary)
            }
        }
    }
}

/// Объём крупно: число отдельно, единица мельче — «153.07 ГБ».
struct BigBytes: View {
    @Environment(\.palette) private var palette
    let bytes: Int64
    var caption: String? = nil
    var size: CGFloat = 20

    var body: some View {
        let parts = Self.split(Subscription.formatBytes(bytes))
        HStack(alignment: .firstTextBaseline, spacing: UI.s(6)) {
            Text(parts.number)
                .font(.system(size: UI.t(size), weight: .heavy))
                .tracking(-0.8)
                .foregroundStyle(palette.textPrimary)
            Text(parts.unit + (caption.map { " " + $0 } ?? ""))
                .font(Typography.heading(11))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
        }
    }

    static func split(_ text: String) -> (number: String, unit: String) {
        guard let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

// MARK: - Скорость

struct SpeedCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var connection: ConnectionManager

    var body: some View {
        VStack(alignment: .leading, spacing: UI.s(8)) {
            SectionLabel(text: L.t("Скорость", "Speed"))
            HStack(alignment: .center, spacing: UI.s(8)) {
                // Число никогда не переносится: «141.8» в две строки читалось
                // как два разных значения.
                HStack(alignment: .firstTextBaseline, spacing: UI.s(4)) {
                    Text(connection.speed?.display ?? "—")
                        .font(.system(size: UI.t(20), weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(connection.speed == nil ? palette.textSecondary : palette.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    Text(L.t("Мбит/с", "Mbit/s"))
                        .font(Typography.heading(11))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                if connection.isMeasuringSpeed {
                    ProgressView().controlSize(.small)
                } else {
                    CircleIconButton(systemImage: "speedometer",
                                     help: L.t("Проверить скорость", "Test the speed")) {
                        Task { await connection.measureSpeed() }
                    }
                }
            }
            Spacer(minLength: 0)
            Text(detail)
                .font(Typography.body(10.5))
                .foregroundStyle(connection.speedError == nil ? palette.textSecondary : palette.bad)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UI.s(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glass()
    }

    private var detail: String {
        if let error = connection.speedError { return error }
        guard let speed = connection.speed else {
            return connection.state.isConnected ? L.t("замер пойдёт через туннель", "the test runs through the tunnel")
                                                : L.t("замер пойдёт напрямую, мимо VPN", "the test runs directly, around the VPN")
        }
        let volume = Subscription.formatBytes(Int64(speed.bytes))
        let seconds = String(format: "%.1f", speed.seconds)
        let route = speed.throughProxy ? L.t("через туннель", "through the tunnel") : L.t("напрямую, мимо VPN", "directly, around the VPN")
        return L.t("\(route) · \(speed.source) · \(volume) за \(seconds) с", "\(route) · \(speed.source) · \(volume) in \(seconds) s")
    }
}

// MARK: - Всплывающее уведомление

struct NoticeBanner: View {
    @Environment(\.palette) private var palette
    let text: String
    let isError: Bool

    private var tint: Color { isError ? palette.bad : palette.good }

    var body: some View {
        HStack(alignment: .top, spacing: UI.s(8)) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: UI.s(12), weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(Typography.body(11.5))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UI.s(13))
        .padding(.vertical, UI.s(11))
        .glass(radius: UI.s(16), elevated: true)
    }
}

// MARK: - Кнопки

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.heading(12))
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, UI.s(16))
            .padding(.vertical, UI.s(9))
            .background(palette.accentGradient,
                        in: RoundedRectangle(cornerRadius: UI.s(12), style: .continuous))
            .shadow(color: palette.accent.opacity(0.35), radius: 10, y: 4)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.heading(12))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, UI.s(15))
            .padding(.vertical, UI.s(9))
            .background(palette.hoverFill, in: RoundedRectangle(cornerRadius: UI.s(12), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: UI.s(12), style: .continuous)
                .strokeBorder(palette.glassEdge.opacity(1.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
