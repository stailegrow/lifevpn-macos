import AppKit
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var store: ServerStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch connection.state {
        case .connected:
            Text(L.t("Подключено: ", "Connected: ")
                 + (connection.activeServer?.displayName ?? "—"))
            if let ip = connection.externalIP { Text(L.t("Внешний IP: \(ip)", "External IP: \(ip)")) }
        case .connecting:
            Text(L.t("Подключаюсь…", "Connecting…"))
        case .failed:
            Text(L.t("Ошибка подключения", "Connection error"))
        case .disconnected:
            Text(L.t("Отключено", "Disconnected"))
        }

        Divider()

        if connection.state.isConnected {
            Button(L.t("Отключиться", "Disconnect")) {
                Task { await connection.disconnect() }
            }
        } else if let server = store.selected {
            Button(L.t("Подключиться к \(server.displayName)", "Connect to \(server.displayName)")) {
                Task { await connection.connect(to: server) }
            }
        }

        if !store.servers.isEmpty {
            Menu(L.t("Серверы", "Servers")) {
                ForEach(store.servers) { server in
                    Button(server.displayName) {
                        store.selectedID = server.id
                        Task { await connection.connect(to: server) }
                    }
                }
            }
        }

        Divider()
        Button(L.t("Открыть Life VPN", "Open Life VPN")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button(L.t("Выйти", "Quit")) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
