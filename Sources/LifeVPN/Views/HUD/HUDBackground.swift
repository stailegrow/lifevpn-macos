import AppKit
import SwiftUI

/// Живой фон: четыре мягких пятна, которые дрейфуют, дышат и переливаются
/// цветами темы.
///
/// Амплитуда считается от размера окна, а не в фиксированных точках:
/// иначе на большом окне движение становится незаметным и фон выглядит
/// картинкой. На тёмных темах собственные оттенки пятен почти сливаются с
/// фоном, поэтому к ним подмешивается акцентный цвет — переливание должно
/// читаться и на чёрном.
///
/// Рисуется одним Canvas на 30 кадрах в секунду. Это VPN-клиент, который
/// висит открытым часами, поэтому анимация намеренно дешёвая и её можно
/// выключить в настройках.
struct HUDBackground: View {
    @Environment(\.palette) private var palette
    let isAnimated: Bool

    /// Точка покоя в долях окна — раскладка одинакова на любом размере.
    private struct Blob {
        let restX: CGFloat
        let restY: CGFloat
        let radius: CGFloat
        let drift: CGFloat
        let period: Double
        let phase: Double
        let colorPeriod: Double
        let colorPhase: Double
    }

    private static let blobs: [Blob] = [
        Blob(restX: 0.16, restY: 0.14, radius: 0.60, drift: 0.16, period: 11, phase: 0,   colorPeriod: 14, colorPhase: 0),
        Blob(restX: 0.88, restY: 0.28, radius: 0.50, drift: 0.14, period: 13, phase: 2.1, colorPeriod: 17, colorPhase: 3.5),
        Blob(restX: 0.24, restY: 0.80, radius: 0.66, drift: 0.15, period: 15, phase: 4.2, colorPeriod: 20, colorPhase: 1.7),
        Blob(restX: 0.82, restY: 0.86, radius: 0.44, drift: 0.13, period: 9,  phase: 5.6, colorPeriod: 12, colorPhase: 5.0)
    ]

    var body: some View {
        ZStack {
            palette.background

            if isAnimated {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        draw(&context, size: size,
                             time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                Canvas { context, size in
                    draw(&context, size: size, time: 0, still: true)
                }
            }

            // Виньетка притушивает края, чтобы карточки в центре читались
            // даже когда пятно проходит прямо под ними.
            RadialGradient(colors: [.clear, .clear, palette.background.opacity(0.55)],
                           center: .center,
                           startRadius: 90,
                           endRadius: 560)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Отрисовка

    private func draw(_ context: inout GraphicsContext,
                      size: CGSize,
                      time: TimeInterval,
                      still: Bool = false) {

        let cycle = cycleColors
        let alpha = palette.isDark ? 0.5 : 0.68
        let minDim = min(size.width, size.height)

        for blob in Self.blobs {
            let t = still ? 0 : (time / blob.period + blob.phase) * 2 * .pi
            let driftPx = blob.drift * minDim
            let center = CGPoint(x: blob.restX * size.width + CGFloat(sin(t)) * driftPx,
                                 y: blob.restY * size.height + CGFloat(sin(t * 0.8 + 1.3)) * driftPx)

            // Дыхание радиуса: пятно не только ездит, но и меняет размер.
            let pulse = still ? 0 : sin(t * 1.3)
            let radius = blob.radius * minDim * (1 + CGFloat(pulse) * 0.08)

            let color = still
                ? cycle[0]
                : blended(cycle, at: (time / blob.colorPeriod + blob.colorPhase)
                          .truncatingRemainder(dividingBy: 1))

            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(alpha), location: 0),
                        .init(color: color.opacity(alpha * 0.5), location: 0.7),
                        .init(color: color.opacity(0), location: 1)
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius)
            )
        }
    }

    /// Круг оттенков, по которому переливается каждое пятно.
    private var cycleColors: [Color] {
        let base = [palette.blob1, palette.blob2, palette.blob3]
        if palette.isDark {
            return base.map { mix($0, palette.accentStart, 0.55) } + [mix(palette.blob1, palette.accentEnd, 0.55)]
        }
        return base + [mix(palette.blob2, palette.accentStart, 0.35)]
    }

    /// Положение на круге оттенков: 0 — первый цвет, 1 — снова он же.
    private func blended(_ colors: [Color], at position: Double) -> Color {
        guard !colors.isEmpty else { return .clear }
        let segment = position * Double(colors.count)
        let index = min(max(Int(segment), 0), colors.count - 1)
        let next = (index + 1) % colors.count
        return mix(colors[index], colors[next], segment - Double(index))
    }

    private func mix(_ a: Color, _ b: Color, _ amount: Double) -> Color {
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? .clear
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? .clear
        let k = max(0, min(1, amount))
        return Color(.sRGB,
                     red: Double(ca.redComponent) * (1 - k) + Double(cb.redComponent) * k,
                     green: Double(ca.greenComponent) * (1 - k) + Double(cb.greenComponent) * k,
                     blue: Double(ca.blueComponent) * (1 - k) + Double(cb.blueComponent) * k,
                     opacity: Double(ca.alphaComponent) * (1 - k) + Double(cb.alphaComponent) * k)
    }
}
