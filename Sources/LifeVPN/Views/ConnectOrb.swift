import SwiftUI

/// Кнопка подключения «неоновый знак»: кнопкой служит сам значок питания.
///
/// Выключено — тонкий бледный контур, при наведении чуть ярче. Во время
/// подключения кольцо знака прорисовывается по кругу, как индикатор. Когда
/// туннель поднят, знак становится толстой неоновой линией в цветах темы
/// с мягко пульсирующим свечением. Ошибка — тот же знак красным.
struct ConnectOrb: View {
    @Environment(\.palette) private var palette
    let state: ConnectionState
    let isEnabled: Bool
    var diameter: CGFloat = UI.s(178)
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    private var size: CGFloat { diameter }
    private var glyphSize: CGFloat { size * 0.74 }
    private var unit: CGFloat { glyphSize / 24 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let ring = ringProgress(time)
            ZStack {
                // Свечение — размытая копия знака под ним.
                symbol(width: lineWidth * 1.5, style: AnyShapeStyle(glowColor), ringTo: ring)
                    .blur(radius: size * 0.055)
                    .opacity(glowOpacity(time))
                symbol(width: lineWidth, style: strokeStyle, ringTo: ring)
            }
            .frame(width: glyphSize, height: glyphSize)
        }
        .frame(width: size, height: size)
        .scaleEffect(isPressed ? 0.94 : (isHovering && isEnabled ? 1.03 : 1))
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovering)
        .animation(.easeInOut(duration: 0.4), value: state)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled && !isPressed { isPressed = true } }
                .onEnded { value in
                    isPressed = false
                    // Нажатие засчитывается, только если отпустили на кнопке.
                    let distance = hypot(value.location.x - size / 2, value.location.y - size / 2)
                    if isEnabled && distance < size / 2 { action() }
                }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(state.isConnected ? L.t("Отключить VPN", "Disconnect VPN") : L.t("Подключить VPN", "Connect VPN"))
    }

    private func symbol(width: CGFloat, style: AnyShapeStyle, ringTo: CGFloat) -> some View {
        let stroke = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        return ZStack {
            PowerGlyph(part: .ring)
                .trim(from: 0, to: ringTo)
                .stroke(style, style: stroke)
            PowerGlyph(part: .stem)
                .stroke(style, style: stroke)
        }
    }

    // MARK: - Состояния

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    private var lineWidth: CGFloat {
        switch state {
        case .connected:    return unit * 1.9
        case .connecting:   return unit * 1.5
        case .failed:       return unit * 1.6
        case .disconnected: return unit * (isHovering ? 1.3 : 1.1)
        }
    }

    private var strokeStyle: AnyShapeStyle {
        switch state {
        case .connected:
            return AnyShapeStyle(LinearGradient(colors: [.white, palette.accentStart, palette.accentEnd],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .connecting:
            return AnyShapeStyle(palette.accentGradient)
        case .failed:
            return AnyShapeStyle(palette.bad)
        case .disconnected:
            return AnyShapeStyle(palette.textPrimary.opacity(isHovering ? 0.4 : 0.22))
        }
    }

    private var glowColor: Color { isFailed ? palette.bad : palette.accentStart }

    private func glowOpacity(_ time: Double) -> Double {
        switch state {
        case .connected:
            return 0.55 + 0.45 * (0.5 + 0.5 * sin(time * 2 * .pi / 3.2))
        case .connecting:
            return 0.35 + 0.35 * (0.5 + 0.5 * sin(time * 2 * .pi / 0.9))
        case .failed:
            return 0.5
        case .disconnected:
            return isHovering ? 0.25 : 0
        }
    }

    /// Насколько прорисовано кольцо: целиком всегда, кроме подключения —
    /// тогда оно раз за разом рисуется по кругу.
    private func ringProgress(_ time: Double) -> CGFloat {
        guard state.isBusy else { return 1 }
        let cycle = time.truncatingRemainder(dividingBy: 1.4) / 1.4
        return CGFloat(0.06 + 0.94 * cycle)
    }
}

/// Значок питания в сетке 24×24: кольцо с разрывом сверху и черта через
/// разрыв. Кольцо собрано из коротких отрезков, а не дугой — так его
/// направление однозначно (по часовой от правого края разрыва), и
/// анимация прорисовки идёт куда задумано.
private struct PowerGlyph: Shape {
    enum Part { case ring, stem }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(x) * unit, y: origin.y + CGFloat(y) * unit)
        }

        var path = Path()
        switch part {
        case .stem:
            path.move(to: point(12, 2.6))
            path.addLine(to: point(12, 11.2))
        case .ring:
            let centerX = 12.0, centerY = 12.56, radius = 8.6
            let start = -45.8, end = 225.8
            let steps = 96
            for step in 0...steps {
                let angle = (start + (end - start) * Double(step) / Double(steps)) * .pi / 180
                let p = point(centerX + radius * cos(angle), centerY + radius * sin(angle))
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        return path
    }
}

/// Главная карточка: кнопка, состояние, узел и две плашки — время и пинг.
struct HeroConnectCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var store: ServerStore

    var body: some View {
        HStack(spacing: UI.s(18)) {
            ConnectOrb(state: connection.state,
                       isEnabled: store.selected != nil && !connection.state.isBusy,
                       diameter: UI.s(128)) {
                guard let server = store.selected else { return }
                Task { await connection.toggle(server) }
            }

            VStack(alignment: .leading, spacing: UI.s(12)) {
                VStack(alignment: .leading, spacing: UI.s(3)) {
                    Text(headline)
                        .font(.system(size: UI.t(15), weight: .bold))
                        .foregroundStyle(isFailed ? palette.bad : palette.textPrimary)
                    Text(caption)
                        .font(Typography.body(11))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: UI.s(8)) {
                    StatTile(label: L.t("время", "time")) {
                        if let since = connection.connectedSince, connection.state.isConnected {
                            TimelineView(.periodic(from: .now, by: 1)) { clock in
                                Text(Self.uptime(from: since, to: clock.date))
                                    .monospacedDigit()
                            }
                        } else {
                            Text("—")
                        }
                    }
                    StatTile(label: L.t("пинг", "ping")) {
                        pingText
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, UI.s(14))
        .padding(.vertical, UI.s(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }

    private var isFailed: Bool { if case .failed = connection.state { return true }; return false }

    private var headline: String {
        switch connection.state {
        case .connected:    return L.t("Подключено", "Connected")
        case .connecting:   return L.t("Подключение…", "Connecting…")
        case .failed:       return L.t("Ошибка", "Error")
        case .disconnected: return L.t("Не подключено", "Not connected")
        }
    }

    private var caption: String {
        if connection.state.isBusy { return L.t("устанавливаем защищённый канал", "establishing a secure channel") }
        guard let server = store.selected else { return L.t("выберите узел", "pick a node") }
        var parts = [ServerRow.title(of: server.displayName), server.kind.rawValue.uppercased()]
        if server.security != .none { parts.append(server.security.rawValue.capitalized) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var pingText: some View {
        if let server = store.selected, case .some(.some(let ms)) = store.pings[server.id] {
            Text(verbatim: "\(ms) " + L.t("мс", "ms"))
                .foregroundStyle(PingBadge.color(for: ms, palette: palette))
        } else {
            Text("—")
        }
    }

    static func uptime(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

private struct StatTile<Value: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        VStack(spacing: UI.s(1)) {
            value
                .font(Typography.code(11.5))
                .foregroundStyle(palette.textPrimary)
            Text(label)
                .font(Typography.label(9.5))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(minWidth: UI.s(64))
        .padding(.horizontal, UI.s(10))
        .padding(.vertical, UI.s(7))
        .background(palette.hoverFill, in: RoundedRectangle(cornerRadius: UI.s(12), style: .continuous))
    }
}
