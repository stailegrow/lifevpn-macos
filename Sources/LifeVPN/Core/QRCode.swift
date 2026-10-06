import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Чтение QR-кодов из картинок.
///
/// Три источника: буфер обмена, файл и кадр с камеры. Все сводятся к одному
/// CIImage, дальше работает системный детектор.
enum QRCode {

    /// Детектор создаётся на каждый разбор, а не живёт в статике: CIDetector
    /// не Sendable, и общий экземпляр не проходит проверку конкурентности.
    /// Кодов мы читаем единицы, так что экономить тут нечего.
    static func decode(_ image: CIImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                  context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        guard let detector else { return [] }
        return detector.features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .filter { !$0.isEmpty }
    }

    static func decode(_ image: NSImage) -> [String] {
        guard let data = image.tiffRepresentation,
              let ciImage = CIImage(data: data) else { return [] }
        return decode(ciImage)
    }

    static func decodeFromClipboard() -> [String] {
        let pasteboard = NSPasteboard.general
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            let found = images.flatMap(decode)
            if !found.isEmpty { return found }
        }
        // В буфере может лежать не картинка, а путь к файлу с ней.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            return urls.flatMap(decodeFromFile)
        }
        return []
    }

    static func decodeFromFile(_ url: URL) -> [String] {
        guard let ciImage = CIImage(contentsOf: url) else { return [] }
        return decode(ciImage)
    }

    /// Диалог выбора картинки. Возвращает найденные строки.
    @MainActor
    static func decodeFromChosenFile() -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L.t("Прочитать", "Read")
        panel.message = L.t("Выбери картинку с QR-кодом", "Choose an image with a QR code")

        guard panel.runModal() == .OK, let url = panel.url else { return [] }
        return decodeFromFile(url)
    }
}
