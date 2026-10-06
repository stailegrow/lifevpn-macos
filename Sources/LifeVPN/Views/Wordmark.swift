import SwiftUI

/// Фирменный знак: органическая капля с круглым вырезом.
///
/// Один и тот же знак стоит в трёх местах — в иконке приложения, на экране
/// запуска и в шапке, — поэтому и рисуется одной функцией. Вырез настоящий:
/// сквозь него виден фон позади, как и в иконке.
struct AppMark: View {
    var colors: [Color]
    var wobble: CGFloat = 0.8
    var phase: CGFloat = 0.6

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 * 0.92
            var shape = blobPath(center: center, radius: radius, phase: phase, wobble: wobble)

            let holeRadius = radius * 0.16
            let holeDistance = radius * 0.55
            let angle = -55.0 * Double.pi / 180
            shape.addEllipse(in: CGRect(x: center.x + holeDistance * cos(angle) - holeRadius,
                                        y: center.y + holeDistance * sin(angle) - holeRadius,
                                        width: holeRadius * 2, height: holeRadius * 2))

            // Правило чётности: круг внутри капли даёт настоящую дырку,
            // а не второе пятно поверх.
            context.fill(shape,
                         with: .linearGradient(Gradient(colors: colors),
                                               startPoint: CGPoint(x: 0, y: 0),
                                               endPoint: CGPoint(x: size.width, y: size.height)),
                         style: FillStyle(eoFill: true))
        }
    }
}

/// Знак плюс название — то, что стоит в левом верхнем углу окна.
struct Wordmark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: UI.s(9)) {
            AppMark(colors: [palette.accentStart, palette.accentEnd])
                .frame(width: UI.s(21), height: UI.s(21))
            Text("Life VPN")
                .font(Typography.stencil(18))
                .foregroundStyle(palette.textPrimary)
        }
    }
}
