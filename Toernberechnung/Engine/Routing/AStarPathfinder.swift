import Foundation
import CoreLocation

final class AStarPathfinder {

    private static let maxExpansions = 600_000
    private static let straightCost = 1.0
    private static let diagonalCost = 2.0.squareRoot()
    private static let minCostMultiplier = 0.85

    private static let dr: [Int] = [-1, -1, -1, 0, 0, 1, 1, 1]
    private static let dc: [Int] = [-1, 0, 1, -1, 1, -1, 0, 1]
    private static let isDiag: [Bool] = [true, false, true, false, false, true, false, true]

    func findPath(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D]? {
        guard SeaMask.shared.isReady else { return nil }

        guard let startCell = snapToNavigable(start),
              let endCell = snapToNavigable(end) else {
            return nil
        }

        let (sr, sc) = startCell
        let (er, ec) = endCell

        if sr == er && sc == ec {
            return [start, end]
        }

        var gScore: [Int: Double] = [:]
        var parent: [Int: Int] = [:]
        var closed = Set<Int>()

        var open = PriorityQueue()

        let startIdx = GridConfig.index(row: sr, col: sc)
        let endIdx = GridConfig.index(row: er, col: ec)
        gScore[startIdx] = 0.0
        open.insert(AStarNode(row: sr, col: sc, fScore: heuristic(r1: sr, c1: sc, r2: er, c2: ec)))

        var expansions = 0
        var found = false

        while let node = open.removeMin() {
            let r = node.row
            let c = node.col
            let curIdx = GridConfig.index(row: r, col: c)

            if closed.contains(curIdx) { continue }
            closed.insert(curIdx)
            expansions += 1

            if curIdx == endIdx { found = true; break }
            if expansions >= Self.maxExpansions { break }

            guard let curG = gScore[curIdx] else { continue }

            for d in 0..<8 {
                let nr = r + Self.dr[d]
                let nc = c + Self.dc[d]
                guard GridConfig.inBounds(row: nr, col: nc) else { continue }

                let neighborCell = SeaMask.shared.cellAt(row: nr, col: nc)
                guard !neighborCell.isBlocked else { continue }

                if Self.isDiag[d] {
                    let adj1 = SeaMask.shared.cellAt(row: r, col: nc)
                    let adj2 = SeaMask.shared.cellAt(row: nr, col: c)
                    if adj1.isBlocked && adj2.isBlocked { continue }
                    if adj1.isBlocked || adj2.isBlocked { continue }
                }

                let stepCost = Self.isDiag[d] ? Self.diagonalCost : Self.straightCost
                let tentativeG = curG + stepCost * neighborCell.cost

                let nIdx = GridConfig.index(row: nr, col: nc)
                if let knownG = gScore[nIdx], tentativeG >= knownG { continue }

                gScore[nIdx] = tentativeG
                parent[nIdx] = curIdx
                let h = heuristic(r1: nr, c1: nc, r2: er, c2: ec)
                open.insert(AStarNode(row: nr, col: nc, fScore: tentativeG + h))
            }
        }

        guard found else { return nil }

        var gridPath: [Int] = []
        var cur: Int? = endIdx
        while let c = cur {
            gridPath.append(c)
            cur = parent[c]
        }
        gridPath.reverse()

        var latLngPath: [CLLocationCoordinate2D] = [start]
        for idx in gridPath {
            let row = idx / GridConfig.cols
            let col = idx % GridConfig.cols
            latLngPath.append(CLLocationCoordinate2D(
                latitude: GridConfig.rowToLat(row),
                longitude: GridConfig.colToLon(col)
            ))
        }
        latLngPath.append(end)
        return latLngPath
    }

    private func heuristic(r1: Int, c1: Int, r2: Int, c2: Int) -> Double {
        let dr = abs(r1 - r2)
        let dc = abs(c1 - c2)
        let straight = Self.straightCost * Self.minCostMultiplier
        let diagonal = Self.diagonalCost * Self.minCostMultiplier
        return straight * Double(dr + dc) + (diagonal - 2.0 * straight) * Double(min(dr, dc))
    }

    private func snapToNavigable(_ point: CLLocationCoordinate2D) -> (Int, Int)? {
        guard GridConfig.inBounds(lat: point.latitude, lon: point.longitude) else { return nil }
        let r0 = GridConfig.latToRow(point.latitude)
        let c0 = GridConfig.lonToCol(point.longitude)

        // Prefer the connected "through-water" network (open sea / fairway /
        // Wattfahrwasser). Harbour pins sit on land or inside HARBOUR basins,
        // and such basins can be enclosed pockets in the rasterised mask — if
        // we snap there, A* finds no escape and the route degrades to a
        // straight line through everything. Snapping to the nearest
        // through-water cell instead puts start/end on the navigable network
        // the route actually uses, so A* always finds a path.
        if SeaMask.shared.isThroughWater(row: r0, col: c0) { return (r0, c0) }

        // Closest any-navigable cell, used only if no through-water is in range.
        var fallback: (Int, Int)? = SeaMask.shared.isNavigable(row: r0, col: c0) ? (r0, c0) : nil

        let maxRadius = 80
        for radius in 1...maxRadius {
            let rMin = max(0, r0 - radius)
            let rMax = min(GridConfig.rows - 1, r0 + radius)
            let cMin = max(0, c0 - radius)
            let cMax = min(GridConfig.cols - 1, c0 + radius)

            for r in rMin...rMax {
                for c in cMin...cMax {
                    let ringDist = max(abs(r - r0), abs(c - c0))
                    guard ringDist == radius else { continue }
                    if SeaMask.shared.isThroughWater(row: r, col: c) {
                        return (r, c)
                    }
                    if fallback == nil, SeaMask.shared.isNavigable(row: r, col: c) {
                        fallback = (r, c)
                    }
                }
            }
        }
        return fallback
    }
}

// MARK: - Priority Queue (Min-Heap)

private struct AStarNode: Comparable {
    let row: Int
    let col: Int
    let fScore: Double

    static func < (lhs: AStarNode, rhs: AStarNode) -> Bool {
        lhs.fScore < rhs.fScore
    }
}

private struct PriorityQueue {
    private var heap: [AStarNode] = []

    var isEmpty: Bool { heap.isEmpty }

    mutating func insert(_ node: AStarNode) {
        heap.append(node)
        siftUp(heap.count - 1)
    }

    mutating func removeMin() -> AStarNode? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let min = heap[0]
        heap[0] = heap.removeLast()
        siftDown(0)
        return min
    }

    private mutating func siftUp(_ index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            if heap[i] < heap[parent] {
                heap.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var i = index
        let count = heap.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var smallest = i
            if left < count && heap[left] < heap[smallest] { smallest = left }
            if right < count && heap[right] < heap[smallest] { smallest = right }
            if smallest == i { break }
            heap.swapAt(i, smallest)
            i = smallest
        }
    }
}
