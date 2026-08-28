import AppKit
import SwiftUI
import FerriteCore

/// Custom reflow presets (pinned to the menu's glyph rows) and the
/// display-reflow group policy. The glyph preview is the solver's own answer
/// (PresetGlyph), so what you see is exactly what clicking it will do.
struct ReflowsPreferencesView: View {
    @ObservedObject var model: ReflowsPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Keep magnet groups together when reflowing a display",
                   isOn: Binding(get: { model.keepGroups },
                                 set: { model.setKeepGroups($0) }))
            Text("Off (default): a display reflow places every window "
                 + "individually and dissolves the magnet groups it touches. "
                 + "On: each group is placed as one tile and keeps its shape.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Custom presets").font(.headline)
                Spacer()
                Button("Add") { model.addPreset() }
            }
            if model.presets.isEmpty {
                Text("Custom presets appear as extra glyphs in the menu's "
                     + "reflow rows — a fixed column count, an exact grid, "
                     + "or a main-centre split with your own proportions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(model.presets) { preset in
                    CustomPresetRow(entry: preset, model: model)
                }
            }
        }
        .padding(4)
    }
}

private struct CustomPresetRow: View {
    let entry: CustomReflowPreset
    @ObservedObject var model: ReflowsPreferencesModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: PresetGlyph.image(for: entry.preset))
            TextField("Name", text: Binding(get: { entry.name },
                                            set: { model.rename(entry.id, to: $0) }))
                .frame(width: 140)
            Picker("", selection: Binding(get: { PresetKind(entry.preset) },
                                          set: { model.setKind($0, for: entry.id) })) {
                Text("Columns").tag(PresetKind.columns)
                Text("Grid").tag(PresetKind.grid)
                Text("Main centre").tag(PresetKind.mainCenter)
            }
            .labelsHidden()
            .frame(width: 120)
            parameterControls
            Spacer()
            Button {
                model.remove(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var parameterControls: some View {
        switch entry.preset {
        case .fixedColumns(let count):
            Stepper("\(count) wide",
                    value: Binding(get: { count },
                                   set: { model.update(entry.id, preset: .fixedColumns($0)) }),
                    in: 1...12)
        case .fixedGrid(let columns, let rows):
            Stepper("\(columns) wide",
                    value: Binding(get: { columns },
                                   set: { model.update(entry.id,
                                                       preset: .fixedGrid(columns: $0, rows: rows)) }),
                    in: 1...12)
            Stepper("\(rows) tall",
                    value: Binding(get: { rows },
                                   set: { model.update(entry.id,
                                                       preset: .fixedGrid(columns: columns, rows: $0)) }),
                    in: 1...8)
        case .mainCenter(let fraction, let sideCapacity):
            Stepper("centre \(Int(fraction * 100))%",
                    value: Binding(get: { Int(fraction * 100) },
                                   set: { model.update(entry.id,
                                                       preset: .mainCenter(fraction: Double($0) / 100,
                                                                           sideCapacity: sideCapacity)) }),
                    in: 20...90, step: 2)
            Stepper(sideCapacityLabel(sideCapacity),
                    value: Binding(get: { sideCapacity ?? 0 },
                                   set: { model.update(entry.id,
                                                       preset: .mainCenter(fraction: fraction,
                                                                           sideCapacity: $0 == 0 ? nil : $0)) }),
                    in: 0...8)
        case .columns, .rows, .grid, .mainSide, .mainSideMirrored, .symmetric,
             .treemap, .bsp, .cascade, .monocle:
            // Built-ins are not user-editable; a custom preset is always one
            // of the three editable kinds, so this is unreachable in practice.
            EmptyView()
        }
    }

    /// 0 means "no cap" — side stacks grow with the window count.
    private func sideCapacityLabel(_ capacity: Int?) -> String {
        guard let capacity, capacity > 0 else { return "∞ per side" }
        return "\(capacity) per side"
    }
}

/// The three editable kinds; switching kind swaps in that kind's defaults.
enum PresetKind: Hashable {
    case columns, grid, mainCenter

    init(_ preset: GroupLayoutSolver.Preset) {
        switch preset {
        case .fixedColumns: self = .columns
        case .fixedGrid: self = .grid
        case .mainCenter: self = .mainCenter
        case .columns, .rows, .grid, .mainSide, .mainSideMirrored, .symmetric,
             .treemap, .bsp, .cascade, .monocle:
            // A custom preset is never a built-in; fall back to the kind whose
            // defaults are least surprising if one ever appears.
            self = .grid
        }
    }

    var defaultPreset: GroupLayoutSolver.Preset {
        switch self {
        case .columns: return .fixedColumns(3)
        case .grid: return .fixedGrid(columns: 3, rows: 2)
        case .mainCenter: return .mainCenter(fraction: 0.66, sideCapacity: 4)
        }
    }
}

/// Bridges the coordinator's ReflowStore to SwiftUI.
final class ReflowsPreferencesModel: ObservableObject {
    @Published var presets: [CustomReflowPreset] = []
    @Published var keepGroups = false
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        // The window and this model are cached for the daemon's lifetime, so
        // without the hook the tab would freeze at whatever the store held
        // when it was first created — and the menu's own toggle writes the
        // same setting (finding 16 corollary).
        coordinator.onReflowSettingsChanged = { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        let settings = coordinator.reflowSettings()
        presets = settings.customPresets
        keepGroups = settings.keepGroupsOnDisplayReflow
    }

    // Every mutator writes through the coordinator, whose hook fires reload —
    // so these never call reload() themselves. The outer closure parameter is
    // named because the inner predicates need their own `$0`.
    func setKeepGroups(_ on: Bool) {
        coordinator.updateReflowSettings { $0.keepGroupsOnDisplayReflow = on }
    }

    func addPreset() {
        coordinator.updateReflowSettings { settings in
            settings.customPresets.append(CustomReflowPreset(
                name: "Custom \(settings.customPresets.count + 1)",
                preset: .fixedGrid(columns: 3, rows: 2)))
        }
    }

    func remove(_ id: UUID) {
        coordinator.updateReflowSettings { settings in
            settings.customPresets.removeAll { $0.id == id }
        }
    }

    func rename(_ id: UUID, to name: String) {
        coordinator.updateReflowSettings { settings in
            guard let index = settings.customPresets.firstIndex(where: { $0.id == id })
            else { return }
            settings.customPresets[index].name = name
        }
    }

    func update(_ id: UUID, preset: GroupLayoutSolver.Preset) {
        coordinator.updateReflowSettings { settings in
            guard let index = settings.customPresets.firstIndex(where: { $0.id == id })
            else { return }
            settings.customPresets[index].preset = preset
        }
    }

    func setKind(_ kind: PresetKind, for id: UUID) {
        update(id, preset: kind.defaultPreset)
    }
}
