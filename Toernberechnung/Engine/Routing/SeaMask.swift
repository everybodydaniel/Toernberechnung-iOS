import Foundation
import CoreLocation

final class SeaMask {

    static let shared = SeaMask()

    static let depthScale: Int16 = 10
    private static let defaultSeaDepthMeters = 5.0

    private(set) var isReady = false
    private var isBuilding = false

    private var cells: [UInt8] = []
    private var chartDepth: [Int16] = []
    private var buoyPositions: [Float] = []

    private init() {}

    func build() {
        guard !isBuilding else { return }
        isBuilding = true
        isReady = false

        let startTime = CFAbsoluteTimeGetCurrent()
        let result = SeaMaskBuilder.build()

        cells = result.cells
        chartDepth = result.chartDepth
        buoyPositions = result.buoyPositions

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[SeaMask] Built in \(Int(elapsed))ms — \(GridConfig.rows)×\(GridConfig.cols) grid, \(buoyPositions.count / 2) buoys indexed")

        isReady = true
        isBuilding = false
    }

    func cellAt(row: Int, col: Int) -> CellType {
        guard !cells.isEmpty else { return .openSea }
        guard GridConfig.inBounds(row: row, col: col) else { return .openSea }
        let raw = cells[GridConfig.index(row: row, col: col)]
        return CellType(rawValue: raw) ?? .openSea
    }

    func cellAtLatLng(lat: Double, lon: Double) -> CellType {
        guard GridConfig.inBounds(lat: lat, lon: lon) else { return .openSea }
        return cellAt(row: GridConfig.latToRow(lat), col: GridConfig.lonToCol(lon))
    }

    func depthAt(row: Int, col: Int) -> Double {
        guard !chartDepth.isEmpty else { return Self.defaultSeaDepthMeters }
        guard GridConfig.inBounds(row: row, col: col) else { return 10.0 }
        return Double(chartDepth[GridConfig.index(row: row, col: col)]) / Double(Self.depthScale)
    }

    func depthAtLatLng(lat: Double, lon: Double) -> Double {
        guard GridConfig.inBounds(lat: lat, lon: lon) else { return 10.0 }
        return depthAt(row: GridConfig.latToRow(lat), col: GridConfig.lonToCol(lon))
    }

    func isNavigable(row: Int, col: Int) -> Bool {
        !cellAt(row: row, col: col).isBlocked
    }

    func isNavigable(lat: Double, lon: Double) -> Bool {
        !cellAtLatLng(lat: lat, lon: lon).isBlocked
    }

    func isThroughWater(row: Int, col: Int) -> Bool {
        cellAt(row: row, col: col).isThroughWater
    }
}
