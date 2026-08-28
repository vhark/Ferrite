import AppKit
import FerriteCore

/// Menu glyphs drawn by the solver itself.
///
/// Each icon is `GroupLayoutSolver`'s own answer for a representative window
/// count (see `tileCount(for:)`) inside the glyph box, so a glyph literally
/// depicts the arrangement clicking it produces and cannot drift out of sync
/// with the solver.
enum PresetGlyph {
    static let size = CGSize(width: 44, height: 30)

    /// Five tiles for count-adaptive presets (the smallest count that tells
    /// them all apart). Fixed-zone presets draw their true cell count so the
    /// glyph depicts the exact division; cascade shows three staggered tiles;
    /// monocle shows one.
    private static func tileCount(for preset: GroupLayoutSolver.Preset) -> Int {
        switch preset {
        case .fixedColumns(let count): return max(1, count)
        case .fixedGrid(let columns, let rows): return max(1, columns * rows)
        case .cascade: return 3
        case .monocle: return 1
        case .columns, .rows, .grid, .mainSide, .mainSideMirrored,
             .symmetric, .treemap, .mainCenter, .bsp:
            return 5
        }
    }

    static func image(for preset: GroupLayoutSolver.Preset) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(preset)
            return true
        }
        // The accent tile must keep its colour; template rendering would flatten
        // the whole glyph to the menu's text colour.
        image.isTemplate = false
        return image
    }

    private static func draw(_ preset: GroupLayoutSolver.Preset) {
        let outline = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let backdrop = NSBezierPath(roundedRect: outline, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        backdrop.fill()
        backdrop.lineWidth = 1
        NSColor.tertiaryLabelColor.setStroke()
        backdrop.stroke()

        let box = outline.insetBy(dx: 2.5, dy: 2.5)
        let count = tileCount(for: preset)
        let tiles = (0..<count).map { index in
            GroupLayoutSolver.Tile(id: index,
                                   weight: readsWeights(preset)
                                       ? Double(count - index) : 1)
        }
        let solved = GroupLayoutSolver.solve(tiles: tiles, preset: preset,
                                             in: box, gap: 1.5)

        backdrop.setClip()
        // Heaviest last, so the accent tile draws over any clamped neighbour.
        for (id, rect) in solved.sorted(by: { $0.key > $1.key }) {
            // Solver space is CG (top-left origin); this context is bottom-left,
            // so mirror or the frontmost tile lands at the bottom of the glyph.
            let mirrored = CGRect(x: rect.minX,
                                  y: box.minY + box.maxY - rect.maxY,
                                  width: rect.width, height: rect.height)
            if id == 0 {
                NSColor.controlAccentColor.setFill()
            } else {
                NSColor.secondaryLabelColor.setFill()
            }
            NSBezierPath(roundedRect: mirrored, xRadius: 1.5, yRadius: 1.5).fill()
        }

        if case .monocle = preset {
            // A single full tile reads as "one window"; the inner stroke says
            // "every window, stacked".
            let inner = box.insetBy(dx: 3, dy: 3)
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Only these presets read the weights. The even ones get equal tiles so
    /// their glyph shows the true division rather than a fake gradient of sizes.
    private static func readsWeights(_ preset: GroupLayoutSolver.Preset) -> Bool {
        switch preset {
        case .treemap, .mainSide, .mainSideMirrored, .mainCenter: return true
        case .columns, .rows, .grid, .symmetric, .bsp, .cascade, .monocle,
             .fixedColumns, .fixedGrid:
            return false
        }
    }
}
