import Foundation

/// Состояние ядра на этапе 0: умеем только проверить, что бинарник на месте
/// и запускается. На этапе 1 сюда переедет ConnectionManager.
@MainActor
final class CoreStatus: ObservableObject {
    @Published private(set) var xrayVersion: String?
    @Published private(set) var failure: String?
    @Published private(set) var isProbing = false

    func probe() async {
        isProbing = true
        defer { isProbing = false }

        do {
            let version = try await Task.detached(priority: .userInitiated) {
                try XrayBinary.version()
            }.value
            xrayVersion = version.isEmpty ? L.t("неизвестна", "unknown") : version
            failure = nil
        } catch {
            xrayVersion = nil
            failure = error.localizedDescription
        }
    }
}
