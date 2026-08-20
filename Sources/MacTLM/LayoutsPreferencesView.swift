import SwiftUI
import KeyboardShortcuts
import MacTLMCore

/// One row per saved workspace: hotkey recorder, stage toggle, rename, archive.
/// Archived workspaces get their own section — greyed out, no hotkey, and the
/// only place a layout can be deleted for good.
struct LayoutsPreferencesView: View {
    @ObservedObject var model: LayoutsPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.bundles.isEmpty && model.archivedBundles.isEmpty {
                Text("No layouts saved yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Layouts") {
                        if model.bundles.isEmpty {
                            Text("No active layouts.").foregroundStyle(.secondary)
                        } else {
                            ForEach(model.bundles, id: \.name) { bundle in
                                LayoutRow(bundle: bundle, model: model)
                            }
                        }
                    }
                    if !model.archivedBundles.isEmpty {
                        Section("Archived") {
                            ForEach(model.archivedBundles, id: \.name) { bundle in
                                ArchivedLayoutRow(bundle: bundle, model: model)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Text("Displays: a layout is saved per monitor. One hotkey restores "
                 + "every display in the workspace.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 340)
        .onAppear { model.reload() }
    }
}

/// Shared name + "N windows · displays" caption.
private struct BundleSummary: View {
    let bundle: LayoutBundle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bundle.name).fontWeight(.medium)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        let displays = bundle.layouts.map(\.displayName).joined(separator: ", ")
        let windows = bundle.layouts.reduce(0) { $0 + $1.entries.count }
        return "\(windows) windows · \(displays)"
    }
}

private struct LayoutRow: View {
    let bundle: LayoutBundle
    @ObservedObject var model: LayoutsPreferencesModel
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if isRenaming {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: $draftName)
                            .onSubmit(commitRename)
                            .frame(width: 180)
                    }
                } else {
                    BundleSummary(bundle: bundle)
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
                // Archiving is reversible, so it needs no confirmation.
                Button("Archive") { model.archive(bundleName: bundle.name) }
            }
            DisclosureGroup("\(windowCount) windows") {
                ForEach(bundle.layouts) { layout in
                    LayoutEntriesGroup(layout: layout,
                                       showsDisplayName: bundle.layouts.count > 1,
                                       model: model)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private var windowCount: Int {
        bundle.layouts.reduce(0) { $0 + $1.entries.count }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        isRenaming = false
        guard !trimmed.isEmpty, trimmed != bundle.name else { return }
        model.rename(from: bundle.name, to: trimmed)
    }
}

/// The windows saved for one display, each removable and flaggable optional.
private struct LayoutEntriesGroup: View {
    let layout: MonitorLayout
    let showsDisplayName: Bool
    @ObservedObject var model: LayoutsPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsDisplayName {
                Text(layout.displayName).font(.caption).foregroundStyle(.secondary)
            }
            if layout.entries.isEmpty {
                // An empty layout is allowed — re-snapshotting refills it.
                Text("No windows left in this layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(layout.entries.enumerated()), id: \.offset) { index, entry in
                    LayoutEntryRow(entry: entry, index: index,
                                   layoutID: layout.id, model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LayoutEntryRow: View {
    let entry: LayoutEntry
    let index: Int
    let layoutID: UUID
    @ObservedObject var model: LayoutsPreferencesModel

    var body: some View {
        HStack(spacing: 12) {
            Text("z\(entry.zIndex)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            Text(PersistenceCoordinator.localizedAppName(forBundleID: entry.bundleID))
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Optional", isOn: Binding(
                get: { entry.optional },
                set: { model.setEntryOptional($0, atIndex: index, inLayoutID: layoutID) }))
                .toggleStyle(.checkbox)
            // No confirmation: a removed entry returns with the next snapshot.
            Button("Remove") { model.removeEntry(atIndex: index, fromLayoutID: layoutID) }
        }
        .padding(.vertical, 1)
    }
}

private struct ArchivedLayoutRow: View {
    let bundle: LayoutBundle
    @ObservedObject var model: LayoutsPreferencesModel
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            BundleSummary(bundle: bundle)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Restore") { model.restore(bundleName: bundle.name) }
            Button("Delete Permanently") { isConfirmingDelete = true }
        }
        .padding(.vertical, 4)
        // Cancel is the default, safe choice; the destructive button is opt-in.
        .confirmationDialog("Delete \"\(bundle.name)\" permanently?",
                            isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) {
                model.deletePermanently(bundleName: bundle.name)
            }
        } message: {
            Text("This removes the saved window positions for every display in "
                 + "this workspace. This cannot be undone.")
        }
    }
}

/// Bridges the AppKit coordinator to SwiftUI.
final class LayoutsPreferencesModel: ObservableObject {
    @Published var bundles: [LayoutBundle] = []
    @Published var archivedBundles: [LayoutBundle] = []
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        reload()
    }

    func reload() {
        bundles = coordinator.loadBundles()
        archivedBundles = coordinator.loadArchivedBundles()
    }

    func rename(from oldName: String, to newName: String) {
        coordinator.renameBundle(from: oldName, to: newName)
        reload()
    }

    func archive(bundleName: String) {
        coordinator.archiveBundle(named: bundleName)
        reload()
    }

    func restore(bundleName: String) {
        coordinator.restoreBundle(named: bundleName)
        reload()
    }

    func deletePermanently(bundleName: String) {
        coordinator.deleteBundle(named: bundleName)
        reload()
    }

    func setClearStage(_ on: Bool, for bundleName: String) {
        coordinator.setStageMode(on ? .clearStage : .leaveOthers,
                                 forBundleNamed: bundleName)
        reload()
    }

    func removeEntry(atIndex index: Int, fromLayoutID layoutID: UUID) {
        coordinator.removeEntry(atIndex: index, fromLayoutID: layoutID)
        reload()
    }

    func setEntryOptional(_ optional: Bool, atIndex index: Int, inLayoutID layoutID: UUID) {
        coordinator.setEntryOptional(optional, atIndex: index, inLayoutID: layoutID)
        reload()
    }
}
