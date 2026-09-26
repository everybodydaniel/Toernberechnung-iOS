import Foundation

enum CellType: UInt8, CaseIterable {
    case openSea = 0
    case fairway = 1
    case harbour = 2
    case wattfahrwasser = 3
    case land = 4
    case restricted = 5
    case ruhezone = 6

    var cost: Double {
        switch self {
        case .openSea: return 1.0
        case .fairway: return 0.85
        case .harbour: return 1.0
        case .wattfahrwasser: return 0.95
        case .land: return .greatestFiniteMagnitude
        case .restricted: return .greatestFiniteMagnitude
        case .ruhezone: return 8.0
        }
    }

    var isBlocked: Bool {
        // Land und gesperrte Bereiche sind nicht befahrbar. Ruhezonen erhalten
        // höhere Kosten. Die Suche meidet sie, kann sie aber an Engstellen durchfahren.
        self == .land || self == .restricted
    }

    /// Zusammenhängendes befahrbares Netz aus offener See und markierten Fahrwassern.
    /// Bevorzugtes Ziel für die Zuordnung von Hafenmarkierungen. Verhindert, dass
    /// sie einem abgeschlossenen HARBOUR-Becken der Rastermaske zugeordnet werden,
    /// aus dem A* keinen Weg ins offene Wasser findet.
    var isThroughWater: Bool {
        self == .openSea || self == .fairway || self == .wattfahrwasser
    }
}
