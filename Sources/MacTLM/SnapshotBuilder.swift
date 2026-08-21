import AppKit
import MacTLMCore

/// Captures the current arrangement into per-display MonitorLayouts.
enum SnapshotBuilder {
    static func snapshot(name: String, stageMode: StageMode) -> [MonitorLayout] {
        var axRefs: [ZOrderMatcher.AXRef] = []
        var meta: [Int: (bundleID: String, title: String, frame: CGRect)] = [:]
        var seenBundles = Set<String>()

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !app.isHidden,
                  seenBundles.insert(bundleID).inserted else { continue }
            let appHandle = AXAppHandle(pid: app.processIdentifier)
            for window in appHandle.windows {
                guard window.isStandardWindow, !window.isMinimized,
                      let frame = window.frame, frame.width > 1, frame.height > 1
                else { continue }
                let id = window.stableID
                axRefs.append(ZOrderMatcher.AXRef(id: id, pid: app.processIdentifier,
                                                  frame: frame))
                meta[id] = (bundleID, window.title, frame)
            }
        }

        let zIndices = ZOrderMatcher.zIndices(axWindows: axRefs,
                                              cgFrontToBack: ZOrderCapture.frontToBack())
        let windows = meta.compactMap { id, m -> SnapshotPlanner.Window? in
            guard let z = zIndices[id] else { return nil }
            return SnapshotPlanner.Window(bundleID: m.bundleID, title: m.title,
                                          titleHash: nil,
                                          frame: m.frame, zIndex: z)
        }
        return SnapshotPlanner.plan(name: name, stageMode: stageMode,
                                    windows: windows,
                                    displays: ScreenGeometry.allDisplays,
                                    date: Date())
    }
}
