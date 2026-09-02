import Foundation
import CoreGraphics

// Emits the site's preset diagrams from Ferrite's own solver, so a diagram can
// never depict an arrangement the app would not produce. Compiled directly
// against Sources/FerriteCore/GroupLayoutSolver.swift.

let box = CGRect(x: 0, y: 0, width: 160, height: 100)
let gap: CGFloat = 3

struct Entry {
    let id: String
    let label: String
    let preset: GroupLayoutSolver.Preset
    let count: Int
    let weighted: Bool
}

let entries: [Entry] = [
    .init(id: "columns", label: "Columns", preset: .columns, count: 4, weighted: false),
    .init(id: "rows", label: "Rows", preset: .rows, count: 3, weighted: false),
    .init(id: "grid", label: "Grid", preset: .grid, count: 5, weighted: false),
    .init(id: "symmetric", label: "Symmetric", preset: .symmetric, count: 5, weighted: false),
    .init(id: "mainside", label: "Main + side", preset: .mainSide, count: 4, weighted: true),
    .init(id: "mainside-mirror", label: "Main + side, right", preset: .mainSideMirrored, count: 4, weighted: true),
    .init(id: "maincenter", label: "Main in the centre", preset: .mainCenter(fraction: 0.6, sideCapacity: nil), count: 5, weighted: true),
    .init(id: "bsp", label: "Split spiral", preset: .bsp, count: 5, weighted: false),
    .init(id: "treemap-c", label: "Treemap, centre", preset: .treemap(bias: .center), count: 5, weighted: true),
    .init(id: "treemap-l", label: "Treemap, left", preset: .treemap(bias: .left), count: 5, weighted: true),
    .init(id: "treemap-r", label: "Treemap, right", preset: .treemap(bias: .right), count: 5, weighted: true),
    .init(id: "cascade", label: "Cascade", preset: .cascade, count: 4, weighted: false),
    .init(id: "monocle", label: "Monocle", preset: .monocle, count: 3, weighted: false),
    // Custom-preset examples, the two the user asked for by name.
    .init(id: "custom-grid", label: "Custom grid, 7 x 3", preset: .fixedGrid(columns: 7, rows: 3), count: 11, weighted: false),
    .init(id: "custom-cols", label: "Custom columns, 5 wide", preset: .fixedColumns(5), count: 7, weighted: false),
    .init(id: "custom-center", label: "Custom centre, 66% / 4 a side", preset: .mainCenter(fraction: 0.66, sideCapacity: 4), count: 7, weighted: true),
]

func svg(for entry: Entry) -> String {
    let tiles = (0..<entry.count).map { index in
        GroupLayoutSolver.Tile(id: index,
                               weight: entry.weighted ? Double(entry.count - index) : 1)
    }
    let solved = GroupLayoutSolver.solve(tiles: tiles, preset: entry.preset,
                                         in: box, gap: gap)
    // Back to front so the accent (frontmost, id 0) draws last and sits on top,
    // matching how the app writes frames.
    let ordered = solved.sorted { $0.key > $1.key }
    var rects = ""
    for (id, r) in ordered {
        let cls = id == 0 ? "t a" : "t"
        rects += String(format:
            "<rect class=\"%@\" x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" rx=\"2\"/>",
            cls, r.minX, r.minY, max(r.width, 0), max(r.height, 0))
    }
    return "<svg viewBox=\"0 0 160 100\" role=\"img\" aria-label=\"\(entry.label) layout\">\(rects)</svg>"
}

for entry in entries {
    print("<!--\(entry.id)-->")
    print(svg(for: entry))
    print("<!--label:\(entry.label)-->")
}
