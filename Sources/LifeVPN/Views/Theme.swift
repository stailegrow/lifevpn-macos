import AppKit
import SwiftUI

/// Палитра приложения. Экраны не знают конкретных цветов — только роли,
/// поэтому смена темы не требует правок в разметке.
///
/// Life VPN: цвета приглушённые, пастельные — пять светлых тем, мягкая
/// тёмная и настоящий чёрный AMOLED. Помимо ролей интерфейса палитра несёт
/// три цвета пятен живого фона: фон переливается оттенками своей темы, и
/// задавать их отдельно от палитры значило бы рассинхронизировать их при
/// добавлении новой темы.
struct Palette: Identifiable, Hashable, Sendable {
    let id: String
    let nameRU: String
    let nameEN: String

    let background: Color
    let card: Color
    let cardBorder: Color

    let accentStart: Color
    let accentEnd: Color
    let idleRing: Color

    let textPrimary: Color
    let textSecondary: Color

    let good: Color
    let warn: Color
    let bad: Color

    let blob1: Color
    let blob2: Color
    let blob3: Color

    /// Тёмные темы просят другую системную схему (курсор, скроллбары,
    /// стандартные контролы) — светлые элементы системы на чёрном фоне
    /// выглядят инородно.
    let isDark: Bool

    var accentGradient: LinearGradient {
        LinearGradient(colors: [accentStart, accentEnd],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    var ringGradient: AngularGradient {
        AngularGradient(colors: [accentStart, accentEnd, accentStart], center: .center)
    }

    var accent: Color { accentStart }

    /// Цвет текста и значков поверх акцентной заливки. Пастельным акцентам
    /// нужен тёмный текст, насыщенным (как у «Рубина») — белый: считаем по
    /// яркости, чтобы новой теме не приходилось об этом помнить.
    var onAccent: Color {
        let c = NSColor(accentStart).usingColorSpace(.sRGB) ?? .white
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.55 ? Color.black.opacity(0.85) : .white
    }

    /// Подложка стеклянных панелей: полупрозрачная, чтобы живой фон
    /// просвечивал сквозь размытие.
    var glass: Color { isDark ? card.opacity(0.55) : Color.white.opacity(0.45) }

    /// Тонкая светлая кромка стекла.
    var glassEdge: Color { isDark ? Color.white.opacity(0.09) : Color.white.opacity(0.75) }

    /// Три сферы живого фона: главная — акцентом, две другие — контрастными
    /// соседями, чтобы объём читался и на почти чёрном.
    var orbColors: (main: Color, second: Color, third: Color) {
        switch id {
        case "ruby", "lagoon":
            return (accentStart, Color(hex: 0x5B47D6), Color(hex: 0x3BB8E6))
        case "amethyst", "amber":
            return (accentStart, Color(hex: 0xE5383B), Color(hex: 0x3BB8E6))
        default:
            return (accentStart, accentEnd, isDark ? Color(hex: 0x3BB8E6) : blob3)
        }
    }

    /// Едва заметная заливка строк и полей на стекле.
    var hoverFill: Color { textPrimary.opacity(isDark ? 0.07 : 0.06) }
    var rowFill: Color { textPrimary.opacity(isDark ? 0.035 : 0.035) }

    // Палитры — константы, они создаются раньше, чем известен язык.
    var name: String { L.t(nameRU, nameEN) }
}

extension Palette {
    /// По умолчанию — нейтральная светлая тема: не «для мальчиков» и не
    /// «для девочек».
    static let sky = Palette(
        id: "sky", nameRU: "Небо", nameEN: "Sky",
        background: Color(hex: 0xF2F7FD), card: Color(hex: 0xFFFFFF, alpha: 0.70), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.50),
        accentStart: Color(hex: 0x9AC7EC), accentEnd: Color(hex: 0xB7CBF2), idleRing: Color(hex: 0x414352, alpha: 0.20),
        textPrimary: Color(hex: 0x43485A), textSecondary: Color(hex: 0x8F93A6),
        good: Color(hex: 0x8FD9BE), warn: Color(hex: 0xF3C696), bad: Color(hex: 0xF3A3AE),
        blob1: Color(hex: 0xD7E8FA), blob2: Color(hex: 0xDEE3FB), blob3: Color(hex: 0xDBF3E6),
        isDark: false)

    static let mint = Palette(
        id: "mint", nameRU: "Мята", nameEN: "Mint",
        background: Color(hex: 0xEFFAF4), card: Color(hex: 0xFFFFFF, alpha: 0.70), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.50),
        accentStart: Color(hex: 0x8FD8BE), accentEnd: Color(hex: 0xAEE7CE), idleRing: Color(hex: 0x2F4740, alpha: 0.20),
        textPrimary: Color(hex: 0x3A4A44), textSecondary: Color(hex: 0x8B9C94),
        good: Color(hex: 0x8FD9BE), warn: Color(hex: 0xF3C696), bad: Color(hex: 0xF3A3AE),
        blob1: Color(hex: 0xD6F1E2), blob2: Color(hex: 0xCFEBE0), blob3: Color(hex: 0xD9EEF8),
        isDark: false)

    static let lavender = Palette(
        id: "lavender", nameRU: "Лаванда", nameEN: "Lavender",
        background: Color(hex: 0xF5F1FC), card: Color(hex: 0xFFFFFF, alpha: 0.70), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.50),
        accentStart: Color(hex: 0xBFA8EE), accentEnd: Color(hex: 0xD1C2F3), idleRing: Color(hex: 0x413C52, alpha: 0.20),
        textPrimary: Color(hex: 0x48435A), textSecondary: Color(hex: 0x938EA6),
        good: Color(hex: 0x8FD9BE), warn: Color(hex: 0xF3C696), bad: Color(hex: 0xF3A3AE),
        blob1: Color(hex: 0xE6DEFB), blob2: Color(hex: 0xEEE1FA), blob3: Color(hex: 0xDDE7FB),
        isDark: false)

    static let peach = Palette(
        id: "peach", nameRU: "Персик", nameEN: "Peach",
        background: Color(hex: 0xFDF5EC), card: Color(hex: 0xFFFFFF, alpha: 0.70), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.50),
        accentStart: Color(hex: 0xF0B583), accentEnd: Color(hex: 0xF6CDA3), idleRing: Color(hex: 0x52453C, alpha: 0.20),
        textPrimary: Color(hex: 0x564A3E), textSecondary: Color(hex: 0xA69A8C),
        good: Color(hex: 0x8FD9BE), warn: Color(hex: 0xF3C696), bad: Color(hex: 0xF3A3AE),
        blob1: Color(hex: 0xFAE2C8), blob2: Color(hex: 0xF8D9D2), blob3: Color(hex: 0xF7EEC4),
        isDark: false)

    static let rose = Palette(
        id: "rose", nameRU: "Роза", nameEN: "Rose",
        background: Color(hex: 0xFDF0F5), card: Color(hex: 0xFFFFFF, alpha: 0.70), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.50),
        accentStart: Color(hex: 0xEEA6C1), accentEnd: Color(hex: 0xF3BFD4), idleRing: Color(hex: 0x52414A, alpha: 0.20),
        textPrimary: Color(hex: 0x564650), textSecondary: Color(hex: 0xA6919C),
        good: Color(hex: 0x8FD9BE), warn: Color(hex: 0xF3C696), bad: Color(hex: 0xF3A3AE),
        blob1: Color(hex: 0xF9DCE9), blob2: Color(hex: 0xF6D9DE), blob3: Color(hex: 0xF7E9C4),
        isDark: false)

    /// Мягкая тёмная тема — не чернота, а тёплый приглушённый тёмно-синий
    /// с теми же пастельными акцентами, чуть ярче для контраста.
    static let night = Palette(
        id: "night", nameRU: "Ночь", nameEN: "Night",
        background: Color(hex: 0x1B2030), card: Color(hex: 0x262C40), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.20),
        accentStart: Color(hex: 0x8FB6EE), accentEnd: Color(hex: 0xB7A6EE), idleRing: Color(hex: 0xFFFFFF, alpha: 0.20),
        textPrimary: Color(hex: 0xEDEFF6), textSecondary: Color(hex: 0x9BA1B8),
        good: Color(hex: 0x7FD9B8), warn: Color(hex: 0xF0C283), bad: Color(hex: 0xF08FA0),
        blob1: Color(hex: 0x2E3A57), blob2: Color(hex: 0x362F57), blob3: Color(hex: 0x20404A),
        isDark: true)

    /// Настоящий чёрный фон — под экраны, которым это экономит подсветку.
    static let amoled = Palette(
        id: "amoled", nameRU: "AMOLED", nameEN: "AMOLED",
        background: Color(hex: 0x000000), card: Color(hex: 0x121214), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.15),
        accentStart: Color(hex: 0x9AC2F2), accentEnd: Color(hex: 0xC2AEF7), idleRing: Color(hex: 0xFFFFFF, alpha: 0.20),
        textPrimary: Color(hex: 0xF5F6FA), textSecondary: Color(hex: 0x8C8F9C),
        good: Color(hex: 0x7FD9B8), warn: Color(hex: 0xF0C283), bad: Color(hex: 0xF08FA0),
        blob1: Color(hex: 0x121722), blob2: Color(hex: 0x17121F), blob3: Color(hex: 0x0F1A18),
        isDark: true)

    /// Глубокий тёмный фон и насыщенный красный акцент — тема под
    /// стеклянный редизайн со сворачиваемой боковой панелью.
    static let ruby = Palette(
        id: "ruby", nameRU: "Рубин", nameEN: "Ruby",
        background: Color(hex: 0x0A0A0F), card: Color(hex: 0x1A1A22), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.10),
        accentStart: Color(hex: 0xE5383B), accentEnd: Color(hex: 0xFF5C61), idleRing: Color(hex: 0xFFFFFF, alpha: 0.20),
        textPrimary: Color(hex: 0xF4F4F7), textSecondary: Color(hex: 0x8E8E9C),
        good: Color(hex: 0x4ADE9A), warn: Color(hex: 0xF5B451), bad: Color(hex: 0xFF6B6B),
        blob1: Color(hex: 0x5A1220), blob2: Color(hex: 0x23194A), blob3: Color(hex: 0x10283F),
        isDark: true)

    static let amethyst = Palette(
        id: "amethyst", nameRU: "Аметист", nameEN: "Amethyst",
        background: Color(hex: 0x09080F), card: Color(hex: 0x1A1824), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.10),
        accentStart: Color(hex: 0x7C5CFF), accentEnd: Color(hex: 0xA48BFF), idleRing: Color(hex: 0xFFFFFF, alpha: 0.20),
        textPrimary: Color(hex: 0xF4F4F7), textSecondary: Color(hex: 0x8E8E9C),
        good: Color(hex: 0x4ADE9A), warn: Color(hex: 0xF5B451), bad: Color(hex: 0xFF6B6B),
        blob1: Color(hex: 0x2A1A5E), blob2: Color(hex: 0x5A1230), blob3: Color(hex: 0x10283F),
        isDark: true)

    static let lagoon = Palette(
        id: "lagoon", nameRU: "Лагуна", nameEN: "Lagoon",
        background: Color(hex: 0x060B0D), card: Color(hex: 0x141C20), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.10),
        accentStart: Color(hex: 0x14B8A6), accentEnd: Color(hex: 0x3DDCC8), idleRing: Color(hex: 0xFFFFFF, alpha: 0.20),
        textPrimary: Color(hex: 0xF2F6F7), textSecondary: Color(hex: 0x8A979C),
        good: Color(hex: 0x4ADE9A), warn: Color(hex: 0xF5B451), bad: Color(hex: 0xFF6B6B),
        blob1: Color(hex: 0x0E3B3A), blob2: Color(hex: 0x1D1554), blob3: Color(hex: 0x10283F),
        isDark: true)

    static let amber = Palette(
        id: "amber", nameRU: "Янтарь", nameEN: "Amber",
        background: Color(hex: 0x0B0906), card: Color(hex: 0x1E1A14), cardBorder: Color(hex: 0xFFFFFF, alpha: 0.10),
        accentStart: Color(hex: 0xF59E0B), accentEnd: Color(hex: 0xFFC14D), idleRing: Color(hex: 0xFFFFFF, alpha: 0.20),
        textPrimary: Color(hex: 0xF7F5F2), textSecondary: Color(hex: 0x9C9488),
        good: Color(hex: 0x4ADE9A), warn: Color(hex: 0xF5B451), bad: Color(hex: 0xFF6B6B),
        blob1: Color(hex: 0x4A2C08), blob2: Color(hex: 0x5A1230), blob3: Color(hex: 0x10283F),
        isDark: true)

    /// Сначала — тёмные темы «Обсидиана», под которые нарисован интерфейс;
    /// прежние пастельные остаются для тех, кто к ним привык.
    static let all: [Palette] = [.ruby, .amethyst, .lagoon, .amber, .night, .amoled,
                                 .sky, .mint, .lavender, .peach, .rose]

    static func named(_ id: String) -> Palette {
        all.first { $0.id == id } ?? .ruby
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Размеры

/// Общий масштаб интерфейса.
///
/// Один множитель на всё: кегли, отступы, размеры элементов. Менять плотность
/// интерфейса правкой полусотни чисел по файлам — верный способ рассогласовать
/// сетку, поэтому все размеры проходят через `UI.s`.
enum UI {
    static let scale: CGFloat = 0.9

    /// Кегли масштабируются мягче раскладки: отступы можно ужимать сколько
    /// угодно, а текст ниже определённого размера просто перестаёт читаться.
    static let textScale: CGFloat = 1.09

    static func s(_ value: CGFloat) -> CGFloat { value * scale }
    static func t(_ value: CGFloat) -> CGFloat { value * scale * textScale }
}

enum Metrics {
    /// Не срез, а скругление: вся форма интерфейса мягкая.
    static let cut = UI.s(18)
    static let gutter = UI.s(13)
    static let cardPadding = UI.s(12)
    static let rowGap = UI.s(6)
}

// MARK: - Доступ из иерархии

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .ruby
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
