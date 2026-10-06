import SwiftUI

/// Экран запуска: живой фон на всё окно и фирменный знак поверх него.
///
/// Показывается один раз при старте и уходит сам. Живой фон здесь не
/// зависит от тумблера в настройках — это разовая заставка, а не рабочий
/// экран, и выключать ей анимацию нечего.
struct LaunchSplash: View {
    @Environment(\.palette) private var palette

    /// Сколько знак растёт и проявляется, прежде чем заставка уедет.
    static let duration: Double = 1.7

    @State private var appeared = false

    var body: some View {
        ZStack {
            ObsidianBackground(isAnimated: true)

            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let breathe = time.truncatingRemainder(dividingBy: 3.2) / 3.2 * 2 * .pi

                VStack(spacing: UI.s(18)) {
                    ZStack {
                        // Ореол позади знака — тот же приём, что у кнопки
                        // подключения: мягкое свечение, а не плоский круг.
                        Circle()
                            .fill(RadialGradient(
                                colors: [palette.accentStart.opacity(0.55),
                                         palette.accentStart.opacity(0)],
                                center: .center, startRadius: 0, endRadius: UI.s(110)))
                            .frame(width: UI.s(220), height: UI.s(220))
                            .scaleEffect(1 + 0.06 * CGFloat(sin(breathe)))

                        AppMark(colors: [palette.accentStart, palette.accentEnd],
                                wobble: 0.9,
                                phase: CGFloat(breathe))
                            .frame(width: UI.s(132), height: UI.s(132))
                            .rotationEffect(.degrees(3 * sin(breathe)))
                    }

                    Text("Life VPN")
                        .font(Typography.stencil(22))
                        .foregroundStyle(palette.textPrimary)
                        .opacity(appeared ? 1 : 0)
                }
                .scaleEffect(appeared ? 1 : 0.82)
                .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.68)) {
                appeared = true
            }
        }
    }
}
