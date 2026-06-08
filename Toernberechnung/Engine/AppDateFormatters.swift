import Foundation

// MARK: - App Date Formatters
//
// Single source of truth for all human-readable date / time formatting in
// the app. Every formatter is pre-configured with the German locale
// (`de_DE`) and the Berlin time zone (`Europe/Berlin`) so the UI never
// shows English month names, AM/PM clocks, or off-by-one-hour values when
// the underlying timestamp is UTC-based (BSH / DWD payloads are).

enum AppDateFormatters {

    static let germanLocale = Locale(identifier: "de_DE")
    static let berlinTimeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current

    static let berlinCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlinTimeZone
        cal.locale = germanLocale
        return cal
    }()

    /// `HH:mm` (e.g. "14:30").
    static let hourMinute: DateFormatter = make("HH:mm")
    /// `dd.MM.yyyy` (e.g. "14.05.2026").
    static let dayMonthYear: DateFormatter = make("dd.MM.yyyy")
    /// `dd.MM. HH:mm` (e.g. "14.05. 14:30").
    static let shortDateTime: DateFormatter = make("dd.MM. HH:mm")
    /// `EEEE, dd.MM.yyyy` (e.g. "Donnerstag, 14.05.2026").
    static let weekdayLong: DateFormatter = make("EEEE, dd.MM.yyyy")
    /// `EE dd.MM. HH:mm` (e.g. "Do 14.05. 14:30").
    static let shortWeekdayDateTime: DateFormatter = make("EE dd.MM. HH:mm")

    private static func make(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = germanLocale
        f.timeZone = berlinTimeZone
        f.dateFormat = pattern
        return f
    }

    /// Format a duration in hours as `Hh MMm` (German short style).
    static func duration(hours: Double) -> String {
        let totalMinutes = max(Int((hours * 60).rounded()), 0)
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
    }
}
