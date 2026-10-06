import SwiftUI

/// Мини-графики задержки по каждому узлу.
///
/// У каждой строки своя шкала. Общая казалась логичнее — по ней видно, какой
/// узел выше, — но она держится ровно до первого далёкого узла: стоит одному
/// отвечать за двести миллисекунд, и все остальные слипаются в прямые у
/// нижнего края. Список узлов у каждого свой, и заранее он неизвестен, так
/// что рассчитывать на близкие величины нельзя.
///
/// Поэтому линия отвечает на вопрос «ровно ли держится этот узел», а на
/// вопрос «который быстрее» отвечает число рядом — оно абсолютное и стоит
/// в той же строке.
struct LatencyCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: ServerStore

    let servers: [ProxyConfig]

    private var series: [(server: ProxyConfig, values: [Int])] {
        servers.map { ($0, store.pingHistory[$0.id] ?? []) }
    }

    private var hasAnyMeasurement: Bool {
        series.contains { !$0.values.isEmpty }
    }

    /// Границы одной строки.
    ///
    /// Шкала не прилегает к данным вплотную. Иначе узел, который держит
    /// ровные 62 мс и дрожит на единицу, нарисуется такой же пилой, как узел,
    /// скачущий от 80 до 300, — а это ровно противоположные вещи. Пока
    /// разброс меньше четверти самой задержки, шкала держится шире данных и
    /// линия остаётся ровной; дальше шкала идёт за данными.
    private func bounds(_ values: [Int]) -> (low: Int, high: Int) {
        guard let low = values.min(), let high = values.max() else { return (0, 1) }

        let middle = (low + high) / 2
        let minimumSpan = max(10, middle / 4)
        let span = max(high - low, minimumSpan)
        let padding = max(1, span / 8)
        let half = span / 2
        return (max(0, middle - half - padding), middle + half + padding)
    }

    var body: some View {
        Card(title: L.t("Задержка", "Latency")) {
            if hasAnyMeasurement {
                HStack {
                    Text(L.t("опрос каждые 10 с · последние \(ServerStore.historyLength)", "polled every 10 s · last \(ServerStore.historyLength)"))
                    Spacer()
                    Text(verbatim: L.t("своя шкала у строки", "own scale per row"))
                }
                .font(Typography.code(8.5))
                .foregroundStyle(palette.textSecondary.opacity(0.8))

                VStack(spacing: UI.s(7)) {
                    ForEach(series, id: \.server.id) { item in
                        row(server: item.server, values: item.values)
                    }
                }
            } else {
                Text(L.t("Замеров ещё не было — нажми «Пинг».", "No measurements yet — press “Ping”."))
                    .font(Typography.body(11))
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private func row(server: ProxyConfig, values: [Int]) -> some View {
        let scale = bounds(values)
        return HStack(spacing: UI.s(9)) {
            Text(ServerRow.title(of: server.displayName))
                .font(Typography.label(10.5))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .frame(width: UI.s(76), alignment: .leading)

            Sparkline(values: values,
                      low: scale.low,
                      high: scale.high,
                      line: palette.accent,
                      endpoint: endpointColor(values.last))
                .frame(height: UI.s(22))

            // Стрелка рядом с числом — чтобы направление читалось не только
            // цветом: цвет говорит «хорошо или плохо», стрелка — «стало
            // лучше или хуже», это разные вещи.
            HStack(spacing: 2) {
                trend(values)
                Text(values.last.map { "\($0)" } ?? "—")
                    .font(Typography.code(10.5))
                    .monospacedDigit()
                    .foregroundStyle(endpointColor(values.last))
            }
            .frame(width: UI.s(42), alignment: .trailing)
        }
    }

    @ViewBuilder
    private func trend(_ values: [Int]) -> some View {
        if values.count >= 2 {
            let delta = values[values.count - 1] - values[values.count - 2]
            // Мелкие колебания — шум сети, стрелку они не заслуживают.
            if abs(delta) >= 5 {
                Image(systemName: delta < 0 ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                    .font(.system(size: UI.s(6)))
                    .foregroundStyle(delta < 0 ? palette.good : palette.warn)
            }
        }
    }

    private func endpointColor(_ value: Int?) -> Color {
        guard let value else { return palette.textSecondary }
        switch PingQuality(ms: value) {
        case .good: return palette.good
        case .fair: return palette.warn
        case .poor: return palette.bad
        }
    }
}

/// Линия без осей: сама по себе она не о величинах, а о поведении —
/// ровно ли держится задержка. Величину называет число рядом.
struct Sparkline: View {
    let values: [Int]
    let low: Int
    let high: Int
    let line: Color
    let endpoint: Color

    var body: some View {
        Canvas { context, size in
            drawBaseline(&context, size: size)

            guard values.count >= 2, high > low else {
                if let single = values.last {
                    dot(&context, at: CGPoint(x: size.width - 3, y: position(single, in: size)))
                }
                return
            }

            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * size.width / CGFloat(values.count - 1),
                        y: position(value, in: size))
            }

            // Заливка под линией: она не несёт своих данных, но задаёт объём —
            // по ней видно, держится задержка у нижней границы или у верхней.
            var area = Path()
            area.move(to: CGPoint(x: points[0].x, y: size.height))
            for point in points { area.addLine(to: point) }
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [line.opacity(0.26), line.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))

            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(line.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            // Последний замер выделен: именно он отвечает на вопрос «как сейчас».
            if let last = points.last {
                dot(&context, at: last)
            }
        }
        .animation(.easeOut(duration: 0.35), value: values)
    }

    private func drawBaseline(_ context: inout GraphicsContext, size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(baseline, with: .color(line.opacity(0.14)), lineWidth: 1)
    }

    /// Кольцо вокруг точки отделяет её от линии и заливки под ней.
    private func dot(_ context: inout GraphicsContext, at point: CGPoint) {
        var halo = Path()
        halo.addEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        context.fill(halo, with: .color(.black.opacity(0.75)))

        var mark = Path()
        mark.addEllipse(in: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
        context.fill(mark, with: .color(endpoint))
    }

    /// Меньше задержка — выше точка.
    private func position(_ value: Int, in size: CGSize) -> CGFloat {
        let span = CGFloat(max(1, high - low))
        let fraction = CGFloat(value - low) / span
        let inset: CGFloat = 4
        return inset + (size.height - inset * 2) * fraction
    }
}
