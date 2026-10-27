import AppKit
import SwiftUI
import FerriteCore

/// Magnet gesture settings. The overlap gate remains fixed so loosening the
/// mate reach cannot turn corner grazes into accidental mates.
struct MagnetsPreferencesView: View {
    @ObservedObject var model: MagnetsPreferencesModel

    /// The model's own bounds, so the slider cannot offer a reach the model
    /// would silently clamp.
    private static let bounds =
        MagnetSettings.minimumMateReach...MagnetSettings.maximumMateReach

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mate reach")
                Slider(value: Binding(get: { model.mateReach },
                                      set: { model.setMateReach($0) }),
                       in: Self.bounds,
                       step: 4)
                Text("\(Int(model.mateReach)) pt")
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            Text("How near a window's edge must come to another window's "
                 + "facing edge before the blue preview appears and releasing "
                 + "mates them. A smaller number means you have to aim more "
                 + "precisely; a larger one means the mate is offered from "
                 + "further out. Accidental mates are prevented by requiring "
                 + "the two edges to actually overlap — at least a quarter of "
                 + "the shorter side — not by this distance.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Perpendicular alignment uses its own 24 pt threshold, "
                 + "independent of mate reach.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Scale groups when resizing outer edges or corners",
                   isOn: Binding(get: { model.scaleGroupsOnResize },
                                 set: { model.setScaleGroupsOnResize($0) }))
            Text("Off by default. When enabled, resizing an outer edge or "
                 + "corner scales the whole group on release. Shared-edge "
                 + "Shrink/Nudge still works when this is off. Standard mode "
                 + "never scales the group.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Application Clustering Mode (Alpha)",
                   isOn: Binding(get: { model.autoClusterSameApp },
                                 set: { model.setAutoClusterSameApp($0) }))
            Text("Replaces existing magnet groups with same-application clusters "
                 + "on each display. Only windows of the same app snap together "
                 + "while this mode is on; new windows join their app's cluster. "
                 + "Choosing a saved layout or display reflow turns the mode off. "
                 + "Turning it off leaves windows in place and restores normal "
                 + "magnet behavior.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(4)
    }
}

/// Bridges the coordinator's MagnetSettingsStore to SwiftUI.
final class MagnetsPreferencesModel: ObservableObject {
    @Published var mateReach = MagnetMating.defaultThreshold
    @Published var scaleGroupsOnResize = false
    @Published var autoClusterSameApp = false
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        // The window and this model are cached for the daemon's lifetime, so
        // without the hook the tab would freeze at whatever the store held
        // when it was first created (finding 16 corollary).
        coordinator.onMagnetSettingsChanged = { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        mateReach = coordinator.magnetSettings.mateReach
        scaleGroupsOnResize = coordinator.magnetSettings.scaleGroupsOnResize
        autoClusterSameApp = coordinator.magnetSettings.autoClusterSameApp
    }

    // Writes through the coordinator, whose hook fires reload — so this never
    // calls reload() itself. The model clamps, so the slider cannot ask for a
    // reach the gesture would refuse.
    func setMateReach(_ points: CGFloat) {
        coordinator.updateMagnetSettings { $0.mateReach = points }
    }

    func setScaleGroupsOnResize(_ enabled: Bool) {
        coordinator.updateMagnetSettings { $0.scaleGroupsOnResize = enabled }
    }

    func setAutoClusterSameApp(_ enabled: Bool) {
        coordinator.updateMagnetSettings { $0.autoClusterSameApp = enabled }
    }
}
