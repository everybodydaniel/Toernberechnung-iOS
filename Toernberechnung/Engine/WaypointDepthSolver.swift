import Foundation

// MARK: - Tiefenberechnung am Wegpunkt

/// Rechenschritte der Törnberechnung entsprechend den Zeilen `L35`…`L57`
/// des Referenzwerkzeugs "Excel-Tool-Törnberechnung_V2.1".
///
/// ```
/// L35  1/12tel         = L33 / 12
/// L39  FmW             = <Zwölftelstaffel> * L35
/// L45  Basis - FmW     = (L41 | L43) - L39
/// L49  HG              = L45 + L47            ("leer" im Lottiefe-Modus)
/// L53  WT              = L45 + L47 + L51
/// L57  WuK             = L53 - M55
/// ```
///
/// Diese Rechenschritte sind nur hier implementiert. Routenberechnung und
/// Passagefenstersuche verwenden dieselbe Funktion und liefern dadurch für
/// denselben Wegpunkt zur selben Zeit denselben Wert für Wasser unter Kiel.
///
/// Die Funktion ist zustandslos und synchron. Alle Eingaben sind bereits ermittelt.
/// Das Laden von Tidenhub, MHW und BSH-Wasserstandskorrektur übernimmt der Aufrufer.
enum WaypointDepthSolver {

    /// Vollständig ermittelte Eingaben für einen Wegpunkt zu einem Zeitpunkt.
    struct Inputs: Equatable {
        let calculationMode: WaypointCalculationMode
        /// Excel `L41` (MHW über SKN) oder `L43` (Lottiefe), je nach Modus.
        let referenceLevelMeters: Double
        /// Excel `L51`. Wird nur bei `.meanHighWater` angewendet. Kann negativ sein,
        /// wenn der Punkt oberhalb des Kartennulls trockenfällt.
        let chartDepthMeters: Double?
        /// Excel `L33`: mittlerer Tidenhub.
        let meanTidalRangeMeters: Double
        /// Excel `L37`: absoluter Abstand zum Hochwasser am Wegpunkt.
        let deviationHours: Double
        /// Excel `L47`: BSH-Wasserstandskorrektur (Windstau).
        let waterLevelCorrectionMeters: Double
        /// Excel `M55`: Tiefgang des Boots.
        let draftMeters: Double
        var missingWaterOverrideMeters: Double? = nil
    }

    /// Alle Zwischenwerte der Excel-Tabelle, damit die Oberfläche die
    /// Rechenschritte einzeln und nicht nur das Endergebnis anzeigen kann.
    struct Output: Equatable {
        let oneTwelfthMeters: Double            // L35
        let missingWaterMeters: Double          // L39
        let baseMeters: Double                  // L45
        /// Excel `L49`. Im Lottiefe-Modus nil; die Tabelle zeigt dort "leer".
        let tideHeightHGMeters: Double?
        /// Tatsächlich angewendeter Wert aus Excel `L51`. Im Lottiefe-Modus nil.
        let chartDepthApplied: Double?
        let availableWaterDepthMeters: Double   // L53
        let clearanceUnderKeelMeters: Double    // L57
    }

    enum Failure: Error, Equatable {
        case deviationExceedsTidalCycle(messages: [String])
        /// Excel `L51` ist leer, obwohl der MHW-Modus diesen Wert benötigt.
        case missingChartDepth
    }

    /// Berechnet den Abstand zwischen Kiel und Grund anhand des Wasserstands.
    /// Reihenfolge und Einheiten bleiben erhalten: Korrektur, Kartentiefe, Tiefgang.
    static func solveTideHeight(_ height: Double, chartDepth: Double, correction: Double,
                                draft: Double, meanHighWater: Double, meanRange: Double) -> Output {
        let correctedHeight = height + correction
        let available = chartDepth + correctedHeight
        return Output(oneTwelfthMeters: meanRange / 12,
                      missingWaterMeters: meanHighWater - height,
                      baseMeters: height, tideHeightHGMeters: correctedHeight,
                      chartDepthApplied: chartDepth, availableWaterDepthMeters: available,
                      clearanceUnderKeelMeters: available - draft)
    }

    static func solve(
        _ inputs: Inputs,
        strategy: TidalHeightStrategy = TwelfthsRuleStrategy()
    ) -> Result<Output, Failure> {
        let approximation = strategy.missingWater(
            deviationHours: inputs.deviationHours,
            meanTidalRangeMeters: inputs.meanTidalRangeMeters
        )
        let tidal = inputs.missingWaterOverrideMeters.map {
            TidalHeightResult(fmwMeters: $0, oneTwelfthMeters: inputs.meanTidalRangeMeters / 12,
                              isValid: $0.isFinite, messages: [])
        } ?? approximation
        guard tidal.isValid else {
            return .failure(.deviationExceedsTidalCycle(messages: tidal.messages))
        }

        let base = inputs.referenceLevelMeters - tidal.fmwMeters

        switch inputs.calculationMode {
        case .meanHighWater:
            guard let chartDepth = inputs.chartDepthMeters else {
                return .failure(.missingChartDepth)
            }
            let tideHeight = base + inputs.waterLevelCorrectionMeters
            let availableDepth = tideHeight + chartDepth
            return .success(Output(
                oneTwelfthMeters: tidal.oneTwelfthMeters,
                missingWaterMeters: tidal.fmwMeters,
                baseMeters: base,
                tideHeightHGMeters: tideHeight,
                chartDepthApplied: chartDepth,
                availableWaterDepthMeters: availableDepth,
                clearanceUnderKeelMeters: availableDepth - inputs.draftMeters
            ))

        case .lottiefe:
            // Die Excel-Zelle ist mit "nicht bei Lottiefe" bezeichnet. Eine Lotung
            // berücksichtigt den Grund bereits; zusätzliche Kartentiefe würde ihn
            // doppelt zählen. Ein vorhandener Wert wird deshalb ausgelassen.
            let availableDepth = base + inputs.waterLevelCorrectionMeters
            return .success(Output(
                oneTwelfthMeters: tidal.oneTwelfthMeters,
                missingWaterMeters: tidal.fmwMeters,
                baseMeters: base,
                tideHeightHGMeters: nil,
                chartDepthApplied: nil,
                availableWaterDepthMeters: availableDepth,
                clearanceUnderKeelMeters: availableDepth - inputs.draftMeters
            ))
        }
    }
}
