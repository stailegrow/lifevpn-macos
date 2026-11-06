import Foundation
import AppKit

// Точка входа. Обычный запуск отдаём SwiftUI; с флагом --self-check вместо
// интерфейса прогоняем внутренние проверки и выходим с кодом результата.
if CommandLine.arguments.contains("--self-check") {
    SelfCheck.runAndExit()
}

// Каталог с узлами и ключами защищаем до того, как что-либо из него
// прочитано. Не вышло — не запускаемся: продолжать с небезопасным каталогом
// нельзя, а удалять профиль пользователя — тем более.
do {
    try Paths.secureDirectory(Paths.appSupport)
} catch {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = L.t("Не удалось защитить данные Life VPN", "Could not secure Life VPN data")
    alert.informativeText = error.localizedDescription + "\n\n" + Paths.appSupport.path
    alert.runModal()
    exit(1)
}

// Регистрируем до первого кадра — иначе первый экран успеет отрисоваться
// системным шрифтом и дёрнется при перерисовке.
Typography.register()

LifeVPNApp.main()
