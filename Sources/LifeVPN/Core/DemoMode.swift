import Foundation

/// Демо-режим для скриншотов и презентаций: запуск с флагом `--demo`.
///
/// Вместо настоящих подписок — выдуманная, вместо замеров — правдоподобные
/// цифры, подключение и замер скорости только изображаются. На диск ничего
/// не пишется, в сеть приложение не ходит, системный прокси не трогает —
/// настоящие данные и настройки остаются как были.
enum DemoMode {
    static let isOn = CommandLine.arguments.contains("--demo")

    struct Node {
        let name: String
        let host: String
        let transport: Transport
        let latency: Int
    }

    static let nodes: [Node] = [
        Node(name: "🇳🇱 Amsterdam", host: "nl.example.com", transport: .tcp, latency: 38),
        Node(name: "🇩🇪 Frankfurt", host: "de.example.com", transport: .xhttp, latency: 44),
        Node(name: "🇫🇮 Helsinki", host: "fi.example.com", transport: .tcp, latency: 51),
        Node(name: "🇸🇪 Stockholm", host: "se.example.com", transport: .xhttp, latency: 57),
        Node(name: "🇬🇧 London", host: "uk.example.com", transport: .tcp, latency: 63),
        Node(name: "🇺🇸 New York", host: "us.example.com", transport: .xhttp, latency: 112)
    ]

    static func subscription() -> Subscription {
        var subscription = Subscription()
        subscription.name = "Life Premium"
        subscription.url = "https://example.com/sub"
        subscription.lastUpdated = Date().addingTimeInterval(-120)
        subscription.usedBytes = 52_184_000_000
        subscription.expiresAt = Date().addingTimeInterval(86_400 * 92)
        return subscription
    }

    static func servers(in subscription: Subscription) -> [ProxyConfig] {
        nodes.enumerated().map { index, node in
            var config = ProxyConfig()
            config.name = node.name
            config.address = node.host
            config.port = 443
            config.userID = String(format: "00000000-0000-4000-8000-%012d", index + 1)
            config.security = .reality
            config.transport = node.transport
            config.sni = "www.example.com"
            config.publicKey = "DEMO-PUBLIC-KEY"
            config.subscriptionID = subscription.id
            return config
        }
    }

    /// Задержка с лёгким дрожанием: строки графика живые, но ровные.
    static func latency(for config: ProxyConfig, step: Int) -> Int {
        let base = nodes.first { config.name == $0.name }?.latency ?? 60
        let wobble = [0, 2, -1, 3, 1, -2, 0, 4, -1, 1, 2, -3]
        let seed = abs(config.name.hashValue % 7)
        return base + wobble[(step + seed) % wobble.count]
    }
}

#if canImport(AppKit)
import AppKit

/// Снимки собственного окна для README — только в демо-режиме.
///
/// Запрос — файл `.demoshot` рядом с LifeVPN.app, внутри имя снимка. Окно
/// рисуется в PNG в полном разрешении экрана (на Retina — вдвое), без
/// курсора. Своё окно приложение снимает само, поэтому разрешение на запись
/// экрана не нужно.
@MainActor
enum DemoShots {
    private static var timer: Timer?

    static func start() {
        guard DemoMode.isOn, timer == nil else { return }
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            MainActor.assumeIsolated { poll(folder) }
        }
    }

    private static func poll(_ folder: URL) {
        let request = folder.appendingPathComponent(".demoshot")
        guard let raw = try? String(contentsOf: request, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: request)
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Life VPN" }),
              let content = window.contentView else { return }

        // Рамка окна целиком — вместе с кнопками-«светофором».
        let target = content.superview ?? content
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let dir = folder.appendingPathComponent("docs/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let status = folder.appendingPathComponent(".demoshot_status")
        do {
            try png.write(to: dir.appendingPathComponent(name + ".png"))
            try? "ok \(name) \(rep.pixelsWide)x\(rep.pixelsHigh)".write(to: status, atomically: true, encoding: .utf8)
        } catch {
            try? "fail \(name)".write(to: status, atomically: true, encoding: .utf8)
        }
    }
}
#endif
