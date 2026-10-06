import Foundation

// Точка входа. Обычный запуск отдаём SwiftUI; с флагом --self-check вместо
// интерфейса прогоняем внутренние проверки и выходим с кодом результата.
if CommandLine.arguments.contains("--self-check") {
    SelfCheck.runAndExit()
}

// Регистрируем до первого кадра — иначе первый экран успеет отрисоваться
// системным шрифтом и дёрнется при перерисовке.
Typography.register()

LifeVPNApp.main()
