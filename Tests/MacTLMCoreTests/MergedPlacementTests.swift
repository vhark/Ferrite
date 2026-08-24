import XCTest
@testable import MacTLMCore

/// Contract tests for M2e merged per-app placement: one assignment per app per
/// bundle launch, absolute target rects, display-aware order fallback.
final class MergedPlacementTests: XCTestCase {
    // Two displays side by side: A owns x 0-2000, B owns x 2000-4000.
    let areaA = CGRect(x: 0, y: 25, width: 2000, height: 975)
    let areaB = CGRect(x: 2000, y: 25, width: 2000, height: 975)

    private func target(_ id: String, area: CGRect) -> TemplateApplyPlanner.Target {
        TemplateApplyPlanner.Target(
            info: DisplayInfo(id: id, width: 2000, height: 1000, scale: 2.0),
            visibleArea: area)
    }

    private func layout(_ display: String, entries: [LayoutEntry]) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: "bundle", displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 2000,
                                                  height: 1000, scale: 2.0),
                      stageMode: .leaveOthers, entries: entries,
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    private func entry(_ bundleID: String, frame: NormalizedFrame, z: Int = 0,
                       titleHash: String? = nil) -> LayoutEntry {
        LayoutEntry(bundleID: bundleID, titleHash: titleHash, frame: frame,
                    zIndex: z, pinPattern: nil, optional: false)
    }

    /// One "arc" entry on each display, distinct normalized frames.
    private func twoDisplayArcPlan(
        hashA: String? = nil, hashB: String? = nil
    ) -> MultiApplyPlanner.MultiPlan {
        let frameA = NormalizedFrame(x: 0.1, y: 0.1, w: 0.5, h: 0.8)
        let frameB = NormalizedFrame(x: 0.25, y: 0.05, w: 0.4, h: 0.7)
        return MultiApplyPlanner.plan(
            requests: [
                (layout("A", entries: [entry("arc", frame: frameA, titleHash: hashA)]),
                 target("A", area: areaA)),
                (layout("B", entries: [entry("arc", frame: frameB, titleHash: hashB)]),
                 target("B", area: areaB)),
            ],
            runningBundleIDs: ["arc"], excludedBundleIDs: [])
    }

    private var displays: [(id: String, area: CGRect)] {
        [("A", areaA), ("B", areaB)]
    }

    // MARK: - 1. Merged placements

    func testMergedPlacementsCarryAbsoluteRectsAndUniqueSlots() {
        let multi = twoDisplayArcPlan()
        let merged = multi.placements["arc"] ?? []
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.slot)).count, 2, "slots globally unique")

        let onA = merged.first { $0.displayID == "A" }
        let onB = merged.first { $0.displayID == "B" }
        XCTAssertNotNil(onA)
        XCTAssertNotNil(onB)
        // Absolute rects: each is the denormalization against its OWN display.
        XCTAssertEqual(onA?.targetRect,
                       NormalizedFrame(x: 0.1, y: 0.1, w: 0.5, h: 0.8).rect(in: areaA))
        XCTAssertEqual(onB?.targetRect,
                       NormalizedFrame(x: 0.25, y: 0.05, w: 0.4, h: 0.7).rect(in: areaB))
        XCTAssertTrue(areaA.contains(onA!.targetRect))
        XCTAssertTrue(areaB.contains(onB!.targetRect))
    }

    // MARK: - 2. The residual itself

    func testCrossDisplayClaimRegression() {
        // Uncertain identity: no title hashes anywhere, order fallback decides.
        let multi = twoDisplayArcPlan()
        let merged = multi.placements["arc"]!
        // Live windows: one centered on each display. B's window enumerates
        // first (frontmost) — the exact shape where a global order zip hands
        // B's window to A's record.
        let windowOnB = DriverWindow(id: 20, title: "",
                                     frame: CGRect(x: 2500, y: 200, width: 800, height: 600))
        let windowOnA = DriverWindow(id: 10, title: "",
                                     frame: CGRect(x: 500, y: 200, width: 800, height: 600))
        let windows = [windowOnB, windowOnA]
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title,
                            titleHash: window.titleHash, order: index)
        }
        let affinity = WindowMatcher.Affinity(
            recordDisplays: merged.recordDisplays,
            windowDisplays: WindowMatcher.Affinity.windowDisplays(of: windows,
                                                                  displays: displays))
        let assignment = WindowMatcher.assign(records: merged.matchingRecords,
                                              to: candidates,
                                              allowOrderFallback: true,
                                              affinity: affinity)
        let bySlot = Dictionary(uniqueKeysWithValues: merged.map { ($0.slot, $0) })
        let targetForA = bySlot[assignment[10]!.slot]!
        let targetForB = bySlot[assignment[20]!.slot]!
        XCTAssertEqual(targetForA.displayID, "A", "A's window keeps A's record")
        XCTAssertEqual(targetForB.displayID, "B", "B's window keeps B's record")
        XCTAssertTrue(areaA.contains(targetForA.targetRect),
                      "A's window lands on its own display")
        XCTAssertTrue(areaB.contains(targetForB.targetRect),
                      "B's window lands on its own display")
    }

    // MARK: - 3. Identity outranks geometry

    func testAffinityOnlyAffectsOrderFallback() {
        // The A record carries a hash matching the window currently ON B.
        let multi = twoDisplayArcPlan(hashA: testHash("Work"), hashB: nil)
        let merged = multi.placements["arc"]!
        let windowOnB = DriverWindow(id: 20, title: "Work",
                                     frame: CGRect(x: 2500, y: 200, width: 800, height: 600))
        let windowOnA = DriverWindow(id: 10, title: "",
                                     frame: CGRect(x: 500, y: 200, width: 800, height: 600))
        let windows = [windowOnB, windowOnA]
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title,
                            titleHash: window.titleHash, order: index)
        }
        let affinity = WindowMatcher.Affinity(
            recordDisplays: merged.recordDisplays,
            windowDisplays: WindowMatcher.Affinity.windowDisplays(of: windows,
                                                                  displays: displays))
        let assignment = WindowMatcher.assign(records: merged.matchingRecords,
                                              to: candidates,
                                              allowOrderFallback: true,
                                              affinity: affinity)
        let bySlot = Dictionary(uniqueKeysWithValues: merged.map { ($0.slot, $0) })
        XCTAssertEqual(bySlot[assignment[20]!.slot]?.displayID, "A",
                       "hash match crosses displays: identity outranks geometry")
        XCTAssertEqual(bySlot[assignment[10]!.slot]?.displayID, "B",
                       "the leftover record falls to the leftover window")
    }

    // MARK: - 4. Fresh launch degrades to global order

    func testFreshLaunchFallsBackToGlobalOrder() {
        let multi = twoDisplayArcPlan()
        let merged = multi.placements["arc"]!
        // Just-launched cascade: both windows centered on display A.
        let first = DriverWindow(id: 10, title: "",
                                 frame: CGRect(x: 400, y: 150, width: 800, height: 600))
        let second = DriverWindow(id: 11, title: "",
                                  frame: CGRect(x: 430, y: 180, width: 800, height: 600))
        let windows = [first, second]
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title,
                            titleHash: window.titleHash, order: index)
        }
        let affinity = WindowMatcher.Affinity(
            recordDisplays: merged.recordDisplays,
            windowDisplays: WindowMatcher.Affinity.windowDisplays(of: windows,
                                                                  displays: displays))
        let assignment = WindowMatcher.assign(records: merged.matchingRecords,
                                              to: candidates,
                                              allowOrderFallback: true,
                                              affinity: affinity)
        XCTAssertEqual(assignment.count, 2,
                       "no window left unmatched while a record goes begging")
        let bySlot = Dictionary(uniqueKeysWithValues: merged.map { ($0.slot, $0) })
        XCTAssertEqual(bySlot[assignment[10]!.slot]?.displayID, "A",
                       "stable global order: first window takes the first record")
        XCTAssertEqual(bySlot[assignment[11]!.slot]?.displayID, "B")
    }

    // MARK: - 5. Global count gate

    func testGlobalCountGate() {
        // Records slot 0 (A, anonymous) and slot 1 (B, hashed); ONE live window.
        let multi = twoDisplayArcPlan(hashA: nil, hashB: testHash("Work"))
        let merged = multi.placements["arc"]!
        let records = merged.matchingRecords
        let window = DriverWindow(id: 10, title: "Work",
                                  frame: CGRect(x: 500, y: 200, width: 800, height: 600))
        let windows = [window]
        // The gate compares GLOBAL totals: 1 window < 2 merged records.
        let allowOrderFallback = windows.count >= records.count
        XCTAssertFalse(allowOrderFallback)
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title,
                            titleHash: window.titleHash, order: index)
        }
        let affinity = WindowMatcher.Affinity(
            recordDisplays: merged.recordDisplays,
            windowDisplays: WindowMatcher.Affinity.windowDisplays(of: windows,
                                                                  displays: displays))
        let assignment = WindowMatcher.assign(records: records,
                                              to: candidates,
                                              allowOrderFallback: allowOrderFallback,
                                              affinity: affinity)
        // Order fallback withheld — the A record must NOT drag the window in —
        // but the hash phase still claims it (pin/hash always allowed).
        XCTAssertEqual(assignment.count, 1)
        let bySlot = Dictionary(uniqueKeysWithValues: merged.map { ($0.slot, $0) })
        XCTAssertEqual(bySlot[assignment[10]!.slot]?.displayID, "B",
                       "hash identity, not display A's leftover record, wins")
    }

    // MARK: - 6. Nil affinity is byte-compatible

    func testNilAffinityIsByteCompatible() {
        // An existing scenario (hash swap, WindowMatcherTests shape) run through
        // both call shapes must be identical.
        func record(slot: Int, title: String) -> WindowRecord {
            WindowRecord(slot: slot, titleHash: testHash(title),
                         frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.5),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 0))
        }
        let records = [record(slot: 0, title: "Work"), record(slot: 1, title: "Play")]
        let windows = [WindowCandidate(id: 10, title: "Play",
                                       titleHash: testHash("Play"), order: 0),
                       WindowCandidate(id: 11, title: "Work",
                                       titleHash: testHash("Work"), order: 1)]
        XCTAssertEqual(WindowMatcher.assign(records: records, to: windows),
                       WindowMatcher.assign(records: records, to: windows,
                                            allowOrderFallback: true, affinity: nil))

        // And an order-fallback-heavy scenario (anonymous windows, uneven counts).
        let anonymous = [WindowRecord(slot: 0, titleHash: nil,
                                      frame: NormalizedFrame(x: 0, y: 0, w: 1, h: 1),
                                      pinPattern: nil,
                                      lastSeen: Date(timeIntervalSince1970: 0)),
                         WindowRecord(slot: 1, titleHash: nil,
                                      frame: NormalizedFrame(x: 0, y: 0, w: 1, h: 1),
                                      pinPattern: nil,
                                      lastSeen: Date(timeIntervalSince1970: 0))]
        let three = [WindowCandidate(id: 1, title: "", titleHash: nil, order: 0),
                     WindowCandidate(id: 2, title: "", titleHash: nil, order: 1),
                     WindowCandidate(id: 3, title: "", titleHash: nil, order: 2)]
        XCTAssertEqual(WindowMatcher.assign(records: anonymous, to: three),
                       WindowMatcher.assign(records: anonymous, to: three,
                                            allowOrderFallback: true, affinity: nil))
    }

    // MARK: - 7. Absolute placement shares the clamp policy

    func testAbsolutePlacementUsesTheEngineClampPolicy() {
        let driver = FakeDriver()
        driver.clampHeightTo = 500 // app refuses the requested height
        let window = DriverWindow(id: 10, title: "Work",
                                  frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let target = CGRect(x: 100, y: 100, width: 800, height: 600)
        let placed = RestoreEngine(driver: driver)
            .place(assignments: [(window: window, target: target)])
        XCTAssertEqual(placed, 1)
        XCTAssertEqual(driver.setFrameCalls.count, 2,
                       "set, read back, exactly one retry, then accept")
        XCTAssertEqual(driver.setFrameCalls[0].frame, target)
        XCTAssertEqual(driver.setFrameCalls[1].frame, target,
                       "retry resends the original target, not the clamped result")

        // Within tolerance: no retry, same as `restore`.
        let calm = FakeDriver()
        RestoreEngine(driver: calm)
            .place(assignments: [(window: window, target: target)])
        XCTAssertEqual(calm.setFrameCalls.count, 1)
    }

    // MARK: - 8. Bucketing helper

    func testWindowsBucketByCenterWithNearestFallback() {
        let onA = DriverWindow(id: 1, title: "",
                               frame: CGRect(x: 500, y: 200, width: 800, height: 600))
        // Straddles the seam: center at x = 2000, contained by B's half-open area.
        let straddling = DriverWindow(id: 2, title: "",
                                      frame: CGRect(x: 1900, y: 200, width: 200, height: 300))
        // Center inside neither visible area (above both, at the B side):
        // nearest-center fallback must pick B.
        let offscreen = DriverWindow(id: 3, title: "",
                                     frame: CGRect(x: 2100, y: 0, width: 100, height: 20))
        let buckets = WindowMatcher.Affinity.windowDisplays(
            of: [onA, straddling, offscreen], displays: displays)
        XCTAssertEqual(buckets[1], "A")
        XCTAssertEqual(buckets[2], "B")
        XCTAssertEqual(buckets[3], "B", "off-area window falls to the nearest center")
    }
}
