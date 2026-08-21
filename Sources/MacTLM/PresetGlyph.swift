import AppKit
import MacTLMCore

/// Menu glyphs drawn by the solver itself.
///
/// Each icon is `GroupLayoutSolver`'s own answer for five windows inside the
/// glyph box, so a glyph literally depicts the arrangement clicking it produces
/// and cannot drift out of sync with the solver.
enum PresetGlyph {
    static let size = CGSize(width: 44, height: 30)

    /// Five tiles is the smallest count that tells every preset apart: grid
    /// becomes 3×2, main+side gets three side tiles, and the treemap has enough
    /// left over to show its bias.
    private static let tileCount = 5

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
        let tiles = (0..<tileCount).map { index in
            GroupLayoutSolver.Tile(id: index,
                                   weight: readsWeights(preset)
                                       ? Double(tileCount - index) : 1)
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
    }

    /// Only these presets read the weights. The even ones get equal tiles so
    /// their glyph shows the true division rather than a fake gradient of sizes.
    private static func readsWeights(_ preset: GroupLayoutSolver.Preset) -> Bool {
        switch preset {
        case .treemap, .mainSide: return true
        case .columns, .rows, .grid, .symmetric: return false
        }
    }
}
