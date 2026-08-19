import AppKit
import MacTLMCore

/// Captures global front-to-back window order via CGWindowList.
/// Bounds/pid/layer need no extra permission (window *names* would).
enum ZOrderCapture {
    /// Front-to-back refs for normal-layer on-screen windows.
    static func frontToBack() -> [ZOrderMatcher.CGRef] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return ZOrderMatcher.CGRef(pid: pid, frame: bounds)
        }
    }
}
