import Foundation

/// Abstraktion für die Berechnung der Fehlmenge Wasser (FmW) anhand der
/// Zeitabweichung zum Hochwasser.
///
/// Standardimplementierung ist die **Zwölftelregel**, welche den Tidenhub
/// in 12 gleiche Teile teilt und Wasserstandsänderungen stündlichen Buckets zuordnet.
///
/// Zukünftige Strategien (z. B. harmonische Analyse, sinusförmige Interpolation) können
/// dieses Protokoll implementieren, ohne `RouteCalculationService` zu ändern.
protocol TidalHeightStrategy {
    /// Berechnet die Fehlmenge Wasser anhand der Zeitabweichung vom Hochwasser.
    ///
    /// - Parameters:
    ///   - deviationHours: Absolute Zeitdifferenz zum relevanten Hochwasser in Dezimalstunden.
    ///   - meanTidalRangeMeters: Mittlerer Tidenhub (MTH) in Metern.
    /// - Returns: Ein `TidalHeightResult` mit FmW, 1/12-Wert und Gültigkeit.
    func missingWater(
        deviationHours: Double,
        meanTidalRangeMeters: Double
    ) -> TidalHeightResult
}

/// Ergebnis einer Tidenhöhen-Strategie-Berechnung.
struct TidalHeightResult: Equatable {
    /// Fehlmenge Wasser in Metern (FmW).
    /// Direkt am Hochwasser ist dieser Wert 0.
    let fmwMeters: Double
    /// Ein Zwölftel des mittleren Tidenhubs in Metern.
    let oneTwelfthMeters: Double
    /// Ob die Berechnung gültig ist. Falsch, wenn deviationHours > 12.
    let isValid: Bool
    /// Erläuternde Meldungen (z. B. „keine Fehlmenge“ am HW oder Fehlerbeschreibungen).
    let messages: [String]
}

/// Die klassische Zwölftelregel zur Schätzung der Tidenhöhe.
///
/// Die Regel teilt den Tidenzyklus in stündliche Buckets und ordnet jeder Stunde
/// einen Anteil in Zwölfteln des Gesamttidenhubs zu:
///
/// ```
/// Stunde ab HW:  0   0-1   1-2   2-3   3-4   4-5   5-7   7-8   8-9   9-10  10-11  11-12  >12
/// Zwölftel:      0    1     3     6     9    11    12    11     9     6      3      1   ungültig
/// ```
///
/// Das Muster entspricht der näherungsweise sinusförmigen Tidenkurve:
/// - Nahe Hochwasser (0–1h): minimale Änderung (1/12)
/// - Mitte der Tide (2–4h): schnelle Änderung (6–9/12)
/// - Nahe Niedrigwasser (5–7h): voller Hub (12/12)
/// - Aufsteigend ab Niedrigwasser: symmetrisches Muster zurück zum HW
///
/// **Epsilon-Toleranz gegenüber dem Excel-Original:**
/// Bei `deviationHours < 0.01` wird FmW unabhängig von Gleitkomma-Rundungen auf 0 gesetzt.
/// So wird vermieden, dass eine Ankunftszeit, die nominell exakt am HW liegt,
/// aufgrund von Mikrosekundenabweichungen eine ungleich Null FmW erzeugt.
struct TwelfthsRuleStrategy: TidalHeightStrategy {

    /// Epsilon-Toleranz, ab der eine Ankunft als „am Hochwasser“ behandelt wird.
    /// Liegt die absolute Abweichung unter diesem Schwellwert, gilt FmW = 0.
    ///
    /// Bewusste Verbesserung gegenüber der Excel-Arbeitsmappe, die rohe
    /// Gleitkomma-Vergleiche nutzt und am exakten HW durch Rundungsartefakte
    /// winzige, von Null verschiedene FmW-Werte produzieren kann.
    static let hwEpsilonHours: Double = 0.01

    func missingWater(
        deviationHours: Double,
        meanTidalRangeMeters: Double
    ) -> TidalHeightResult {
        let oneTwelfth = meanTidalRangeMeters / 12.0

        if abs(deviationHours) < Self.hwEpsilonHours {
            return TidalHeightResult(
                fmwMeters: 0,
                oneTwelfthMeters: oneTwelfth,
                isValid: true,
                messages: ["keine Fehlmenge"]
            )
        }

        let hours = abs(deviationHours)

        guard hours <= 12 else {
            return TidalHeightResult(
                fmwMeters: 0,
                oneTwelfthMeters: oneTwelfth,
                isValid: false,
                messages: ["Berechnung nicht möglich: Ankunftszeit liegt mehr als 12 Stunden vom relevanten Hochwasser entfernt."]
            )
        }

        let twelfths: Double
        switch hours {
        case ...1:  twelfths = 1
        case ...2:  twelfths = 3
        case ...3:  twelfths = 6
        case ...4:  twelfths = 9
        case ...5:  twelfths = 11
        case ...7:  twelfths = 12
        case ...8:  twelfths = 11
        case ...9:  twelfths = 9
        case ...10: twelfths = 6
        case ...11: twelfths = 3
        case ...12: twelfths = 1
        default:    twelfths = 0
        }

        return TidalHeightResult(
            fmwMeters: twelfths * oneTwelfth,
            oneTwelfthMeters: oneTwelfth,
            isValid: true,
            messages: []
        )
    }
}
