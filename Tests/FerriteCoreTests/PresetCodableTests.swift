import XCTest
@testable import FerriteCore

final class PresetCodableTests: XCTestCase {
    func testEveryPresetRoundTrips() throws {
        let presets: [GroupLayoutSolver.Preset] = [
            .columns, .rows, .grid, .mainSide, .mainSideMirrored, .symmetric,
            .treemap(bias: .center), .treemap(bias: .left), .treemap(bias: .right),
            .mainCenter(fraction: 0.66, sideCapacity: 4),
            .mainCenter(fraction: 0.6, sideCapacity: nil),
            .bsp, .cascade, .monocle,
            .fixedColumns(7), .fixedGrid(columns: 7, rows: 3),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for preset in presets {
            let data = try encoder.encode(preset)
            let back = try decoder.decode(GroupLayoutSolver.Preset.self, from: data)
            XCTAssertEqual(back, preset)
        }
    }
}
