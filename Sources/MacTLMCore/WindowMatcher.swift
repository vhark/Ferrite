import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A currently-open window as seen by the driver, reduced to matching inputs.
///
/// `title` is live and in-memory only — used for pin patterns and UI display,
/// never persisted. `titleHash` is the opaque identity that records compare
/// against.
public struct WindowCandidate: Equatable {
    public let id: Int       // driver-stable identifier
    public let title: String
    public let titleHash: String?
    public let order: Int    // enumeration order, 0 = frontmost

    public init(id: Int, title: String, titleHash: String?, order: Int) {
        self.id = id; self.title = title
        self.titleHash = titleHash; self.order = order
    }
}

/// Assigns remembered records to open windows:
/// 1. pin patterns claim first, 2. identical title hashes, 3. remaining by order.
/// Phase 3 is opt-out: pass `allowOrderFallback: false` when the open windows
/// cannot be trusted to correspond to the remembered ones.
public enum WindowMatcher {
    /// Display hint for the order-fallback phase ONLY (merged multi-display
    /// placement). Pin and hash phases never consult it: certain identity
    /// outranks geometry. This keeps `assign` the single identity path
    /// (BACKLOG finding 20) — never a second matcher.
    public struct Affinity {
        /// record slot → the display its placement targets
        public let recordDisplays: [Int: String]
        /// live window id → the display currently owning its center
        public let windowDisplays: [Int: String]

        public init(recordDisplays: [Int: String], windowDisplays: [Int: String]) {
            self.recordDisplays = recordDisplays
            self.windowDisplays = windowDisplays
        }

        /// Buckets live windows by the display owning their center —
        /// containment first, nearest-center for straddlers. Same rule as
        /// capture (`SnapshotPlanner.assign`), reused, not forked.
        public static func windowDisplays(
            of windows: [DriverWindow],
            displays: [(id: String, area: CGRect)]
        ) -> [Int: String] {
            let areas = displays.map(\.area)
            var result: [Int: String] = [:]
            for window in windows {
                guard let index = SnapshotPlanner.ownerIndex(of: window.frame,
                                                             areas: areas)
                else { continue }
                result[window.id] = displays[index].id
            }
            return result
        }
    }

    public static func assign(records: [WindowRecord],
                              to windows: [WindowCandidate],
                              allowOrderFallback: Bool = true,
                              affinity: Affinity? = nil) -> [Int: WindowRecord] {
        var result: [Int: WindowRecord] = [:]
        var freeRecords = records.sorted { $0.slot < $1.slot }
        var freeWindows = windows.sorted { $0.order < $1.order }

        // 1. Pin patterns (case-insensitive regex; empty/invalid patterns ignored).
        var claimed: [Int] = []
        for (i, record) in freeRecords.enumerated() where record.pinPattern != nil {
            guard let pattern = record.pinPattern,
                  !pattern.isEmpty,
                  (try? NSRegularExpression(pattern: pattern)) != nil,
                  let index = freeWindows.firstIndex(where: {
                      $0.title.range(of: pattern,
                                     options: [.regularExpression, .caseInsensitive]) != nil
                  })
            else { continue }
            result[freeWindows[index].id] = record
            freeWindows.remove(at: index)
            claimed.append(i)
        }
        for i in claimed.reversed() { freeRecords.remove(at: i) }

        // 2. Identity-hash matches. Nil hashes are skipped: two untitled
        // windows must never pair on `nil == nil`.
        claimed = []
        for (i, record) in freeRecords.enumerated() {
            guard let hash = record.titleHash,
                  let index = freeWindows.firstIndex(where: { $0.titleHash == hash })
            else { continue }
            result[freeWindows[index].id] = record
            freeWindows.remove(at: index)
            claimed.append(i)
        }
        for i in claimed.reversed() { freeRecords.remove(at: i) }

        // 3. Remaining pairs by order. With an affinity, same-display
        // record/window pairs zip first (stable order), leftovers zip
        // globally — adopt-running windows stay where the user left them,
        // freshly launched ones degrade to plain global order.
        if allowOrderFallback {
            if let affinity {
                var leftoverWindows: [WindowCandidate] = []
                for window in freeWindows {
                    guard let display = affinity.windowDisplays[window.id],
                          let index = freeRecords.firstIndex(where: {
                              affinity.recordDisplays[$0.slot] == display
                          }) else {
                        leftoverWindows.append(window)
                        continue
                    }
                    result[window.id] = freeRecords.remove(at: index)
                }
                freeWindows = leftoverWindows
            }
            for (window, record) in zip(freeWindows, freeRecords) {
                result[window.id] = record
            }
        }
        return result
    }
}
