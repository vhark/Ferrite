import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Turns a magnet group plus its live windows into solved frames.
///
/// The group reflows inside its own bounding box rather than the whole display,
/// so a group occupying the left half stays in the left half.
public enum GroupReflowPlanner {
    public struct LiveWindow: Equatable {
        public let id: Int
        public let bundleID: String
        public let slot: Int
        public let frame: CGRect

        public init(id: Int, bundleID: String, slot: Int, frame: CGRect) {
            self.id = id
            self.bundleID = bundleID
            self.slot = slot
            self.frame = frame
        }
    }

    public struct Plan: Equatable {
        public let bounds: CGRect
        /// Window id → target frame.
        public let frames: [Int: CGRect]
    }

    public static func plan(group: MagnetGroup,
                            live: [LiveWindow],
                            preset: GroupLayoutSolver.Preset,
                            gap: CGFloat = 8,
                            minimumSize: CGSize = CGSize(width: 240, height: 160)) -> Plan? {
        // Preserve member order: it is the order the user built the group in.
        let resolved: [(window: LiveWindow, weight: Double)] = group.members.compactMap { member in
            guard let window = live.first(where: {
                $0.bundleID == member.bundleID && $0.slot == member.slot
            }) else { return nil }
            return (window, member.weight)
        }
        guard resolved.count > 1 else { return nil }

        let bounds = resolved.dropFirst().reduce(resolved[0].window.frame) {
            $0.union($1.window.frame)
        }
        let tiles = resolved.map {
            GroupLayoutSolver.Tile(id: $0.window.id, weight: $0.weight)
        }
        let frames = GroupLayoutSolver.solve(tiles: tiles, preset: preset, in: bounds,
                                             gap: gap, minimumSize: minimumSize)
        return Plan(bounds: bounds, frames: frames)
    }
}
