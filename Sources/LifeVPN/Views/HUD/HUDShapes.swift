import SwiftUI

/// Прямоугольник со скруглёнными углами — базовая форма всего интерфейса.
///
/// Имя `CutRect` осталось от первой версии, где углы были срезаны по
/// диагонали. Переименовывать его значило бы тронуть полсотни мест ради
/// одного слова; форма же сменилась целиком — интерфейс Life VPN мягкий,
/// без единого острого угла.
struct CutRect: InsettableShape {
    enum Corner: CaseIterable { case topLeading, topTrailing, bottomTrailing, bottomLeading }

    var cut: CGFloat = 12
    var corners: Set<Corner> = Set(Corner.allCases)
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> CutRect {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in outer: CGRect) -> Path {
        let rect = outer.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let r = min(cut, min(rect.width, rect.height) / 2)

        let tl = corners.contains(.topLeading) ? r : 0
        let tr = corners.contains(.topTrailing) ? r : 0
        let br = corners.contains(.bottomTrailing) ? r : 0
        let bl = corners.contains(.bottomLeading) ? r : 0

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                        startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                        startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                        startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()
        return path
    }
}

/// Органическое пятно — форма кнопки подключения и фирменного знака.
///
/// Радиус гуляет по двум гармоникам, точки соединяются квадратичными
/// кривыми через середины отрезков: так контур получается гладким, без
/// единого угла, в отличие от ломаной по точкам.
///
/// Множитель у `phase` обязан быть целым. `phase` — зацикленные часы с
/// периодом ровно 2π, и при целом множителе форма на стыке цикла совпадает
/// сама с собой; при дробном — не совпадает, и пятно дёргается раз за цикл.
func blobPath(center: CGPoint, radius: CGFloat, phase: CGFloat, wobble: CGFloat) -> Path {
    let points = 20
    var pts: [CGPoint] = []
    pts.reserveCapacity(points)

    for i in 0..<points {
        let theta = CGFloat(i) / CGFloat(points) * 2 * .pi
        let r = radius * (1
                          + wobble * 0.11 * sin(3 * theta + phase)
                          + wobble * 0.06 * sin(5 * theta - phase * 2))
        pts.append(CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta)))
    }

    var path = Path()
    let first = pts[0]
    let last = pts[points - 1]
    path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
    for i in 0..<points {
        let cur = pts[i]
        let next = pts[(i + 1) % points]
        path.addQuadCurve(to: CGPoint(x: (cur.x + next.x) / 2, y: (cur.y + next.y) / 2),
                          control: cur)
    }
    path.closeSubpath()
    return path
}

/// Полоска-индикатор из отдельных сегментов.
struct SegmentBar: View {
    var fraction: Double
    var segments: Int = 24
    var filled: LinearGradient
    var empty: Color

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let unit = (geometry.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let active = Int((Double(segments) * max(0, min(1, fraction))).rounded())

            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { index in
                    Rectangle()
                        .fill(index < active ? AnyShapeStyle(filled) : AnyShapeStyle(empty))
                        .frame(width: unit)
                }
            }
        }
        .frame(height: 6)
    }
}
