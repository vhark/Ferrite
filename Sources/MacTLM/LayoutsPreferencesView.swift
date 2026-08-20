import SwiftUI
import KeyboardShortcuts
import MacTLMCore

/// One row per saved workspace: hotkey recorder, stage toggle, rename, delete.
struct LayoutsPreferencesView: View {
    @ObservedObject var model: LayoutsPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.bundles.isEmpty {
                Text("No layouts saved yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.bundles, id: \.name) { bundle in
                    LayoutRow(bundle: bundle, model: model)
                }
                .listStyle(.inset)
            }
            Text("Displays: a layout is saved per monitor. One hotkey restores "
                 + "every display in the workspace.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { model.reload() }
    }
}

private struct LayoutRow: View {
    let bundle: LayoutBundle
    @ObservedObject var model: LayoutsPreferencesModel
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .onSubmit(commitRename)
                        .frame(width: 180)
                } else {
                    Text(bundle.name).fontWeight(.medium)
                }
                Text(displaySummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Hide others", isOn: Binding(
                get: { bundle.layouts.first?.stageMode == .clearStage },
                set: { model.setClearStage($0, for: bundle.name) }))
                .toggleStyle(.checkbox)
            KeyboardShortcuts.Recorder("", name: LayoutShortcuts.name(forBundle: bundle.name))
            Button(isRenaming ? "Save" : "Rename") {
                if isRenaming { commitRename() } else {
                    draftName = bundle.name
                    isRenaming = true
                }
            }
            Button("Delete") { model.delete(bundleName: bundle.name) }
        }
        .padding(.vertical, 4)
    }

    private var displaySummary: String {
        let displays = bundle.layouts.map(\.displayName).joined(separator: ", ")
        let windows = bundle.layouts.reduce(0) { $0 + $1.entries.count }
        return "\(windows) windows · \(displays)"
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        isRenaming = false
        guard !trimmed.isEmpty, trimmed != bundle.name else { return }
        model.rename(from: bundle.name, to: trimmed)
    }
}

/// Bridges the AppKit coordinator to SwiftUI.
final class LayoutsPreferencesModel: ObservableObject {
    @Published var bundles: [LayoutBundle] = []
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        reload()
    }

    func reload() { bundles = coordinator.loadBundles() }

    func rename(from oldName: String, to newName: String) {
        coordinator.renameBundle(from: oldName, to: newName)
        reload()
    }

    func delete(bundleName: String) {
        coordinator.deleteBundle(named: bundleName)
        reload()
    }

    func setClearStage(_ on: Bool, for bundleName: String) {
        coordinator.setStageMode(on ? .clearStage : .leaveOthers,
                                 forBundleNamed: bundleName)
        reload()
    }
}
