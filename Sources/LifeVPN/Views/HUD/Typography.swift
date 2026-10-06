import AppKit
import SwiftUI

/// Роли шрифтов.
///
/// Никаких фирменных гарнитур: нежному, воздушному оформлению нужна
/// спокойная человечная типографика, а системный шрифт macOS ровно такой —
/// и заодно избавляет сборку от скачивания и регистрации файлов шрифтов.
/// Имена ролей сохранены из первой версии, поэтому разметка их не заметила.
enum Typography {

    /// Осталась ради симметрии с точкой входа: регистрировать больше нечего.
    static func register() {}

    static var statusText: String {
        L.t("системный", "system")
    }

    /// Кегли проходят через общий масштаб интерфейса — см. UI.textScale.
    private static func scaled(_ size: CGFloat) -> CGFloat { UI.t(size) }

    // MARK: - Роли

    /// Крупная надпись: состояние подключения, числа на карточках.
    static func hero(_ size: CGFloat) -> Font {
        .system(size: scaled(size), weight: .bold, design: .default)
    }

    /// Заголовки панелей и кнопок.
    static func heading(_ size: CGFloat) -> Font {
        .system(size: scaled(size), weight: .semibold, design: .default)
    }

    static func label(_ size: CGFloat) -> Font {
        .system(size: scaled(size), weight: .medium, design: .default)
    }

    static func body(_ size: CGFloat) -> Font {
        .system(size: scaled(size), weight: .regular)
    }

    /// Цифры, адреса, логи — всё, что должно стоять в колонку.
    static func code(_ size: CGFloat) -> Font {
        .system(size: scaled(size), design: .monospaced)
    }

    /// Вордмарк.
    static func stencil(_ size: CGFloat) -> Font {
        .system(size: scaled(size), weight: .semibold, design: .default)
    }

    /// Разрядка для мелких подписей.
    static func wide(_ size: CGFloat) -> Font {
        .system(size: scaled(size), weight: .medium, design: .default)
    }
}
