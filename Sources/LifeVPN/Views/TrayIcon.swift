import AppKit

/// Значок в строке меню — тот же фирменный знак, что в иконке приложения и
/// на экране запуска: капля с круглым вырезом.
///
/// Рисуем сами, а не берём символ из системного набора: тамошние картинки
/// приходят со своими полями и в строке меню обрезаются. Свой рисунок
/// помещается в положенные 18 точек целиком.
///
/// Отключённое состояние отдаём шаблоном — тогда macOS сама красит значок
/// под строку меню, светлую или тёмную. Подключённое рисуем зелёным и
/// признак шаблона снимаем, иначе цвет до экрана не доживёт.
enum TrayIcon {

    private static let side: CGFloat = 18

    static func image(connected: Bool) -> NSImage {
        let color: NSColor = connected ? .systemGreen : .labelColor
        let size = NSSize(width: side, height: side)

        let image = NSImage(size: size)
        if let rep = draw(color: color, size: size) {
            image.addRepresentation(rep)
        }
        image.isTemplate = !connected
        return image
    }

    /// Рисуем в двойном разрешении: на Retina без этого края будут мыльными.
    private static func draw(color: NSColor, size: NSSize) -> NSBitmapImageRep? {
        let scale = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 * 0.86

        let path = blob(center: center, radius: radius)

        // Вырез пробивается насквозь правилом чётности: круг внутри капли
        // даёт дырку, а не второе пятно поверх.
        let holeRadius = radius * 0.16
        let holeDistance = radius * 0.55
        let angle = -55.0 * Double.pi / 180
        let hole = NSRect(x: center.x + holeDistance * CGFloat(cos(angle)) - holeRadius,
                          y: center.y - holeDistance * CGFloat(sin(angle)) - holeRadius,
                          width: holeRadius * 2, height: holeRadius * 2)
        path.appendOval(in: hole)
        path.windingRule = .evenOdd

        color.setFill()
        path.fill()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Тот же контур, что у кнопки подключения: две гармоники и гладкие
    /// кривые через середины отрезков.
    private static func blob(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        let points = 20
        let wobble: CGFloat = 0.8
        let phase: CGFloat = 0.6

        var pts: [NSPoint] = []
        pts.reserveCapacity(points)
        for i in 0..<points {
            let theta = CGFloat(i) / CGFloat(points) * 2 * .pi
            let r = radius * (1
                              + wobble * 0.11 * sin(3 * theta + phase)
                              + wobble * 0.06 * sin(5 * theta - phase * 2))
            pts.append(NSPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta)))
        }

        let path = NSBezierPath()
        let first = pts[0]
        let last = pts[points - 1]
        path.move(to: NSPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for i in 0..<points {
            let cur = pts[i]
            let next = pts[(i + 1) % points]
            path.curve(to: NSPoint(x: (cur.x + next.x) / 2, y: (cur.y + next.y) / 2),
                       controlPoint1: cur,
                       controlPoint2: cur)
        }
        path.close()
        return path
    }
}
