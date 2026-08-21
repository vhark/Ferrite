import Foundation
@testable import MacTLMCore

/// Stand-in for the app layer's salted `WindowIdentity.hash`: same title ->
/// same opaque identity, blank title -> nil. Core never hashes, so tests supply
/// the mapping themselves.
func testHash(_ title: String) -> String? {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "h:\(title)"
}

extension DriverWindow {
    /// Test convenience mirroring `MacWindowDriver`: derives the identity hash
    /// from the live title, exactly as the real driver layer does. `pid` only
    /// matters to the z-order matcher, which Core tests do not exercise, so it
    /// defaults rather than being spelled out at ~30 call sites.
    init(id: Int, pid: pid_t = 0, title: String, frame: CGRect) {
        self.init(id: id, pid: pid, title: title,
                  titleHash: testHash(title), frame: frame)
    }
}
