import AppKit
import SwiftUI
import FerriteCore

/// The one tunable in the magnet gesture: how far a window's edge reaches for
/// another's. The overlap gate is not exposed — it is what keeps mating from
/// being accidental, and loosening it would make the gesture untrustworthy.
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
            Text("Perpendicular alignment stays at a fixed 24 pt: below a "
                 + "24 pt reach, every mate also levels the perpendicular "
                 + "edges, because nothing can be near enough to mate yet too "
                 + "far to straighten.")
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
    }

    // Writes through the coordinator, whose hook fires reload — so this never
    // calls reload() itself. The model clamps, so the slider cannot ask for a
    // reach the gesture would refuse.
    func setMateReach(_ points: CGFloat) {
        coordinator.updateMagnetSettings { $0.mateReach = points }
    }
}
