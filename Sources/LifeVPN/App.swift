import AppKit
import SwiftUI

@MainActor
struct LifeVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @StateObject private var connection = ConnectionManager.shared
    @StateObject private var store = ServerStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var core = CoreStatus()
    @StateObject private var updater = Updater.shared

    // 620×600: компактное окно с боковой панелью; раньше единственная колонка
    // несла в себе шапку, контент и нижний ряд вкладок друг над другом —
    // геометрия сходилась только при одной конкретной узкой ширине. Теперь
    // слева — сайдбар фиксированной ширины (см. Sidebar.width), справа —
    // контент на всю оставшуюся ширину; сайдбар и раскладка карточек в
    // контенте рассчитаны на эти конкретные размеры, поэтому окно по-прежнему
    // нерастягиваемое.
    private static let windowWidth: CGFloat = 620
    private static let windowHeight: CGFloat = 600

    var body: some Scene {
        Window("Life VPN", id: "main") {
            RootView()
                .environmentObject(connection)
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(core)
                .environmentObject(updater)
                // Смена языка перестраивает дерево целиком: строки берутся
                // при отрисовке, и без этого часть экранов осталась бы на
                // прежнем языке до следующего обновления.
                .id(settings.language)
                .frame(width: Self.windowWidth, height: Self.windowHeight)
                .task { await core.probe() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: Self.windowWidth, height: Self.windowHeight)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(connection)
                .environmentObject(store)
                .id(settings.language)
        } label: {
            Image(nsImage: TrayIcon.image(connected: connection.state.isConnected))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Демо: никаких обновлений подписок, баз правил и проверок версии.
        guard !DemoMode.isOn else {
            DemoShots.start()
            return
        }
        ServerStore.shared.startAutoRefresh()
        Updater.shared.startAutomaticChecks()

        // Базы правил — отдельной задачей: они ни от чего не зависят и не
        // должны задерживать замер задержки. Обновляются каждый запуск.
        let routing = AppSettings.shared.routing
        Task {
            await GeoAssets.refreshOnLaunch(
                geositeURL: routing.geositeURL.isEmpty ? GeoAssets.defaultGeositeURL : routing.geositeURL,
                geoipURL: routing.geoipURL.isEmpty ? GeoAssets.defaultGeoipURL : routing.geoipURL)
        }

        let measureLatency = AppSettings.shared.pingOnLaunch
        Task { await ServerStore.shared.prepareOnLaunch(measureLatency: measureLatency) }
    }

    /// Системный прокси обязан сниматься при выходе — иначе пользователь
    /// остаётся без интернета и без приложения, которое это чинит.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ConnectionManager.shared.shutdownSynchronously()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
