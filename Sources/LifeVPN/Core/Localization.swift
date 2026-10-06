import Foundation

/// Язык интерфейса.
enum Lang: String, CaseIterable, Codable, Identifiable, Sendable {
    case ru
    case en

    var id: String { rawValue }

    /// Название языка пишем на нём самом — так его узнают и те, кто
    /// открыл приложение на чужом языке.
    var title: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    var code: String {
        switch self {
        case .ru: return "RU"
        case .en: return "EN"
        }
    }

    /// Язык системы, если он нам известен. Первый запуск начинается с него.
    static var system: Lang {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("ru") ? .ru : .en
    }
}

/// Переводы живут рядом с местом, где строка нужна: `L.t("Закрыть", "Close")`.
///
/// Отдельная таблица ключей была бы аккуратнее на бумаге, но на практике
/// расходится с интерфейсом: ключ теряет смысл, перевод отстаёт, а пустой
/// ключ виден только в готовой сборке. Пара «оригинал — перевод» на месте
/// не даёт строке остаться без перевода: её просто негде забыть.
enum L {
    /// Читается отовсюду, меняется только из настроек. Гонка тут
    /// невозможна по существу: значение — одно перечисление из двух.
    nonisolated(unsafe) static var current: Lang = .ru

    static func t(_ ru: String, _ en: String) -> String {
        current == .ru ? ru : en
    }
}
