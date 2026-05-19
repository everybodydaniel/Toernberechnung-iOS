import Foundation

/// Abstraktion zum Abrufen von Tidendaten für eine BSH-Referenzstation.
///
/// Unterstützt mehrere Backends:
/// - Online-BSH-API (`BSHTideDataProvider`)
/// - Mockdaten für Unit-Tests (`MockTideDataProvider`)
/// - Manuelle Nutzereingabe als Fallback
///
/// Der Provider muss sauber scheitern, wenn eine Stations-ID unbekannt, nicht verfügbar,
/// umbenannt oder vom BSH nicht unterstützt wird. Niemals bei fehlenden Daten abstürzen.
protocol TideDataProvider {
    /// Holt Hochwasser-Ereignisse für eine Referenzstation rund um ein Datum.
    ///
    /// - Parameters:
    ///   - stationID: BSH-Stations-ID (z. B. „507P“). Kann vorläufig oder fehlerhaft sein.
    ///   - date: Das ungefähre Suchdatum.
    /// - Returns: Nach Zeit sortiertes Array von `TideEvent` oder leer, wenn die Station unbekannt ist.
    /// - Throws: Netzwerk- und Parse-Fehler. Bei unbekannter Station leeres Ergebnis statt Fehler.
    func highWaters(
        for stationID: String,
        around date: Date
    ) async throws -> [TideEvent]

    /// Liefert den mittleren Tidenhub einer Station, sofern verfügbar.
    /// Gibt nil zurück, falls der Provider diesen Wert nicht liefert.
    func meanTidalRange(for stationID: String) async throws -> Double?

    /// Liefert das mittlere Hochwasser einer Station, sofern verfügbar.
    /// Gibt nil zurück, falls der Provider diesen Wert nicht liefert.
    func meanHighWater(for stationID: String) async throws -> Double?
}

/// Adapter, der den bestehenden `BSHTideService` als `TideDataProvider` bereitstellt.
///
/// Bildet Stations-IDs auf `HarbourOption` für den BSH-Aufruf ab.
/// Findet sich eine Stations-ID nicht in der bekannten Hafenliste, werden leere
/// Ergebnisse zurückgegeben, sodass die Berechnung den Wegpunkt als unvollständig markiert.
final class BSHTideDataProvider: TideDataProvider {

    func highWaters(
        for stationID: String,
        around date: Date
    ) async throws -> [TideEvent] {
        do {
            return try await BSHTideService.shared.highWaters(for: stationID, around: date)
        } catch {
            return []
        }
    }

    func meanTidalRange(for stationID: String) async throws -> Double? {
        return nil
    }

    func meanHighWater(for stationID: String) async throws -> Double? {
        return nil
    }
}

/// Mock-Provider für Unit-Tests. Liefert konfigurierbare Tidenereignisse.
final class MockTideDataProvider: TideDataProvider {
    /// Vorkonfigurierte Hochwasser-Ereignisse, indiziert nach Stations-ID.
    var highWatersByStation: [String: [TideEvent]] = [:]
    /// Vorkonfigurierte mittlere Tidenhübe, indiziert nach Stations-ID.
    var meanTidalRanges: [String: Double] = [:]
    /// Vorkonfigurierte mittlere Hochwasserwerte, indiziert nach Stations-ID.
    var meanHighWaters: [String: Double] = [:]
    /// Wenn true, wird beim Abruf ein Fehler geworfen (Netzwerkfehler simuliert).
    var shouldThrow: Bool = false

    func highWaters(for stationID: String, around date: Date) async throws -> [TideEvent] {
        if shouldThrow {
            throw BSHTideError.badResponse
        }
        return highWatersByStation[stationID] ?? []
    }

    func meanTidalRange(for stationID: String) async throws -> Double? {
        meanTidalRanges[stationID]
    }

    func meanHighWater(for stationID: String) async throws -> Double? {
        meanHighWaters[stationID]
    }
}
