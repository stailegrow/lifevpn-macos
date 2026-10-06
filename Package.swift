// swift-tools-version: 6.0
import PackageDescription

// Тестового таргета нет намеренно: XCTest поставляется только с Xcode, а
// проект должен собираться на голых Command Line Tools. Проверки живут
// в SelfCheck.swift и запускаются как `swift run LifeVPN --self-check`.
let package = Package(
    name: "LifeVPN",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "LifeVPN",
            path: "Sources/LifeVPN",
            resources: [
                .copy("Resources/xray")
            ]
        )
    ]
)
