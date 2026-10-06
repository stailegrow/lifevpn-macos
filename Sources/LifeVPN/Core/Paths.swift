import Foundation

/// Все пути, по которым приложение пишет на диск.
///
/// Держим их в одном месте: на этапе TUN сюда добавится состояние маршрутов,
/// которое надо уметь откатывать после аварийного завершения.
enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LifeVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var generatedConfig: URL { appSupport.appendingPathComponent("config.json") }
    static var coreLog: URL { appSupport.appendingPathComponent("xray.log") }
    static var servers: URL { appSupport.appendingPathComponent("servers.json") }
    static var settings: URL { appSupport.appendingPathComponent("settings.json") }
    static var geoDir: URL {
        let dir = appSupport.appendingPathComponent("geo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
