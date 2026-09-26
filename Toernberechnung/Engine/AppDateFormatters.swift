import Foundation

// MARK: - Datums- und Zeitformate
//
// Zentrale Formatierung von Datum und Uhrzeit in der App.
// Alle Formatierer verwenden `de_DE` und `Europe/Berlin`.
// So erscheinen deutsche Monatsnamen und Uhrzeiten im 24-Stunden-Format.
// UTC-Zeitstempel von BSH und WeatherKit werden in die Ortszeit umgerechnet.

enum AppDateFormatters {

    static let germanLocale = Locale(identifier: "de_DE")
    static let berlinTimeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current

    static let berlinCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlinTimeZone
        cal.locale = germanLocale
        return cal
    }()

    /// `HH:mm` (z. B. "14:30").
    static let hourMinute: DateFormatter = make("HH:mm")
    /// `dd.MM.yyyy` (z. B. "14.05.2026").
    static let dayMonthYear: DateFormatter = make("dd.MM.yyyy")
    /// `EEEE, dd.MM.yyyy` (z. B. "Donnerstag, 14.05.2026").
    static let weekdayLong: DateFormatter = make("EEEE, dd.MM.yyyy")
    /// `EE dd.MM. HH:mm` (z. B. "Do 14.05. 14:30").
    static let shortWeekdayDateTime: DateFormatter = make("EE dd.MM. HH:mm")
    /// `EEE` (z. B. "Do").
    static let weekdayShort: DateFormatter = make("EEE")
    /// `EEE dd.MM.` (z. B. "Do 14.05.").
    static let weekdayDay: DateFormatter = make("EEE dd.MM.")

    private static func make(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = germanLocale
        f.timeZone = berlinTimeZone
        f.dateFormat = pattern
        return f
    }

    /// Formatiert eine Dauer in Stunden als `Hh MMm`.
    static func duration(hours: Double) -> String {
        let totalMinutes = max(Int((hours * 60).rounded()), 0)
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
    }
}
