import AppKit
import SwiftUI

// MARK: - Стекло

/// Стеклянная поверхность «Обсидиана»: размытие того, что под ней,
/// полупрозрачная подложка темы и тонкая светлая кромка.
///
/// Вся форма интерфейса держится на ней — боковая панель, карточки,
/// плашки, — поэтому стиль задан в одном месте.
struct GlassSurface: ViewModifier {
    @Environment(\.palette) private var palette
    let radius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(palette.glass)
                }
                .shadow(color: .black.opacity(elevated ? (palette.isDark ? 0.45 : 0.14) : 0),
                        radius: elevated ? 24 : 0,
                        y: elevated ? 12 : 0)
            }
            .overlay {
                shape.strokeBorder(palette.glassEdge, lineWidth: 1)
            }
    }
}

extension View {
    func glass(radius: CGFloat = UI.s(22), elevated: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, elevated: elevated))
    }
}

/// Мелкая подпись раздела капсом с разрядкой — «МЕНЮ», «ПОДПИСКА».
struct SectionLabel: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: UI.t(9.5), weight: .bold))
            .tracking(1.2)
            .foregroundStyle(palette.textSecondary.opacity(0.75))
            .lineLimit(1)
    }
}

// MARK: - Фон

/// Живой фон: «северное сияние» — несколько вытянутых мягких световых лент,
/// которые медленно плывут, поворачиваются и дышат поверх тёмного поля. На
/// тёмных темах ленты складываются светом (там, где пересекаются, ярче),
/// сверху — едва заметное зерно, чтобы градиенты не шли полосами.
///
/// Раскладка задана в долях окна. Рисуется одним Canvas на 30 кадрах;
/// анимацию можно выключить в настройках — тогда ленты стоят на местах.
struct ObsidianBackground: View {
    @Environment(\.palette) private var palette
    let isAnimated: Bool

    private struct Ribbon {
        let x: CGFloat, y: CGFloat          // центр, доли окна
        let driftX: CGFloat, driftY: CGFloat
        let length: CGFloat                 // доля ширины
        let thickness: CGFloat              // доля высоты
        let angle: Double, sway: Double     // наклон и размах поворота, радианы
        let period: Double, phase: Double
        let tone: Int
        let alpha: Double
    }

    private static let ribbons: [Ribbon] = [
        Ribbon(x: 0.80, y: 0.16, driftX: 0.10, driftY: 0.06, length: 1.05, thickness: 0.36,
               angle: -0.45, sway: 0.25, period: 23, phase: 0.0, tone: 0, alpha: 0.55),
        Ribbon(x: 0.32, y: 0.88, driftX: 0.12, driftY: 0.05, length: 1.10, thickness: 0.32,
               angle: 0.30, sway: 0.20, period: 29, phase: 1.7, tone: 1, alpha: 0.50),
        Ribbon(x: 0.64, y: 0.62, driftX: 0.14, driftY: 0.08, length: 0.80, thickness: 0.22,
               angle: -0.15, sway: 0.35, period: 19, phase: 3.1, tone: 2, alpha: 0.32),
        Ribbon(x: 0.14, y: 0.22, driftX: 0.08, driftY: 0.08, length: 0.70, thickness: 0.22,
               angle: 0.80, sway: 0.30, period: 25, phase: 4.4, tone: 0, alpha: 0.22),
        Ribbon(x: 0.96, y: 0.78, driftX: 0.06, driftY: 0.10, length: 0.70, thickness: 0.26,
               angle: 1.15, sway: 0.22, period: 31, phase: 2.5, tone: 1, alpha: 0.34)
    ]

    var body: some View {
        ZStack {
            palette.background

            Group {
                if isAnimated {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                        Canvas { context, size in
                            draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                } else {
                    Canvas { context, size in
                        draw(&context, size: size, time: 0)
                    }
                }
            }
            .drawingGroup()

            Image(nsImage: Grain.image)
                .resizable(resizingMode: .tile)
                .opacity(palette.isDark ? 0.05 : 0.06)
                .blendMode(.overlay)

            // Края притушены, середина остаётся спокойной под карточками.
            RadialGradient(colors: [palette.background.opacity(0),
                                    palette.background.opacity(palette.isDark ? 0.42 : 0.3)],
                           center: UnitPoint(x: 0.6, y: 0.45),
                           startRadius: 180,
                           endRadius: 700)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let tones = palette.orbColors
        context.blendMode = palette.isDark ? .plusLighter : .normal

        for ribbon in Self.ribbons {
            let t = (time / ribbon.period + ribbon.phase) * 2 * .pi
            let center = CGPoint(x: (ribbon.x + ribbon.driftX * CGFloat(sin(t))) * size.width,
                                 y: (ribbon.y + ribbon.driftY * CGFloat(sin(t * 0.7 + 1.1))) * size.height)
            let angle = ribbon.angle + ribbon.sway * sin(t * 0.5)
            let breathe = 1 + 0.12 * CGFloat(sin(t * 1.3))

            let color: Color
            switch ribbon.tone {
            case 1:  color = tones.second
            case 2:  color = tones.third
            default: color = tones.main
            }
            let alpha = palette.isDark ? min(1, ribbon.alpha * 1.45) : ribbon.alpha * 0.7

            // Единичный круг, растянутый в эллипс: радиальный градиент
            // растягивается вместе с ним и даёт мягкую ленту без размытия.
            var ribbonContext = context
            ribbonContext.translateBy(x: center.x, y: center.y)
            ribbonContext.rotate(by: .radians(angle))
            ribbonContext.scaleBy(x: ribbon.length * size.width / 2 * breathe,
                                  y: ribbon.thickness * size.height / 2)
            ribbonContext.fill(
                Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                with: .radialGradient(
                    Gradient(stops: [.init(color: color.opacity(alpha), location: 0),
                                     .init(color: color.opacity(alpha * 0.45), location: 0.45),
                                     .init(color: color.opacity(0), location: 1)]),
                    center: .zero, startRadius: 0, endRadius: 1))
        }
    }
}

/// Плитка шума для зерна поверх фона. Генерируется один раз при первом
/// обращении, детерминированно — без картинок в ресурсах.
private enum Grain {
    @MainActor static let image: NSImage = {
        let side = 160
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<(side * side) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = UInt8(truncatingIfNeeded: seed >> 56)
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: side, height: side,
                                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }()
}
