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
    /// from the live title, exactly as the real driver layer does.
    init(id: Int, title: String, frame: CGRect) {
        self.init(id: id, title: title, titleHash: testHash(title), frame: frame)
    }
}
