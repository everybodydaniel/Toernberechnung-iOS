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
        // 1:1 mit Original: nur LAND und RESTRICTED sind
        // blockiert. RUHEZONE ist NICHT blockiert, sondern teuer befahrbar
        // (Kosten 2.0) — A* meidet Ruhezonen/Schutzgebiete dadurch, kann sie
        // aber in Engstellen durchfahren, statt gar keinen Weg zu finden und
        // auf eine Gerade durch Land zurückzufallen.
        self == .land || self == .restricted
    }

    /// The connected open sailing network: open sea, marked fairways and
    /// Wattfahrwasser. Used as the preferred snap target so a harbour pin is
    /// never snapped into an enclosed HARBOUR basin (which can be disconnected
    /// from the sea in the rasterised mask and would leave A* with no path).
    var isThroughWater: Bool {
        self == .openSea || self == .fairway || self == .wattfahrwasser
    }
}
