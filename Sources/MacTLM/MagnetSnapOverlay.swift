import AppKit
import MacTLMCore

/// A thin accent line showing which edge a dragged window is about to mate to.
/// Without it, mating reads as windows jumping for no reason (PRD §5).
final class MagnetSnapOverlay {
    /// Thickness of the bar, in points.
    private static let thickness: CGFloat = 4

    private lazy var panel: NSPanel = Self.makePanel()

    /// Highlights `edge` of `frame`, both in AX/CG space: `frame` is where the
    /// dragged window will land and `edge` is the side of it that meets the
    /// mate, so the bar sits exactly on the boundary the two will share.
    func show(edge: MagnetMating.Edge, of frame: CGRect) {
        let bar = Self.barRect(along: edge, of: frame)
        guard bar.width > 0, bar.height > 0 else { return hide() }
        panel.setFrame(ScreenGeometry.nsRect(fromCG: bar), display: false)
        // Resolved per show: the accent colour follows System Settings.
        panel.contentView?.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        // Regardless: MacTLM is an accessory app and is never the active one.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// The bar's rect in CG space — a full-length sliver inset along `edge`.
    private static func barRect(along edge: MagnetMating.Edge, of frame: CGRect) -> CGRect {
        switch edge {
        case .left:
            return CGRect(x: frame.minX, y: frame.minY,
                          width: thickness, height: frame.height)
        case .right:
            return CGRect(x: frame.maxX - thickness, y: frame.minY,
                          width: thickness, height: frame.height)
        case .top:
            return CGRect(x: frame.minX, y: frame.minY,
                          width: frame.width, height: thickness)
        case .bottom:
            return CGRect(x: frame.minX, y: frame.maxY - thickness,
                          width: frame.width, height: thickness)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = thickness / 2
        bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        panel.contentView = bar
        return panel
    }
}
