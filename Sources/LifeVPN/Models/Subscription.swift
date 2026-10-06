import Foundation

/// Подписка — источник, из которого список серверов подтягивается целиком
/// и переживает изменения на стороне сервиса.
struct Subscription: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var url: String = ""

    /// 0 — обновлять только вручную.
    var updateIntervalHours: Double = 12

    var lastUpdated: Date?
    var lastError: String?

    /// Заголовки, которыми панель описывает подписку.
    var announce: String?
    var usedBytes: Int64?
    var totalBytes: Int64?
    var expiresAt: Date?

    var displayName: String {
        if !name.isEmpty { return name }
        return URL(string: url)?.host ?? L.t("Подписка", "Subscription")
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Сырое значение заголовка subscription-userinfo — панели врут по-разному,
    /// и без исходной строки разбираться в расхождениях невозможно.
    var rawUserInfo: String?

    /// Строка вида «12,4 ГБ из 100 ГБ» либо «12,4 ГБ из ∞».
    /// total = 0 у панелей означает безлимит, а не нулевой лимит.
    var trafficSummary: String? {
        guard let usedBytes else { return nil }
        let used = Self.formatBytes(usedBytes)
        guard let totalBytes, totalBytes > 0 else { return L.t("\(used) из ∞", "\(used) of ∞") }
        return L.t("\(used) из \(Self.formatBytes(totalBytes))", "\(used) of \(Self.formatBytes(totalBytes))")
    }

    /// Доля израсходованного, 0…1. nil при безлимите.
    var trafficFraction: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var expirySummary: String? {
        guard let expiresAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: expiresAt)
    }

    static func formatBytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        // Иначе ноль превращается в «Zero KB».
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    /// «только что» вместо «через 0 секунд»: RelativeDateTimeFormatter
    /// на почти совпадающих датах уезжает в будущее.
    static func formatUpdated(_ date: Date?) -> String {
        guard let date else { return L.t("ещё ни разу", "never yet") }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return L.t("только что", "just now") }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Пора ли обновлять по расписанию.
    func isDue(now: Date = Date()) -> Bool {
        guard updateIntervalHours > 0 else { return false }
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) >= updateIntervalHours * 3600
    }
}
