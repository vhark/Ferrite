import Foundation

/// A currently-open window as seen by the driver, reduced to matching inputs.
public struct WindowCandidate: Equatable {
    public let id: Int       // driver-stable identifier
    public let title: String
    public let order: Int    // enumeration order, 0 = frontmost

    public init(id: Int, title: String, order: Int) {
        self.id = id; self.title = title; self.order = order
    }
}

/// Assigns remembered records to open windows:
/// 1. pin patterns claim first, 2. exact titles, 3. remaining by order.
/// Phase 3 is opt-out: pass `allowOrderFallback: false` when the open windows
/// cannot be trusted to correspond to the remembered ones.
public enum WindowMatcher {
    public static func assign(records: [WindowRecord],
                              to windows: [WindowCandidate],
                              allowOrderFallback: Bool = true) -> [Int: WindowRecord] {
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

        // 2. Exact title matches.
        claimed = []
        for (i, record) in freeRecords.enumerated() {
            guard let index = freeWindows.firstIndex(where: { $0.title == record.title })
            else { continue }
            result[freeWindows[index].id] = record
            freeWindows.remove(at: index)
            claimed.append(i)
        }
        for i in claimed.reversed() { freeRecords.remove(at: i) }

        // 3. Remaining pairs by order.
        if allowOrderFallback {
            for (window, record) in zip(freeWindows, freeRecords) {
                result[window.id] = record
            }
        }
        return result
    }
}
