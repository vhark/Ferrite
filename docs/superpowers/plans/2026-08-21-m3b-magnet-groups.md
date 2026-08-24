# M3b — Magnet Groups, Shared-Edge Resize, Manual Weights

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish PRD Phase 3. Windows snap edge-to-edge during ordinary drags and remember that they are mated; dragging a shared edge resizes the mate (shrink or nudge); group members carry manual weights that feed the M3a treemap. After this milestone the reflow glyph row acts on the *group* you built, not merely on everything that happens to be on the display.

**Baseline:** `main` at `v0.6.0-m3a`, 158 tests passing. `GroupLayoutSolver.solve(tiles:preset:in:gap:minimumSize:)` is complete and property-tested.

**Design stance:** all geometry and all persistence live in `MacTLMCore` (Foundation + guarded CoreGraphics only) so the Linux port inherits the entire feature except the event plumbing. `Sources/MacTLM` contributes exactly four things: richer AX events, a mouse-up-terminated drag session, a preview overlay, and the apply calls.

---

## Vocabulary

- **Mate / mating** — two windows whose facing edges are flush (separated by the group gap). Mating is a user gesture: drag until edges are near, release.
- **Magnet group** — the transitive closure of mated windows, persisted per display configuration.
- **Shrink vs nudge** — when a shared edge moves, the mate either resizes to follow it (shrink) or translates while keeping its size (nudge, which can cascade into further mates).
- **Self-inflicted event** — an AX moved/resized notification caused by our own `setFrame`. These must never re-enter the mating or propagation logic.

---

## Task 1: Magnet group model with absent-tolerant persistence

**Files:** create `Sources/MacTLMCore/MagnetGroup.swift`; modify `Sources/MacTLMCore/WindowRecord.swift`; create `Tests/MacTLMCoreTests/MagnetGroupModelTests.swift`.

Members are identified by `bundleID` + `slot` — the same identity `WindowMatcher` already resolves for restore. Do not invent a second identity scheme; M2d's merge rewrite deliberately collapsed pin resolution into one path and this must not undo that.

- [ ] **Step 1: Write the tests first** in `Tests/MacTLMCoreTests/MagnetGroupModelTests.swift` (7 tests)

```swift
import XCTest
@testable import MacTLMCore

final class MagnetGroupModelTests: XCTestCase {
    private func member(_ bundle: String, _ slot: Int, weight: Double = 1) -> MagnetMember {
        MagnetMember(bundleID: bundle, slot: slot, weight: weight)
    }

    func testContainsFindsMemberByBundleAndSlot() {
        let group = MagnetGroup(members: [member("a", 0), member("b", 1)])
        XCTAssertTrue(group.contains(bundleID: "b", slot: 1))
        XCTAssertFalse(group.contains(bundleID: "b", slot: 0),
                       "slot is part of identity — a different window of the same app is not a member")
    }

    func testMergingGroupsUnionsMembersWithoutDuplicates() {
        var left = MagnetGroup(members: [member("a", 0), member("b", 0)])
        let right = MagnetGroup(members: [member("b", 0), member("c", 0)])
        left.merge(right)
        XCTAssertEqual(left.members.count, 3)
        XCTAssertTrue(left.contains(bundleID: "c", slot: 0))
    }

    func testMergePreservesTheHeavierWeightForASharedMember() {
        var left = MagnetGroup(members: [member("a", 0, weight: 3)])
        left.merge(MagnetGroup(members: [member("a", 0, weight: 1)]))
        XCTAssertEqual(left.members.count, 1)
        XCTAssertEqual(left.members[0].weight, 3, accuracy: 0.001,
                       "a merge must not silently demote a window the user had promoted")
    }

    func testRemovingTheSecondToLastMemberDissolvesTheGroup() {
        var group = MagnetGroup(members: [member("a", 0), member("b", 0)])
        XCTAssertTrue(group.remove(bundleID: "a", slot: 0))
        XCTAssertTrue(group.isDissolved, "a group of one is not a group")
    }

    func testAdjustWeightIsClampedToAUsableRange() {
        var group = MagnetGroup(members: [member("a", 0, weight: 1), member("b", 0)])
        for _ in 0..<20 { group.adjustWeight(bundleID: "a", slot: 0, by: 4) }
        XCTAssertLessThanOrEqual(group.members[0].weight, MagnetGroup.maximumWeight)
        for _ in 0..<40 { group.adjustWeight(bundleID: "a", slot: 0, by: 0.25) }
        XCTAssertGreaterThanOrEqual(group.members[0].weight, MagnetGroup.minimumWeight)
    }

    func testLegacyConfigurationRecordsWithoutGroupsStillDecode() throws {
        // The store is fail-soft: a decode failure returns an EMPTY store and the
        // next save overwrites the user's real data. A new non-optional field is
        // therefore a data-loss bug (BACKLOG finding 11). This is the guard.
        let legacy = """
        {"apps":{"com.apple.TextEdit":[{"slot":0,"frame":{"x":0,"y":0,"w":0.5,"h":0.5},"lastSeen":0}]}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConfigurationRecords.self, from: legacy)
        XCTAssertEqual(decoded.apps.count, 1, "legacy payload must survive intact")
        XCTAssertTrue(decoded.groups.isEmpty)
    }

    func testConfigurationRecordsRoundTripWithGroups() throws {
        var records = ConfigurationRecords()
        records.groups = [MagnetGroup(members: [member("a", 0, weight: 2), member("b", 1)],
                                      resizeMode: .nudge)]
        let data = try JSONEncoder().encode(records)
        let back = try JSONDecoder().decode(ConfigurationRecords.self, from: data)
        XCTAssertEqual(back, records)
    }
}
```

- [ ] **Step 2: Run the tests, watch them fail** (`swift test` — expect "cannot find type 'MagnetGroup' in scope")

- [ ] **Step 3: Implement** `Sources/MacTLMCore/MagnetGroup.swift`

```swift
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
```

- [ ] **Step 4: Extend `ConfigurationRecords`** in `Sources/MacTLMCore/WindowRecord.swift`

Replace the struct's body so it carries groups and decodes legacy payloads. Keep `apps` first so existing call sites are untouched.

```swift
/// Everything remembered for one display configuration: bundleID → window
/// slots, plus the magnet groups the user built on that arrangement.
public struct ConfigurationRecords: Codable, Equatable {
    public var apps: [String: [WindowRecord]]
    public var groups: [MagnetGroup]

    public init(apps: [String: [WindowRecord]] = [:], groups: [MagnetGroup] = []) {
        self.apps = apps
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case apps, groups }

    /// Absent-tolerant on purpose: the store is fail-soft, so a decode error
    /// yields an empty store and the next save destroys the user's real data.
    /// Every field added here must decode from a payload written before it
    /// existed (BACKLOG finding 11).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent([String: [WindowRecord]].self, forKey: .apps) ?? [:]
        groups = try container.decodeIfPresent([MagnetGroup].self, forKey: .groups) ?? []
    }
}
```

- [ ] **Step 5: Run the tests, watch them pass** (expect 165 tests)
- [ ] **Step 6: Commit** — `feat: magnet group model persisted per display configuration`

---

## Task 2: Mating geometry

**Files:** create `Sources/MacTLMCore/MagnetMating.swift`, `Tests/MacTLMCoreTests/MagnetMatingTests.swift`.

Pure function: given the frame a user just dropped and the frames around it, decide whether it mates and where it should land. All frames are AX/CG space — origin top-left, y grows downward.

- [ ] **Step 1: Write the tests first** (8 tests)

```swift
import XCTest
@testable import MacTLMCore

final class MagnetMatingTests: XCTestCase {
    private let mate = CGRect(x: 1000, y: 100, width: 600, height: 800)

    func testDroppingJustLeftOfAWindowMatesItsRightEdge() {
        // dragged.maxX = 990, mate.minX = 1000 → 10pt apart, inside threshold
        let dragged = CGRect(x: 490, y: 100, width: 500, height: 800)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)], gap: 8)
        XCTAssertEqual(candidate?.mateID, 1)
        XCTAssertEqual(candidate?.edge, .right)
        XCTAssertEqual(candidate?.snapped.maxX ?? 0, mate.minX - 8, accuracy: 0.001,
                       "the dragged window must sit flush minus the gap")
        XCTAssertEqual(candidate?.snapped.width ?? 0, dragged.width, accuracy: 0.001,
                       "mating moves a window, it does not resize it")
    }

    func testDroppingFarAwayDoesNotMate() {
        let dragged = CGRect(x: 100, y: 100, width: 500, height: 800)
        XCTAssertNil(MagnetMating.candidate(dragged: dragged, others: [(1, mate)]))
    }

    func testEdgesThatBarelyOverlapDoNotMate() {
        // Vertically adjacent by only 20pt of an 800pt-tall mate.
        let dragged = CGRect(x: 490, y: 880, width: 500, height: 800)
        XCTAssertNil(MagnetMating.candidate(dragged: dragged, others: [(1, mate)]),
                     "a corner graze is not a mate")
    }

    func testMatingAlsoAlignsTheNearPerpendicularEdge() {
        // Tops 12pt out of true → snap them level.
        let dragged = CGRect(x: 490, y: 112, width: 500, height: 800)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)])
        XCTAssertEqual(candidate?.snapped.minY ?? -1, mate.minY, accuracy: 0.001)
    }

    func testMatingLeavesAFarPerpendicularEdgeAlone() {
        let dragged = CGRect(x: 490, y: 400, width: 500, height: 300)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)])
        XCTAssertEqual(candidate?.snapped.minY ?? -1, 400, accuracy: 0.001,
                       "deliberate offsets must survive; only near-misses get straightened")
    }

    func testVerticalMatingSnapsBelow() {
        let dragged = CGRect(x: 1000, y: 915, width: 600, height: 400)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)], gap: 8)
        XCTAssertEqual(candidate?.edge, .top, "the dragged window's TOP edge is what mates")
        XCTAssertEqual(candidate?.snapped.minY ?? 0, mate.maxY + 8, accuracy: 0.001)
    }

    func testNearestCandidateWins() {
        let near = CGRect(x: 1000, y: 100, width: 300, height: 800)
        let far = CGRect(x: 1018, y: 100, width: 300, height: 800)
        let dragged = CGRect(x: 490, y: 100, width: 500, height: 800)
        let candidate = MagnetMating.candidate(dragged: dragged,
                                              others: [(2, far), (1, near)])
        XCTAssertEqual(candidate?.mateID, 1)
    }

    func testSnappingIsIdempotent() {
        let dragged = CGRect(x: 490, y: 100, width: 500, height: 800)
        guard let first = MagnetMating.candidate(dragged: dragged, others: [(1, mate)]) else {
            return XCTFail("expected a mate")
        }
        let second = MagnetMating.candidate(dragged: first.snapped, others: [(1, mate)])
        XCTAssertEqual(second?.snapped ?? .zero, first.snapped,
                       "re-mating an already-mated window must not drift it")
    }
}
```

- [ ] **Step 2: Run the tests, watch them fail**

- [ ] **Step 3: Implement** `Sources/MacTLMCore/MagnetMating.swift`

```swift
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Decides whether a just-dropped window mates with a neighbour, and where it
/// should land. Pure geometry in AX/CG space (origin top-left, y downward).
public enum MagnetMating {
    /// Which edge OF THE DRAGGED WINDOW meets the mate.
    public enum Edge: String, Codable, Equatable {
        case left, right, top, bottom

        var isHorizontal: Bool { self == .left || self == .right }
    }

    public struct Candidate: Equatable {
        public let mateID: Int
        public let edge: Edge
        public let snapped: CGRect
        public let distance: CGFloat
    }

    /// How near facing edges must be, in points, before they mate.
    public static let defaultThreshold: CGFloat = 24
    /// How much the perpendicular extents must overlap, as a fraction of the
    /// shorter side. Stops a corner graze from counting as a mate.
    public static let defaultMinimumOverlap: Double = 0.25

    public static func candidate(dragged: CGRect,
                                 others: [(id: Int, frame: CGRect)],
                                 threshold: CGFloat = defaultThreshold,
                                 minimumOverlap: Double = defaultMinimumOverlap,
                                 gap: CGFloat = 8) -> Candidate? {
        var best: Candidate?
        for other in others {
            for edge in [Edge.right, .left, .bottom, .top] {
                let distance = facingDistance(dragged, other.frame, edge: edge)
                guard distance <= threshold,
                      overlapFraction(dragged, other.frame, edge: edge) >= minimumOverlap
                else { continue }
                let snapped = snap(dragged, to: other.frame, edge: edge,
                                   gap: gap, threshold: threshold)
                if best == nil || distance < best!.distance {
                    best = Candidate(mateID: other.id, edge: edge,
                                     snapped: snapped, distance: distance)
                }
            }
        }
        return best
    }

    /// Gap between the dragged window's `edge` and the mate's facing edge.
    private static func facingDistance(_ dragged: CGRect, _ other: CGRect,
                                       edge: Edge) -> CGFloat {
        switch edge {
        case .right: return abs(other.minX - dragged.maxX)
        case .left: return abs(dragged.minX - other.maxX)
        case .bottom: return abs(other.minY - dragged.maxY)
        case .top: return abs(dragged.minY - other.maxY)
        }
    }

    /// Shared extent along the axis perpendicular to the mating edge, as a
    /// fraction of the shorter of the two sides.
    private static func overlapFraction(_ a: CGRect, _ b: CGRect, edge: Edge) -> Double {
        if edge.isHorizontal {
            let shared = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            let shorter = min(a.height, b.height)
            guard shorter > 0 else { return 0 }
            return Double(max(0, shared) / shorter)
        }
        let shared = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let shorter = min(a.width, b.width)
        guard shorter > 0 else { return 0 }
        return Double(max(0, shared) / shorter)
    }

    /// Flush against the mate, plus perpendicular alignment when the user was
    /// already close to level. Deliberate offsets are preserved.
    private static func snap(_ dragged: CGRect, to other: CGRect, edge: Edge,
                             gap: CGFloat, threshold: CGFloat) -> CGRect {
        var origin = dragged.origin
        switch edge {
        case .right: origin.x = other.minX - gap - dragged.width
        case .left: origin.x = other.maxX + gap
        case .bottom: origin.y = other.minY - gap - dragged.height
        case .top: origin.y = other.maxY + gap
        }
        if edge.isHorizontal {
            if abs(dragged.minY - other.minY) <= threshold {
                origin.y = other.minY
            } else if abs(dragged.maxY - other.maxY) <= threshold {
                origin.y = other.maxY - dragged.height
            }
        } else {
            if abs(dragged.minX - other.minX) <= threshold {
                origin.x = other.minX
            } else if abs(dragged.maxX - other.maxX) <= threshold {
                origin.x = other.maxX - dragged.width
            }
        }
        return CGRect(origin: origin, size: dragged.size)
    }
}
```

- [ ] **Step 4: Run the tests, watch them pass** (expect 173 tests)
- [ ] **Step 5: Commit** — `feat: mating geometry for drag-to-magnetize`

---

## Task 3: Shared-edge resize propagation

**Files:** create `Sources/MacTLMCore/MagnetResize.swift`, `Tests/MacTLMCoreTests/MagnetResizeTests.swift`.

The user drags one window's edge; mates sharing that edge follow. `shrink` resizes the mate, `nudge` translates it and cascades to *its* mates.

- [ ] **Step 1: Write the tests first** (8 tests)

```swift
import XCTest
@testable import MacTLMCore

final class MagnetResizeTests: XCTestCase {
    // Two windows mated left|right with an 8pt gap.
    private let left = CGRect(x: 0, y: 0, width: 992, height: 1000)
    private let right = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
    private let floor = CGSize(width: 200, height: 200)

    func testShrinkMovesTheMatesFacingEdgeOnly() {
        let widened = CGRect(x: 0, y: 0, width: 1192, height: 1000) // +200 right edge
        let result = MagnetResize.propagate(frames: [1: widened, 2: right],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        let mate = result[2]
        XCTAssertNotNil(mate)
        XCTAssertEqual(mate!.minX, widened.maxX + 8, accuracy: 0.001, "shared edge stays shared")
        XCTAssertEqual(mate!.maxX, right.maxX, accuracy: 0.001, "far edge is anchored")
        XCTAssertEqual(mate!.width, right.width - 200, accuracy: 0.001)
    }

    func testNudgeTranslatesTheMateKeepingItsSize() {
        let widened = CGRect(x: 0, y: 0, width: 1192, height: 1000)
        let result = MagnetResize.propagate(frames: [1: widened, 2: right],
                                           changed: 1, previous: left,
                                           mode: .nudge, gap: 8, minimumSize: floor)
        let mate = result[2]!
        XCTAssertEqual(mate.width, right.width, accuracy: 0.001)
        XCTAssertEqual(mate.minX, right.minX + 200, accuracy: 0.001)
    }

    func testShrinkStopsAtTheMinimumSize() {
        let hugely = CGRect(x: 0, y: 0, width: 1900, height: 1000)
        let result = MagnetResize.propagate(frames: [1: hugely, 2: right],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        XCTAssertGreaterThanOrEqual(result[2]!.width, floor.width - 0.001,
                                    "a mate must never be crushed below usability")
    }

    func testWindowsThatShareNoEdgeAreUntouched() {
        let stranger = CGRect(x: 3000, y: 0, width: 500, height: 500)
        let widened = CGRect(x: 0, y: 0, width: 1192, height: 1000)
        let result = MagnetResize.propagate(frames: [1: widened, 2: stranger],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        XCTAssertNil(result[2])
    }

    func testNudgeCascadesThroughAChainOfMates() {
        let middle = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        let far = CGRect(x: 1508, y: 0, width: 500, height: 1000)
        let widened = CGRect(x: 0, y: 0, width: 1092, height: 1000) // +100
        let result = MagnetResize.propagate(frames: [1: widened, 2: middle, 3: far],
                                           changed: 1, previous: left,
                                           mode: .nudge, gap: 8, minimumSize: floor)
        XCTAssertEqual(result[2]!.minX, middle.minX + 100, accuracy: 0.001)
        XCTAssertEqual(result[3]!.minX, far.minX + 100, accuracy: 0.001,
                       "a nudge travels down the chain")
    }

    func testShrinkDoesNotCascade() {
        let middle = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        let far = CGRect(x: 1508, y: 0, width: 500, height: 1000)
        let widened = CGRect(x: 0, y: 0, width: 1092, height: 1000)
        let result = MagnetResize.propagate(frames: [1: widened, 2: middle, 3: far],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        XCTAssertNil(result[3], "shrink absorbs the delta in the immediate mate")
    }

    func testMovingAWindowWithoutResizingItPropagatesNothing() {
        let slid = left.offsetBy(dx: 5, dy: 0) // same size, both edges moved equally
        let result = MagnetResize.propagate(frames: [1: slid, 2: right],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        XCTAssertTrue(result.isEmpty,
                      "a plain move is a mating gesture, not a resize gesture")
    }

    func testPropagationTerminatesOnACycle() {
        // Three windows each adjacent to the next, last adjacent back to the first.
        let a = CGRect(x: 0, y: 0, width: 492, height: 500)
        let b = CGRect(x: 500, y: 0, width: 492, height: 500)
        let c = CGRect(x: 0, y: 508, width: 492, height: 492)
        let grown = CGRect(x: 0, y: 0, width: 592, height: 500)
        let result = MagnetResize.propagate(frames: [1: grown, 2: b, 3: c],
                                           changed: 1, previous: a,
                                           mode: .nudge, gap: 8, minimumSize: floor)
        XCTAssertFalse(result.isEmpty)
        XCTAssertLessThanOrEqual(result.count, 2)
    }
}
```

- [ ] **Step 2: Run the tests, watch them fail**

- [ ] **Step 3: Implement** `Sources/MacTLMCore/MagnetResize.swift`

```swift
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Propagates a shared-edge drag to the mates that share that edge.
public enum MagnetResize {
    public typealias Mode = MagnetGroup.ResizeMode

    /// Ignore sub-pixel jitter; AX frames are not exact.
    private static let epsilon: CGFloat = 0.5

    /// Returns new frames for the members that must move. `changed` is never
    /// in the result — the user already put it where they want it.
    public static func propagate(frames: [Int: CGRect],
                                 changed: Int,
                                 previous: CGRect,
                                 mode: Mode,
                                 gap: CGFloat = 8,
                                 minimumSize: CGSize = CGSize(width: 240, height: 160),
                                 adjacencyTolerance: CGFloat = 12) -> [Int: CGRect] {
        guard let now = frames[changed] else { return [:] }
        // A pure translation is a mating gesture; only edge motion propagates.
        let sizeChanged = abs(now.width - previous.width) > epsilon
            || abs(now.height - previous.height) > epsilon
        guard sizeChanged else { return [:] }

        var result: [Int: CGRect] = [:]
        var live = frames
        var visited: Set<Int> = [changed]
        var queue: [(id: Int, previous: CGRect, now: CGRect)] = [(changed, previous, now)]

        while let step = queue.first {
            queue.removeFirst()
            for edge in Edge.allCases {
                let delta = edge.delta(from: step.previous, to: step.now)
                guard abs(delta) > epsilon else { continue }
                for (id, frame) in live where !visited.contains(id) {
                    guard edge.isAdjacent(step.previous, frame, gap: gap,
                                          tolerance: adjacencyTolerance) else { continue }
                    let updated: CGRect
                    switch mode {
                    case .shrink:
                        updated = edge.resizingMate(frame, toFollow: step.now,
                                                    gap: gap, minimumSize: minimumSize)
                    case .nudge:
                        updated = edge.translatingMate(frame, by: delta)
                    }
                    visited.insert(id)
                    result[id] = updated
                    live[id] = updated
                    if mode == .nudge {
                        // A nudged window pushes its own mates.
                        queue.append((id, frame, updated))
                    }
                }
            }
        }
        return result
    }

    /// Which edge of the CHANGED window moved, described from its point of view.
    private enum Edge: CaseIterable {
        case leading, trailing, top, bottom

        var isHorizontal: Bool { self == .leading || self == .trailing }

        func delta(from previous: CGRect, to now: CGRect) -> CGFloat {
            switch self {
            case .leading: return now.minX - previous.minX
            case .trailing: return now.maxX - previous.maxX
            case .top: return now.minY - previous.minY
            case .bottom: return now.maxY - previous.maxY
            }
        }

        /// Is `mate` flush against this edge of `subject`?
        func isAdjacent(_ subject: CGRect, _ mate: CGRect,
                        gap: CGFloat, tolerance: CGFloat) -> Bool {
            let facing: CGFloat
            switch self {
            case .trailing: facing = abs(mate.minX - subject.maxX - gap)
            case .leading: facing = abs(subject.minX - mate.maxX - gap)
            case .bottom: facing = abs(mate.minY - subject.maxY - gap)
            case .top: facing = abs(subject.minY - mate.maxY - gap)
            }
            guard facing <= tolerance else { return false }
            if isHorizontal {
                return min(subject.maxY, mate.maxY) - max(subject.minY, mate.minY) > 0
            }
            return min(subject.maxX, mate.maxX) - max(subject.minX, mate.minX) > 0
        }

        /// Mate keeps its far edge and follows the shared one.
        func resizingMate(_ mate: CGRect, toFollow subject: CGRect,
                          gap: CGFloat, minimumSize: CGSize) -> CGRect {
            switch self {
            case .trailing:
                let x = subject.maxX + gap
                return CGRect(x: x, y: mate.minY,
                              width: max(minimumSize.width, mate.maxX - x),
                              height: mate.height)
            case .leading:
                let maxX = subject.minX - gap
                let width = max(minimumSize.width, maxX - mate.minX)
                return CGRect(x: maxX - width, y: mate.minY,
                              width: width, height: mate.height)
            case .bottom:
                let y = subject.maxY + gap
                return CGRect(x: mate.minX, y: y, width: mate.width,
                              height: max(minimumSize.height, mate.maxY - y))
            case .top:
                let maxY = subject.minY - gap
                let height = max(minimumSize.height, maxY - mate.minY)
                return CGRect(x: mate.minX, y: maxY - height,
                              width: mate.width, height: height)
            }
        }

        func translatingMate(_ mate: CGRect, by delta: CGFloat) -> CGRect {
            isHorizontal ? mate.offsetBy(dx: delta, dy: 0)
                         : mate.offsetBy(dx: 0, dy: delta)
        }
    }
}
```

- [ ] **Step 4: Run the tests, watch them pass** (expect 181 tests)
- [ ] **Step 5: Commit** — `feat: shared-edge resize propagation with shrink and nudge modes`

---

## Task 4: Group-weighted reflow planning

**Files:** create `Sources/MacTLMCore/GroupReflowPlanner.swift`, `Tests/MacTLMCoreTests/GroupReflowPlannerTests.swift`.

Turns a group plus its live windows into solver input: bounds are the group's bounding box (so a group in the left half reflows inside that half, not across the display), and weights come from the members' manual ranks.

- [ ] **Step 1: Write the tests first** (5 tests)

```swift
import XCTest
@testable import MacTLMCore

final class GroupReflowPlannerTests: XCTestCase {
    private func window(_ id: Int, _ bundle: String, _ slot: Int, _ frame: CGRect)
        -> GroupReflowPlanner.LiveWindow {
        GroupReflowPlanner.LiveWindow(id: id, bundleID: bundle, slot: slot, frame: frame)
    }

    func testBoundsAreTheGroupsBoundingBox() {
        let group = MagnetGroup(members: [MagnetMember(bundleID: "a", slot: 0),
                                          MagnetMember(bundleID: "b", slot: 0)])
        let plan = GroupReflowPlanner.plan(
            group: group,
            live: [window(1, "a", 0, CGRect(x: 0, y: 0, width: 500, height: 400)),
                   window(2, "b", 0, CGRect(x: 508, y: 0, width: 500, height: 400))],
            preset: .columns, gap: 8, minimumSize: .zero)
        XCTAssertEqual(plan?.bounds, CGRect(x: 0, y: 0, width: 1008, height: 400))
    }

    func testWeightsComeFromMemberRanks() {
        let group = MagnetGroup(members: [MagnetMember(bundleID: "a", slot: 0, weight: 3),
                                          MagnetMember(bundleID: "b", slot: 0, weight: 1)])
        let plan = GroupReflowPlanner.plan(
            group: group,
            live: [window(1, "a", 0, CGRect(x: 0, y: 0, width: 400, height: 400)),
                   window(2, "b", 0, CGRect(x: 408, y: 0, width: 400, height: 400))],
            preset: .symmetric, gap: 0, minimumSize: .zero)
        let frames = plan!.frames
        XCTAssertGreaterThan(frames[1]!.width, frames[2]!.width * 2,
                             "a weight-3 member must get roughly three times the area")
    }

    func testMembersWithNoLiveWindowAreSkipped() {
        let group = MagnetGroup(members: [MagnetMember(bundleID: "a", slot: 0),
                                          MagnetMember(bundleID: "gone", slot: 0),
                                          MagnetMember(bundleID: "b", slot: 0)])
        let plan = GroupReflowPlanner.plan(
            group: group,
            live: [window(1, "a", 0, CGRect(x: 0, y: 0, width: 400, height: 400)),
                   window(2, "b", 0, CGRect(x: 408, y: 0, width: 400, height: 400))],
            preset: .columns, gap: 8, minimumSize: .zero)
        XCTAssertEqual(plan?.frames.count, 2)
    }

    func testAGroupWithOneLiveWindowHasNothingToReflow() {
        let group = MagnetGroup(members: [MagnetMember(bundleID: "a", slot: 0),
                                          MagnetMember(bundleID: "b", slot: 0)])
        let plan = GroupReflowPlanner.plan(
            group: group,
            live: [window(1, "a", 0, CGRect(x: 0, y: 0, width: 400, height: 400))],
            preset: .columns, gap: 8, minimumSize: .zero)
        XCTAssertNil(plan)
    }

    func testFramesStayInsideTheBoundingBox() {
        let group = MagnetGroup(members: (0..<4).map {
            MagnetMember(bundleID: "a", slot: $0, weight: Double($0 + 1))
        })
        let live = (0..<4).map {
            window($0 + 1, "a", $0,
                   CGRect(x: CGFloat($0) * 400, y: 0, width: 392, height: 800))
        }
        let plan = GroupReflowPlanner.plan(group: group, live: live,
                                           preset: .treemap(bias: .center),
                                           gap: 8, minimumSize: .zero)!
        for frame in plan.frames.values {
            XCTAssertTrue(plan.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "\(frame) escaped \(plan.bounds)")
        }
    }
}
```

- [ ] **Step 2: Run the tests, watch them fail**

- [ ] **Step 3: Implement** `Sources/MacTLMCore/GroupReflowPlanner.swift`

```swift
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
```

- [ ] **Step 4: Run the tests, watch them pass** (expect 186 tests)
- [ ] **Step 5: Commit** — `feat: plan group reflows inside the group's own bounds`

---

## Task 5: Window-level AX events

**File:** modify `Sources/MacTLM/AppObserver.swift`, and its construction site in `Sources/MacTLM/WorkspaceMonitor.swift` (find it with `grep -rn "AppObserver(" Sources/MacTLM`).

Today the callback collapses every notification into `onActivity(bundleID)`. Persistence depends on that coarse signal and **must keep working unchanged**; mating needs to know *which* window and *which* event.

- [ ] **Step 1** Add a public event type and a second, optional callback. Do not change `onActivity`'s meaning or its call sites.

```swift
/// A window-level AX event, for features that need more than "something changed".
struct WindowEvent {
    enum Kind { case created, moved, resized, titleChanged }
    let kind: Kind
    let bundleID: String
    let pid: pid_t
    /// Stable id of the window element, matching `DriverWindow.id`.
    let windowID: Int
    let frame: CGRect
}
```

- [ ] **Step 2** In the `AXObserverCallback`, the second parameter is the `AXUIElement` that changed. Wrap it in `AXWindowHandle` (already exists) to read `stableID` and `frame`, map the notification name to a `Kind`, and call `onWindowEvent?(event)` in addition to the existing `onActivity(bundleID)`.
  - The element for `kAXWindowCreatedNotification` is the new window; for moved/resized it is the window. If `AXWindowHandle` cannot produce a frame, skip the rich event but still fire `onActivity`.
- [ ] **Step 3** `init` gains `onWindowEvent: ((WindowEvent) -> Void)? = nil` so the existing construction site compiles untouched; pass the real handler from `WorkspaceMonitor`.
- [ ] **Step 4** Verify: `swift build` clean, `swift test` 186 (Core untouched), `./scripts/make-app.sh` green. Do not launch.
- [ ] **Step 5: Commit** — `feat: forward window-level AX events alongside the coarse activity signal`

---

## Task 6: Drag sessions and mating

**Files:** create `Sources/MacTLM/MagnetDragSession.swift`; modify `Sources/MacTLM/PersistenceCoordinator.swift`.

macOS has **no drag-ended AX notification**. Debouncing moved events would fire mid-drag and snap the window out from under the cursor, so the drag ends on a real mouse-up.

- [ ] **Step 1** `MagnetDragSession` holds: the window currently moving (`WindowEvent`'s id/bundleID plus its frame at drag start), a `NSEvent` global monitor for `.leftMouseUp`, and a suppression set.
- [ ] **Step 2** On a `.moved` event for an eligible window (app not excluded, not MacTLM, standard window):
  - if no session is open, open one and install the global monitor via `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp])` — we already hold Accessibility, which is what this requires;
  - compute `MagnetMating.candidate` against the other eligible windows on the same display and hand it to the overlay (Task 7);
  - ignore the event entirely if it is self-inflicted (see Step 4).
- [ ] **Step 3** On mouse-up: remove the monitor, hide the overlay, and if a candidate exists:
  - `driver.setFrame(candidate.snapped, of: window)` with the read-back-and-one-retry policy `RestoreEngine` uses;
  - resolve both windows to `(bundleID, slot)` through the tracker's matcher and either extend the mate's existing group or create a new one, then persist through the coordinator (**never** write the store file directly — the tracker's next debounced save would clobber it, BACKLOG finding 15).
- [ ] **Step 4 — self-inflicted suppression.** Every frame we write is recorded as `(windowID, frame, deadline: now + 0.4s)`. An incoming event whose window and frame match a live entry is dropped. Without this, our own `setFrame` re-enters mating and the window walks across the screen.
- [ ] **Step 5** `PersistenceCoordinator` gains `magnetGroups(forCurrentConfiguration:)`, `mate(_:with:)` and `ungroup(_:)` that mutate `ConfigurationRecords.groups` through the tracker and trigger a save.
- [ ] **Step 6** Verify: build clean, 186 tests, make-app green, app not launched.
- [ ] **Step 7: Commit** — `feat: mate windows on drop with mouse-up-terminated drag sessions`

---

## Task 7: Snap preview overlay

**File:** create `Sources/MacTLM/MagnetSnapOverlay.swift`.

Without a preview, mating feels like windows randomly jumping. PRD §5 asks for "a subtle highlight when edges mate".

- [ ] **Step 1** A borderless, non-activating `NSPanel`: `isOpaque = false`, `backgroundColor = .clear`, `ignoresMouseEvents = true`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary]`, `hidesOnDeactivate = false`.
- [ ] **Step 2** `show(edge:of:)` draws a 4pt rounded bar in `NSColor.controlAccentColor` along the mating edge of the *target* frame, converted from AX/CG space to Cocoa screen space (`ScreenGeometry` already owns that flip — reuse it, do not re-derive it).
- [ ] **Step 3** `hide()` orders it out. The session hides it on mouse-up, on losing the candidate, and on any error path — a stuck overlay is worse than no overlay.
- [ ] **Step 4** Verify: build clean, 186 tests, make-app green.
- [ ] **Step 5: Commit** — `feat: accent-line preview of the edge a drag will mate to`

---

## Task 8: Resize propagation wiring

**File:** modify `Sources/MacTLM/MagnetDragSession.swift` (or a sibling `MagnetResizeWatcher.swift` if cleaner).

- [ ] **Step 1** On a `.resized` event for a window belonging to a group, look up that group's live windows, call `MagnetResize.propagate` with the group's `resizeMode`, and apply the results back-to-front with the standard clamp policy.
- [ ] **Step 2** Feed `previous` from a per-window last-known frame cache, updated on every observed event and on every frame we write.
- [ ] **Step 3** All writes go through the same suppression set as Task 6. Resize propagation without suppression is an infinite loop, not a bug you can debounce away.
- [ ] **Step 4** Verify: build clean, 186 tests, make-app green.
- [ ] **Step 5: Commit** — `feat: apply shared-edge resize to a group's mates`

---

## Task 9: Group-aware reflow and the menu surface

**Files:** modify `Sources/MacTLM/DisplayGroupReflow.swift`, `Sources/MacTLM/StatusMenuController.swift`.

- [ ] **Step 1** `DisplayGroupReflow.apply` first asks: does the frontmost window belong to a group with two or more live members? If so, reflow via `GroupReflowPlanner`; otherwise keep today's whole-display behavior. The glyph row keeps working exactly as it does now when no group exists.
- [ ] **Step 2** Retitle the section header dynamically: "Reflow this group" when a group is active, "Reflow this display" otherwise.
- [ ] **Step 3** Add a `Groups` section below the reflow row: one row per group in the current configuration, titled from its members' localized app names (reuse `AppRecordSummary.localizedAppName`), with a submenu:
  - `Resize mode` → Shrink / Nudge (checkmark on the active one);
  - `Grow frontmost` (×1.25) and `Shrink frontmost` (×0.8), each re-running the last preset so the weight change is visible immediately;
  - `Ungroup`.
- [ ] **Step 4** Remember the last preset per group in memory (not persisted — a preset is a gesture, not a setting).
- [ ] **Step 5** Verify: build clean, 186 tests, make-app green, app not launched.
- [ ] **Step 6: Commit** — `feat: group-aware reflow with a Groups menu section`

---

## Task 10: Live acceptance and tag

Human-driven; do not attempt from an agent.

- [ ] **Step 1** `./scripts/install.sh`, confirm the daemon is running and the login item stayed enabled.
- [ ] **Step 2 — mating.** Drag an Arc window until its edge nears the other Arc: the accent line appears; release; it snaps flush with an 8pt gap. The menu's Groups section lists the pair.
- [ ] **Step 3 — persistence.** Quit and relaunch MacTLM; the group is still listed.
- [ ] **Step 4 — shrink.** With mode Shrink, drag the shared edge: the mate's far edge stays put and it resizes. Nothing oscillates (suppression works).
- [ ] **Step 5 — nudge.** Switch to Nudge, repeat: the mate keeps its size and slides; a third mated window slides too.
- [ ] **Step 6 — weights.** `Grow frontmost` three times, then apply the treemap: the promoted window is visibly largest, and the ranking survives switching presets.
- [ ] **Step 7 — ungroup.** Ungroup, confirm the row disappears and the glyph row reverts to whole-display reflow.
- [ ] **Step 8** Update `docs/BACKLOG.md`: shipped row for `v0.7.0-m3b`, test count, PRD Phase 3 acceptance result, and any platform finding this milestone paid for. Tag `v0.7.0-m3b`.

---

## Plan self-review notes

- **Spec coverage:** PRD §3.2 Phase 3 wants magnet groups (T1, T6), shared-edge resize with shrink/nudge (T3, T8), manual weights feeding the treemap (T1, T4, T9), and snap-during-drag with a highlight (T6, T7). §4's `MagnetGroup` data model — member refs, adjacency, resize mode, active preset, per-member weights — is T1 plus T9's in-memory preset.
- **Deliberate omission:** adjacency is recomputed from live geometry rather than stored on the group. Storing edges would duplicate truth that windows already carry and would go stale the moment anything moved outside our observation. The cost is that a group whose windows drifted far apart resizes as separate windows until re-mated; that is the honest behavior.
- **Deliberate omission:** no unit tests for the drag session, overlay, or event plumbing — no headless surface exists for a global mouse monitor. Covered by T10's live protocol, consistent with every AppKit layer since M1.
- **Risk — event storms.** Moved events fire continuously during a drag, and each one runs a mating query over the display's windows. The query is O(windows) with no AX calls beyond the enumeration the driver already caches, but if it proves heavy in T10, throttle the *preview* to ~30fps while leaving mouse-up resolution exact.
- **Risk — suppression is load-bearing twice** (T6 and T8). If mating or resize ever oscillates in live testing, suspect a suppression miss (frame tolerance too tight, or deadline too short) before suspecting the geometry, which is property-tested.
- **Known gap carried forward:** weights are per-group and per-`(bundleID, slot)`, so a group spanning two displays is possible but untested — the two-displays-one-app residual in `docs/BACKLOG.md` applies here too.
