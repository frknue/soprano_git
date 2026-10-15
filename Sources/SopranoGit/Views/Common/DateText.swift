import Foundation

/// Dates as lists show them, deterministic given `now`, time zone and the
/// en_US_POSIX locale.
enum DateText {
    static func format(
        _ date: Date,
        style: AppSettings.DateStyle,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        switch style {
        case .absolute:
            return formatter("yyyy-MM-dd HH:mm", timeZone: timeZone).string(from: date)
        case .relative:
            let seconds = max(0, now.timeIntervalSince(date))
            let minutes = Int(seconds / 60)
            let hours = minutes / 60
            let days = hours / 24
            if minutes < 1 { return "now" }
            if hours < 1 { return "\(minutes)m" }
            if days < 1 { return "\(hours)h" }
            if days < 7 { return "\(days)d" }
            if days < 35 { return "\(days / 7)w" }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return formatter(sameYear ? "MMM d" : "MMM d yyyy", timeZone: timeZone).string(from: date)
        }
    }

    private struct FormatterKey: Hashable {
        let format: String
        let timeZone: TimeZone
    }

    /// Building a DateFormatter costs ~150 µs, more than a whole graph row; formatters
    /// are reused (formatting is thread-safe, the cache is locked).
    private nonisolated(unsafe) static var formatters: [FormatterKey: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let key = FormatterKey(format: format, timeZone: timeZone)
        formattersLock.lock()
        defer { formattersLock.unlock() }
        if let formatter = formatters[key] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatters[key] = formatter
        return formatter
    }
}
