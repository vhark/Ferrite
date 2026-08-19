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
public enum WindowMatcher {
    public static func assign(records: [WindowRecord],
                              to windows: [WindowCandidate]) -> [Int: WindowRecord] {
        var result: [Int: WindowRecord] = [:]
        var freeRecords = records.sorted { $0.slot < $1.slot }
        var freeWindows = windows.sorted { $0.order < $1.order }

        // 1. Pin patterns (case-insensitive regex; invalid patterns ignored).
        for record in freeRecords where record.pinPattern != nil {
            guard let pattern = record.pinPattern,
                  (try? NSRegularExpression(pattern: pattern)) != nil,
                  let index = freeWindows.firstIndex(where: {
                      $0.title.range(of: pattern,
                                     options: [.regularExpression, .caseInsensitive]) != nil
                  })
            else { continue }
            result[freeWindows[index].id] = record
            freeWindows.remove(at: index)
        }
        freeRecords.removeAll { candidate in result.values.contains(candidate) }

        // 2. Exact title matches.
        for record in freeRecords {
            guard let index = freeWindows.firstIndex(where: { $0.title == record.title })
            else { continue }
            result[freeWindows[index].id] = record
            freeWindows.remove(at: index)
        }
        freeRecords.removeAll { candidate in result.values.contains(candidate) }

        // 3. Remaining pairs by order.
        for (window, record) in zip(freeWindows, freeRecords) {
            result[window.id] = record
        }
        return result
    }
}
