import SwiftUI
import MacTLMCore

/// One section per app with remembered windows: exclude toggle, a row per
/// remembered slot with its pin pattern, and a destructive "Forget" that drops
/// every record for the app (the cleanup path for stale entries).
struct AppsPreferencesView: View {
    @ObservedObject var model: AppsPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.apps.isEmpty {
                Text("No apps with remembered windows yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.apps) { app in
                        AppRecordSection(app: app, model: model)
                    }
                }
                .listStyle(.inset)
            }
            Text("Records are per display configuration — this list shows what "
                 + "is remembered for the monitors attached right now.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Window titles are shown live and never saved to disk.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 340)
        .onAppear { model.reload() }
    }
}

private struct AppRecordSection: View {
    let app: PersistenceCoordinator.AppRecordSummary
    @ObservedObject var model: AppsPreferencesModel
    @State private var isConfirmingForget = false

    var body: some View {
        Section {
            Toggle("Never move this app's windows", isOn: Binding(
                get: { app.isExcluded },
                set: { model.setExcluded($0, bundleID: app.bundleID) }))
                .toggleStyle(.checkbox)
            // Explains why apps like Illustrator start out excluded.
            if ExcludeList.defaults.isExcluded(app.bundleID) {
                Text("Excluded by default: this app fights external window moves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(app.slots, id: \.slot) { record in
                SlotRow(bundleID: app.bundleID, record: record,
                        liveTitle: app.liveTitles[record.slot], model: model)
            }
            Text("A pin re-attaches a remembered position to the window whose "
                 + "title matches this pattern.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Forget") { isConfirmingForget = true }
            }
            // Cancel is the default, safe choice; forgetting is permanent.
            .confirmationDialog("Forget saved positions for \"\(app.displayName)\"?",
                                isPresented: $isConfirmingForget) {
                Button("Cancel", role: .cancel) {}
                Button("Forget", role: .destructive) {
                    model.forget(bundleID: app.bundleID)
                }
            } message: {
                Text("MacTLM will stop restoring its windows until it learns "
                     + "them again.")
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName).fontWeight(.medium)
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SlotRow: View {
    let bundleID: String
    let record: WindowRecord
    /// The title of the window sitting in this slot right now, if the app is
    /// running and a window matched. Never comes from disk.
    let liveTitle: String?
    @ObservedObject var model: AppsPreferencesModel
    @State private var draftPin = ""

    var body: some View {
        HStack(spacing: 12) {
            Text("Slot \(record.slot)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            // Titles are never persisted, so a slot with no live window can
            // only identify itself by position.
            Text(liveTitle ?? "Window \(record.slot + 1)")
                .foregroundStyle(liveTitle == nil ? AnyShapeStyle(.secondary)
                                                  : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("no pin", text: $draftPin)
                .frame(width: 200)
                .onSubmit {
                    model.setPinPattern(draftPin, bundleID: bundleID, slot: record.slot)
                }
        }
        .padding(.vertical, 2)
        .onAppear { draftPin = record.pinPattern ?? "" }
        // Rows are reused across reloads, so track the persisted value too.
        .onChange(of: record.pinPattern) { draftPin = $0 ?? "" }
    }
}

/// Bridges the AppKit coordinator to SwiftUI. Every mutation reloads, so the
/// list always reflects what the tracker just persisted.
final class AppsPreferencesModel: ObservableObject {
    @Published var apps: [PersistenceCoordinator.AppRecordSummary] = []
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        reload()
    }

    func reload() {
        apps = coordinator.appRecordSummaries()
    }

    func setPinPattern(_ pattern: String, bundleID: String, slot: Int) {
        coordinator.setPinPattern(pattern, bundleID: bundleID, slot: slot)
        reload()
    }

    func forget(bundleID: String) {
        coordinator.forgetApp(bundleID: bundleID)
        reload()
    }

    func setExcluded(_ excluded: Bool, bundleID: String) {
        coordinator.setExcluded(excluded, bundleID: bundleID)
        reload()
    }
}
