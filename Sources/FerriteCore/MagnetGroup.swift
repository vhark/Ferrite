import Foundation

/// One window inside a magnet group.
///
/// Identity is `bundleID` + `slot` — exactly what `WindowMatcher` resolves for
/// restore — so grouping reuses the single identity path rather than inventing
/// a parallel one.
public struct MagnetMember: Codable, Equatable, Hashable {
    public var bundleID: String
    public var slot: Int
    /// Manual rank fed to the weighted presets. 1.0 is neutral.
    public var weight: Double

    public init(bundleID: String, slot: Int, weight: Double = 1) {
        self.bundleID = bundleID
        self.slot = slot
        self.weight = weight
    }
}

/// A set of windows the user mated edge-to-edge.
public struct MagnetGroup: Codable, Equatable, Identifiable {
    public enum ResizeMode: String, Codable {
        /// The mate resizes so the shared edge stays shared.
        case shrink
        /// The mate keeps its size and translates, possibly pushing its own mates.
        case nudge
        /// Nothing but the resized window moves: no shared-edge propagation
        /// and no proportional group settle. Membership survives — the group
        /// still carries, reflows and weighs as one.
        case standard
    }

    public static let minimumWeight: Double = 0.25
    public static let maximumWeight: Double = 8

    public var id: UUID
    public var members: [MagnetMember]
    public var resizeMode: ResizeMode

    public init(id: UUID = UUID(),
                members: [MagnetMember],
                resizeMode: ResizeMode = .shrink) {
        self.id = id
        self.members = members
        self.resizeMode = resizeMode
    }

    /// A group needs at least two windows to mean anything.
    public var isDissolved: Bool { members.count < 2 }

    public func contains(bundleID: String, slot: Int) -> Bool {
        index(ofBundleID: bundleID, slot: slot) != nil
    }

    public func index(ofBundleID bundleID: String, slot: Int) -> Int? {
        members.firstIndex { $0.bundleID == bundleID && $0.slot == slot }
    }

    /// Unions `other` in. A member present in both keeps the heavier weight —
    /// merging must never demote a window the user promoted.
    public mutating func merge(_ other: MagnetGroup) {
        for incoming in other.members {
            if let existing = index(ofBundleID: incoming.bundleID, slot: incoming.slot) {
                members[existing].weight = max(members[existing].weight, incoming.weight)
            } else {
                members.append(incoming)
            }
        }
    }

    @discardableResult
    public mutating func remove(bundleID: String, slot: Int) -> Bool {
        guard let index = index(ofBundleID: bundleID, slot: slot) else { return false }
        members.remove(at: index)
        return true
    }

    public mutating func adjustWeight(bundleID: String, slot: Int, by factor: Double) {
        guard let index = index(ofBundleID: bundleID, slot: slot) else { return }
        let scaled = members[index].weight * factor
        members[index].weight = min(Self.maximumWeight, max(Self.minimumWeight, scaled))
    }
}
