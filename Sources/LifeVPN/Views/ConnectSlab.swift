import SwiftUI

/// Главный переключатель: органическое пятно с мягким ореолом, а под ним —
/// состояние и имя узла. Никакой карточки и обводки вокруг: кнопка сидит
/// прямо на живом фоне.
///
/// Все «часы» анимации считаются от абсолютного времени с постоянным
/// периодом и никогда не перезапускаются от смены состояния — иначе на
/// каждом переключении картинка прыгала бы к началу цикла. От состояния
/// зависит только амплитуда, и она переходит к новому значению плавно, за
/// те же 0,38 секунды, что и в Android-версии.
struct ConnectSlab: View {
    @Environment(\.palette) private var palette

    let state: ConnectionState
    let serverName: String?
    let connectedSince: Date?
    let externalIP: String?
    let isEnabled: Bool
    let action: () -> Void

    @State private var previous: Amplitudes = .disconnected
    @State private var target: Amplitudes = .disconnected
    @State private var changedAt: Date = .distantPast
    @State private var connectedAt: Date?

    private static let transition: Double = 0.38
    private static let sparkleDuration: Double = 0.7

    /// Поле больше самой кнопки: свечение должно успеть сойти на нет
    /// внутри холста. Когда оно упиралось в край, на тёмной теме был
    /// отчётливо виден квадрат — обрезанный краями холста градиент.
    private var size: CGFloat { UI.s(250) }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                Canvas { context, canvasSize in
                    draw(&context, size: canvasSize, now: timeline.date)
                }
                .frame(width: size, height: size)
            }

            Spacer().frame(height: UI.s(14))

            Text(headline)
                .font(Typography.hero(18))
                .foregroundStyle(isFailed ? palette.bad : palette.textPrimary)

            Text(caption)
                .font(Typography.body(12.5))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if state.isConnected, connectedSince != nil || externalIP != nil {
                Spacer().frame(height: UI.s(13))
                HStack(spacing: UI.s(10)) {
                    if let connectedSince {
                        StatPill(label: L.t("время", "time")) {
                            TimelineView(.periodic(from: .now, by: 1)) { clock in
                                Text(Self.uptime(from: connectedSince, to: clock.date))
                                    .font(Typography.code(12.5))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.textPrimary)
                            }
                        }
                    }
                    if let externalIP {
                        StatPill(label: "IP") {
                            Text(externalIP)
                                .font(Typography.code(12.5))
                                .foregroundStyle(palette.textPrimary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UI.s(14))
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.55)
        .onTapGesture { if isEnabled { action() } }
        .onAppear { target = Amplitudes.of(state); previous = target }
        .onChange(of: state) { _, new in
            let now = Date()
            previous = interpolated(at: now)
            target = Amplitudes.of(new)
            changedAt = now
            connectedAt = new.isConnected ? now : nil
        }
    }

    // MARK: - Тексты

    private var isFailed: Bool { if case .failed = state { return true }; return false }
    private var isConnecting: Bool { state == .connecting }

    private var headline: String {
        switch state {
        case .connected:    return L.t("Подключено", "Connected")
        case .connecting:   return L.t("Подключение", "Connecting")
        case .failed:       return L.t("Ошибка", "Error")
        case .disconnected: return L.t("Не подключено", "Not connected")
        }
    }

    private var caption: String {
        switch state {
        case .failed(let message):
            return message
        case .connecting:
            return L.t("устанавливаем защищённый канал", "establishing a secure channel")
        default:
            return serverName ?? L.t("выберите узел", "pick a node")
        }
    }

    private static func uptime(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Амплитуды

    /// Сила эффектов для одного состояния. Сами часы анимации от состояния
    /// не зависят — только это.
    private struct Amplitudes {
        var rotation: Double
        var scale: Double
        var wobble: CGFloat
        var halo: Double

        static let disconnected = Amplitudes(rotation: 4, scale: 0.035, wobble: 0.55, halo: 0.16)
        static let connecting   = Amplitudes(rotation: 8, scale: 0.075, wobble: 1.35, halo: 0.26)
        static let connected    = Amplitudes(rotation: 2, scale: 0.020, wobble: 0.55, halo: 0.13)
        static let failed       = Amplitudes(rotation: 1, scale: 0.015, wobble: 0.30, halo: 0.10)

        static func of(_ state: ConnectionState) -> Amplitudes {
            switch state {
            case .disconnected: return .disconnected
            case .connecting:   return .connecting
            case .connected:    return .connected
            case .failed:       return .failed
            }
        }

        static func lerp(_ a: Amplitudes, _ b: Amplitudes, _ t: Double) -> Amplitudes {
            Amplitudes(rotation: a.rotation + (b.rotation - a.rotation) * t,
                       scale: a.scale + (b.scale - a.scale) * t,
                       wobble: a.wobble + (b.wobble - a.wobble) * CGFloat(t),
                       halo: a.halo + (b.halo - a.halo) * t)
        }
    }

    private func interpolated(at date: Date) -> Amplitudes {
        let elapsed = date.timeIntervalSince(changedAt)
        guard elapsed < Self.transition else { return target }
        let t = max(0, elapsed / Self.transition)
        // Плавный вход-выход, чтобы переход не начинался рывком.
        let eased = t * t * (3 - 2 * t)
        return Amplitudes.lerp(previous, target, eased)
    }

    // MARK: - Отрисовка

    private func draw(_ context: inout GraphicsContext, size canvas: CGSize, now: Date) {
        let time = now.timeIntervalSinceReferenceDate
        let amps = interpolated(at: now)

        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let half = min(canvas.width, canvas.height) / 2

        let breathe = phase(time, period: 3.2)
        let haloPhase = phase(time, period: 3.0)
        let gradientAngle = angle(time, period: 5.2)
        let sheenAngle = angle(time, period: 3.8)
        let orbitAngle = angle(time, period: 0.85)
        let spinnerAngle = angle(time, period: 0.75)

        // Ореол. Радиус вместе с пульсацией обязан оставаться внутри
        // холста: 0.70 + 0.26 в пике даёт 0.96 от половины стороны, то
        // есть прозрачный край свечения не доходит до границы.
        let haloRadius = half * (0.70 + CGFloat(amps.halo * sin(haloPhase)))
        let haloRect = CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                              width: haloRadius * 2, height: haloRadius * 2)
        context.fill(
            Path(ellipseIn: haloRect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: haloColor.opacity(0.85), location: 0),
                    .init(color: haloColor.opacity(0.50), location: 0.55),
                    .init(color: haloColor.opacity(0), location: 1)
                ]),
                center: center, startRadius: 0, endRadius: haloRadius))

        let blobRadius = half * 0.50

        // Тело пятна: дышит и слегка поворачивается вокруг центра.
        var blobContext = context
        blobContext.translateBy(x: center.x, y: center.y)
        blobContext.rotate(by: .degrees(amps.rotation * sin(breathe)))
        let scaleFactor = 1 + amps.scale * sin(breathe)
        blobContext.scaleBy(x: scaleFactor, y: scaleFactor)
        blobContext.translateBy(x: -center.x, y: -center.y)

        let shape = blobPath(center: center, radius: blobRadius,
                             phase: CGFloat(breathe), wobble: amps.wobble)

        let direction = CGPoint(x: cos(gradientAngle), y: sin(gradientAngle))
        let gradientStart = CGPoint(x: center.x - direction.x * blobRadius,
                                    y: center.y - direction.y * blobRadius)
        let gradientEnd = CGPoint(x: center.x + direction.x * blobRadius,
                                  y: center.y + direction.y * blobRadius)
        blobContext.fill(shape, with: .linearGradient(Gradient(colors: fillColors),
                                               startPoint: gradientStart,
                                               endPoint: gradientEnd))

        // Блик внутри пятна: обрезан по его форме, поэтому не вылезает.
        var sheen = blobContext
        sheen.clip(to: shape)
        let sheenCenter = CGPoint(x: center.x + blobRadius * 0.38 * cos(sheenAngle),
                                  y: center.y + blobRadius * 0.38 * sin(sheenAngle))
        let sheenRadius = blobRadius * 0.75
        sheen.fill(
            Path(ellipseIn: CGRect(x: sheenCenter.x - sheenRadius, y: sheenCenter.y - sheenRadius,
                                   width: sheenRadius * 2, height: sheenRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(isAmoledIdle ? 0.16 : 0.22), .white.opacity(0)]),
                center: sheenCenter, startRadius: 0, endRadius: sheenRadius))

        // Символ внутри неподвижен: он отвечает за состояние, и качаться
        // вместе с телом кнопки ему незачем.
        drawGlyph(&context, center: center, radius: blobRadius, spin: spinnerAngle)

        if isConnecting {
            let orbitRadius = blobRadius + UI.s(26)
            let dot = UI.s(4)
            for index in 0..<3 {
                let a = orbitAngle + Double(index) * 2 * .pi / 3
                let point = CGPoint(x: center.x + orbitRadius * cos(a),
                                    y: center.y + orbitRadius * sin(a))
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - dot, y: point.y - dot,
                                           width: dot * 2, height: dot * 2)),
                    with: .color(state.isConnected ? palette.good : palette.accentStart))
            }
        }

        drawSparkles(&context, center: center, radius: blobRadius, now: now)
    }

    /// Разовая вспышка искр в момент успеха — короткий выстрел наружу и
    /// затухание, а не бесконечное мерцание.
    private func drawSparkles(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, now: Date) {
        guard let connectedAt else { return }
        let elapsed = now.timeIntervalSince(connectedAt)
        guard elapsed > 0, elapsed < Self.sparkleDuration else { return }

        let burst = elapsed / Self.sparkleDuration
        let fade = 1 - burst
        let travel = radius + UI.s(30) * CGFloat(burst)
        for degrees in [-70.0, 20.0, 130.0, 205.0] {
            let a = degrees * .pi / 180
            let point = CGPoint(x: center.x + travel * cos(a), y: center.y + travel * sin(a))
            let r = UI.s(2 + 2 * CGFloat(burst))
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(fade * 0.9)))
        }
    }

    /// Классический значок питания: разрыв кольца сверху и риска ровно
    /// через него. Во время подключения та же дуга вращается спиннером.
    private func drawGlyph(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, spin: Double) {
        let r = radius * 0.38
        let width = r * 0.26
        let stroke = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)

        switch state {
        case .connecting:
            var arc = Path()
            arc.addArc(center: center, radius: r,
                       startAngle: .degrees(-90), endAngle: .degrees(170), clockwise: false)
            var spun = context
            spun.translateBy(x: center.x, y: center.y)
            spun.rotate(by: .radians(spin))
            spun.translateBy(x: -center.x, y: -center.y)
            spun.stroke(arc, with: .color(glyphColor), style: stroke)

        case .connected:
            var check = Path()
            check.move(to: CGPoint(x: center.x - r * 0.55, y: center.y + r * 0.05))
            check.addLine(to: CGPoint(x: center.x - r * 0.10, y: center.y + r * 0.50))
            check.addLine(to: CGPoint(x: center.x + r * 0.65, y: center.y - r * 0.45))
            context.stroke(check, with: .color(glyphColor), style: stroke)

        case .failed:
            let a = r * 0.5
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - a, y: center.y - a))
            cross.addLine(to: CGPoint(x: center.x + a, y: center.y + a))
            cross.move(to: CGPoint(x: center.x + a, y: center.y - a))
            cross.addLine(to: CGPoint(x: center.x - a, y: center.y + a))
            context.stroke(cross, with: .color(glyphColor), style: stroke)

        case .disconnected:
            var ring = Path()
            ring.addArc(center: center, radius: r,
                        startAngle: .degrees(-55), endAngle: .degrees(235), clockwise: false)
            context.stroke(ring, with: .color(glyphColor), style: stroke)

            var tick = Path()
            tick.move(to: CGPoint(x: center.x, y: center.y - r * 1.25))
            tick.addLine(to: CGPoint(x: center.x, y: center.y - r * 0.15))
            context.stroke(tick, with: .color(glyphColor), style: stroke)
        }
    }

    // MARK: - Цвета

    /// На AMOLED кнопка в покое обязана быть чёрной — в этом и смысл темы.
    /// Цвет остаётся только там, где он несёт смысл: подключено и ошибка.
    private var isAmoledIdle: Bool {
        palette.id == "amoled" && !state.isConnected && !isFailed
    }

    private var haloColor: Color {
        if isFailed { return palette.bad }
        if isAmoledIdle { return Color(hex: 0x2A2A31) }
        return palette.accentStart
    }

    private var fillColors: [Color] {
        if isFailed { return [palette.bad, palette.bad] }
        if state.isConnected { return [palette.good, palette.accentEnd] }
        if isAmoledIdle { return [Color(hex: 0x0D0D10), Color(hex: 0x000000)] }
        return [palette.accentStart, palette.accentEnd]
    }

    /// Обычно символ рисуется цветом фона — так он читается на заливке
    /// кнопки. На чёрной AMOLED-кнопке фон тоже чёрный, и его не было бы
    /// видно, поэтому там берём светлый цвет текста.
    private var glyphColor: Color {
        isAmoledIdle ? palette.textPrimary : palette.background
    }

    // MARK: - Часы

    /// Зацикленная фаза 0…2π с постоянным периодом.
    private func phase(_ time: TimeInterval, period: Double) -> Double {
        time.truncatingRemainder(dividingBy: period) / period * 2 * .pi
    }

    private func angle(_ time: TimeInterval, period: Double) -> Double {
        phase(time, period: period)
    }
}

/// Мягкая пилюля со значением — тот же язык, что круглые кнопки в шапке:
/// заливка без обводки.
private struct StatPill<Value: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        VStack(spacing: 1) {
            value
            Text(label)
                .font(Typography.label(9))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, UI.s(15))
        .padding(.vertical, UI.s(9))
        .background(palette.hoverFill, in: CutRect(cut: UI.s(16)))
    }
}
