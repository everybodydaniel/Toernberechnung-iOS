import Foundation

// MARK: - Protokoll zur Berechnung der Gezeitenhöhe

/// Schnittstelle zur Berechnung der Fehlmenge Wasser aus dem zeitlichen
/// Abstand zum Hochwasser.
///
/// Standard ist die Zwölftelregel: Sie teilt den Tidenhub in zwölf gleiche
/// Teile und ordnet den Stundenbereichen Wasserstandsänderungen zu.
///
/// Weitere Strategien wie harmonische Analyse oder Sinusinterpolation können
/// dieses Protokoll erfüllen, ohne `RouteCalculationService` zu ändern.
protocol TidalHeightStrategy {
    /// Berechnet die Fehlmenge Wasser aus dem Abstand zum Hochwasser.
    ///
    /// - Parameters:
    ///   - deviationHours: Absoluter Abstand zum passenden Hochwasser in Dezimalstunden.
    ///   - meanTidalRangeMeters: Mittlerer Tidenhub in Metern.
    /// - Returns: `TidalHeightResult` mit Fehlmenge Wasser, Zwölftelwert und Gültigkeit.
    func missingWater(
        deviationHours: Double,
        meanTidalRangeMeters: Double
    ) -> TidalHeightResult

    /// Umkehrung von `missingWater`: größter Abstand zum Hochwasser, bei dem
    /// die Fehlmenge Wasser noch höchstens `maxMissingWaterMeters` beträgt.
    ///
    /// Bestimmt damit, bis wann eine Ankunft bei ausreichender Wassertiefe möglich ist,
    /// ohne viele einzelne Ankunftszeiten zu prüfen.
    ///
    /// Gibt `nil` zurück, wenn auch zum Hochwasser die Wassertiefe nicht ausreicht.
    func maxDeviationHours(
        forMaxMissingWaterMeters maxMissingWaterMeters: Double,
        meanTidalRangeMeters: Double
    ) -> Double?
}

extension TidalHeightStrategy {
    /// Allgemeine Umkehrung durch wiederholte Halbierung des Suchbereichs.
    /// Geeignet für Strategien, deren Fehlmenge bei größerem Abstand zum Hochwasser
    /// zwischen Hoch- und Niedrigwasser nicht kleiner wird.
    func maxDeviationHours(
        forMaxMissingWaterMeters maxMissingWaterMeters: Double,
        meanTidalRangeMeters: Double
    ) -> Double? {
        guard maxMissingWaterMeters >= 0 else { return nil }

        let atFullCycle = missingWater(
            deviationHours: 12,
            meanTidalRangeMeters: meanTidalRangeMeters
        )
        if atFullCycle.isValid, atFullCycle.fmwMeters <= maxMissingWaterMeters { return 12 }

        var low = 0.0
        var high = 12.0
        for _ in 0 ..< 60 {
            let middle = (low + high) / 2
            let result = missingWater(
                deviationHours: middle,
                meanTidalRangeMeters: meanTidalRangeMeters
            )
            if result.isValid, result.fmwMeters <= maxMissingWaterMeters {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }
}

// MARK: - Ergebnis der Gezeitenhöhe

/// Ergebnis einer Berechnung mit der Gezeitenstrategie.
struct TidalHeightResult: Equatable {
    /// Fehlmenge Wasser (FmW) in Metern.
    /// Direkt zum Hochwasser beträgt sie 0.
    let fmwMeters: Double
    /// Ein Zwölftel des mittleren Tidenhubs in Metern.
    let oneTwelfthMeters: Double
    /// Gültigkeit der Berechnung. False, wenn deviationHours > 12 ist.
    let isValid: Bool
    /// Erläuterungen, z. B. "keine Fehlmenge" zum Hochwasser oder Fehlerbeschreibungen.
    let messages: [String]
}

// MARK: - Strategie nach der Zwölftelregel

/// Traditionelle Zwölftelregel zur Schätzung der Gezeitenhöhe.
///
/// Teilt den Gezeitenzyklus in Stundenbereiche und ordnet ihnen Anteile
/// des gesamten Tidenhubs zu:
///
/// ```
/// Stunden ab HW: 0   0-1   1-2   2-3   3-4   4-5   5-7   7-8   8-9   9-10  10-11  11-12  >12
/// Zwölftel:     0    1     3     6     9    11    12    11     9     6      3      1    ungültig
/// ```
///
/// Das Muster nähert den sinusförmigen Verlauf der Gezeitenkurve an:
/// - Nahe Hochwasser (0–1 h): geringe Änderung (1/12)
/// - Mittlerer Bereich (2–4 h): schnelle Änderung (6–9/12)
/// - Nahe Niedrigwasser (5–7 h): voller Tidenhub (12/12)
/// - Danach: symmetrischer Verlauf zurück zum Hochwasser
///
/// Bei `deviationHours < 0.01` wird FmW auf 0 gesetzt. So führen kleine
/// Rundungsabweichungen einer eigentlich zum Hochwasser liegenden Ankunft
/// nicht zu einer zusätzlichen Fehlmenge Wasser.
struct TwelfthsRuleStrategy: TidalHeightStrategy {

    /// Toleranz, innerhalb derer die Ankunft als genau zum Hochwasser gilt.
    /// Unterhalb dieser Grenze ist FmW = 0.
    ///
    /// Der Toleranzvergleich verhindert, dass kleine Gleitkommaabweichungen
    /// bei einer Ankunft zum Hochwasser eine Fehlmenge auslösen.
    static let hwEpsilonHours: Double = 0.01

    func missingWater(
        deviationHours: Double,
        meanTidalRangeMeters: Double
    ) -> TidalHeightResult {
        let oneTwelfth = meanTidalRangeMeters / 12.0

        // Hochwasser innerhalb der festgelegten Toleranz.
        if abs(deviationHours) < Self.hwEpsilonHours {
            return TidalHeightResult(
                fmwMeters: 0,
                oneTwelfthMeters: oneTwelfth,
                isValid: true,
                messages: ["keine Fehlmenge"]
            )
        }

        let hours = abs(deviationHours)

        // Abstand größer als ein vollständiger Gezeitenzyklus; keine nutzbare Berechnung.
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
        default:    twelfths = 0 // durch die vorherige Prüfung nicht erreichbar
        }

        return TidalHeightResult(
            fmwMeters: twelfths * oneTwelfth,
            oneTwelfthMeters: oneTwelfth,
            isValid: true,
            messages: []
        )
    }

    /// Direkte Umkehrung der Treppenfunktion.
    ///
    /// Das Ergebnis ist die obere Grenze des letzten Stundenbereichs,
    /// dessen Fehlmenge noch in die zulässige Wassermenge passt:
    ///
    /// ```
    /// Menge < 1/12  → 0 h  (nur genau zum Hochwasser)
    /// Menge < 3/12  → 1 h
    /// Menge < 6/12  → 2 h
    /// Menge < 9/12  → 3 h
    /// Menge < 11/12 → 4 h
    /// Menge < 12/12 → 5 h
    /// sonst        → 12 h (ausreichende Tiefe im gesamten Zyklus)
    /// ```
    func maxDeviationHours(
        forMaxMissingWaterMeters maxMissingWaterMeters: Double,
        meanTidalRangeMeters: Double
    ) -> Double? {
        guard maxMissingWaterMeters >= 0 else { return nil }

        let oneTwelfth = meanTidalRangeMeters / 12
        // Ohne Tidenhub entsteht keine Fehlmenge.
        guard oneTwelfth > 0 else { return 12 }

        // Kleine Toleranz, damit eine rechnerisch genaue Grenze von N/12
        // durch Gleitkommarundung nicht dem vorherigen Stundenbereich zugeordnet wird.
        let budgetInTwelfths = maxMissingWaterMeters / oneTwelfth + 1e-9

        switch budgetInTwelfths {
        case ..<1: return 0
        case ..<3: return 1
        case ..<6: return 2
        case ..<9: return 3
        case ..<11: return 4
        case ..<12: return 5
        default: return 12
        }
    }
}
