import AppKit
import MacTLMCore

/// Ghost outlines standing in for the followers of a ⌘-cluster carry.
///
/// Moving followers live means a synchronous AX write into each target app's
/// main thread per moved event — one busy member stalls every tick. macOS has
/// no API to freeze another app's rendering, so the honest equivalent of
/// "don't render contents until movement stops" is these ghosts: zero mid-drag
/// IPC, one real write per follower at release.
final class MagnetGhostOverlay {
    private static let cornerRadius: CGFloat = 8
    private static let strokeWidth: CGFloat = 2

    /// One panel per follower, paired with the Cocoa origin it was shown at.
    /// Translation is absolute-from-start — shown origin + delta — so a
    /// dropped mouse event never accumulates into drift.
    private var ghosts: [(panel: NSPanel, shownOrigin: NSPoint)] = []

    /// Shows one ghost per frame. `frames` are in AX/CG space; the flip to
    /// Cocoa happens here, once, via `ScreenGeometry` — never re-derived.
    func show(frames: [CGRect]) {
        hide()
        for frame in frames {
            let panel = Self.makePanel()
            let cocoa = ScreenGeometry.nsRect(fromCG: frame)
            panel.setFrame(cocoa, display: false)
            // Resolved per show: the accent colour follows System Settings.
            if let layer = panel.contentView?.layer {
                layer.borderColor = NSColor.controlAccentColor.cgColor
                layer.backgroundColor = NSColor.controlAccentColor
                    .withAlphaComponent(0.1).cgColor
            }
            // Regardless: MacTLM is an accessory app and is never the active one.
            panel.orderFrontRegardless()
            ghosts.append((panel: panel, shownOrigin: cocoa.origin))
        }
    }

    /// Repositions every ghost from its shown origin by `delta`, in Cocoa
    /// space — the same space as the mouse locations that produce it, so no
    /// flip is involved. `setFrameOrigin` is a window-server op: no IPC.
    func translate(to delta: CGVector) {
        for ghost in ghosts {
            ghost.panel.setFrameOrigin(
                NSPoint(x: ghost.shownOrigin.x + delta.dx,
                        y: ghost.shownOrigin.y + delta.dy))
        }
    }

    func hide() {
        for ghost in ghosts { ghost.panel.orderOut(nil) }
        ghosts.removeAll()
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        // Ordered out and dropped, never closed: ARC owns the lifetime.
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        let outline = NSView()
        outline.wantsLayer = true
        outline.layer?.cornerRadius = cornerRadius
        outline.layer?.borderWidth = strokeWidth
        panel.contentView = outline
        return panel
    }
}
