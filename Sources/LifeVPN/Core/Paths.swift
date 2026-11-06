import Foundation
import Darwin

/// Все пути, по которым приложение пишет на диск.
///
/// Каталог `~/Library/Application Support/LifeVPN` хранит ссылки узлов с
/// ключами, поэтому до первого чтения он приводится к приватному виду
/// (`Paths.secureDirectory`): владелец — текущий пользователь, 0700, файлы
/// 0600, без расширяющих доступ ACL, без символических и жёстких ссылок.
enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("LifeVPN", isDirectory: true)
    }()

    /// Файлы, в которых могут быть секреты или следы подключения.
    static let privateFileNames = ["servers.json", "settings.json", "config.json",
                                   "proxy-state.json", "xray.log", "access.log"]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Создаёт (если нужно) и защищает каталог данных. Ошибка — повод не
    /// запускаться: с небезопасным каталогом не продолжаем и ничего не удаляем.
    static func secureDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw posix("lstat", directory.path) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        try protect(directory.path, directory: true)
        for name in privateFileNames {
            let path = directory.appendingPathComponent(name).path
            if lstat(path, &info) != 0 {
                if errno == ENOENT { continue }
                throw posix("lstat", path)
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw Failure(message: L.t("«\(name)» в каталоге данных — не обычный файл (например, ссылка). Запуск остановлен, файл не тронут.",
                                           "“\(name)” in the data folder is not a regular file (e.g. a link). Launch stopped, the file is untouched."))
            }
            guard info.st_uid == getuid() else {
                throw Failure(message: L.t("«\(name)» принадлежит другому пользователю.", "“\(name)” belongs to another user."))
            }
            guard info.st_nlink == 1 else {
                throw Failure(message: L.t("У «\(name)» есть жёсткие ссылки за пределами каталога.", "“\(name)” has hard links outside the folder."))
            }
            // Старые файлы с правами 000 сначала делаем читаемыми владельцу —
            // содержимое при этом не трогаем.
            guard chmod(path, 0o600) == 0 else { throw posix("chmod", path) }
            try protect(path, directory: false)
        }
    }

    /// Открывает объект без перехода по символической ссылке, проверяет тип,
    /// владельца и число ссылок, снимает ACL и выставляет права через fd —
    /// между проверкой и изменением объект нельзя подменить.
    private static func protect(_ path: String, directory: Bool) throws {
        let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posix("open", path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posix("fstat", path) }
        guard info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else {
            throw Failure(message: L.t("Небезопасный объект в каталоге данных: \(path)", "Unsafe object in the data folder: \(path)"))
        }
        guard let acl = acl_init(0) else { throw posix("acl_init", path) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw posix("acl_set_fd_np", path) }
        guard fchmod(fd, directory ? 0o700 : 0o600) == 0 else { throw posix("fchmod", path) }
    }

    /// Атомарная запись приватного файла: временный файл создаётся уже с
    /// правами 0600 (а не по umask), затем атомарно заменяет прежний.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posix("open", temporary.path) }
        var ok = false
        defer { if !ok { unlink(temporary.path) } }
        let written = data.withUnsafeBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return -1 }
                offset += n
            }
            return offset
        }
        guard written == data.count, fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
            let failure = posix("write", temporary.path)
            close(fd)
            throw failure
        }
        close(fd)
        guard rename(temporary.path, url.path) == 0 else { throw posix("rename", url.path) }
        ok = true
    }

    private static func posix(_ call: String, _ path: String) -> Failure {
        let code = errno
        return Failure(message: "\(call) \(path): \(String(cString: strerror(code)))")
    }

    static var generatedConfig: URL { appSupport.appendingPathComponent("config.json") }
    static var coreLog: URL { appSupport.appendingPathComponent("xray.log") }
    static var accessLog: URL { appSupport.appendingPathComponent("access.log") }
    static var servers: URL { appSupport.appendingPathComponent("servers.json") }
    static var settings: URL { appSupport.appendingPathComponent("settings.json") }
    static var geoDir: URL {
        let dir = appSupport.appendingPathComponent("geo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
}
