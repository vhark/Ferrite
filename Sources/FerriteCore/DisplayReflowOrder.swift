import Foundation

/// In-memory direction cycles for the built-in Columns and Rows display reflows.
/// Placement order is independent of current focus and of AX write/stacking order.
public struct DisplayReflowOrder {
    private struct Cycle {
        let preset: GroupLayoutSolver.Preset
        let keepGroups: Bool
        let order: [Set<Int>]
    }

    private var cycles: [String: Cycle] = [:]

    public init() {}

    public mutating func reset(displayID: String) {
        cycles.removeValue(forKey: displayID)
    }

    /// Tiles must represent disjoint sets of live windows. A kept group's identity
    /// is its membership, not whichever member currently represents it in z-order.
    /// Tiles absent from `membersByTile` represent individual windows.
    public mutating func orderedTiles(_ tiles: [GroupLayoutSolver.Tile],
                                      preset: GroupLayoutSolver.Preset,
                                      displayID: String,
                                      keepGroups: Bool,
                                      membersByTile: [Int: Set<Int>] = [:])
        -> [GroupLayoutSolver.Tile] {
        guard tiles.count > 1, preset == .columns || preset == .rows else {
            reset(displayID: displayID)
            return tiles
        }
        let identities = tiles.map { membersByTile[$0.id] ?? [$0.id] }
        guard let previous = cycles[displayID],
              previous.preset == preset, previous.keepGroups == keepGroups,
              Set(previous.order) == Set(identities) else {
            cycles[displayID] = Cycle(preset: preset, keepGroups: keepGroups,
                                      order: identities)
            return tiles
        }
        let reversed = Array(previous.order.reversed())
        cycles[displayID] = Cycle(preset: preset, keepGroups: keepGroups, order: reversed)
        let byIdentity = Dictionary(uniqueKeysWithValues: zip(identities, tiles))
        // Equal membership sets above guarantee every previous tile still exists.
        return reversed.map { byIdentity[$0]! }
    }
}
