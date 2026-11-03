import SwiftUI
import FerriteCore

struct PowerPreferencesView: View {
    @ObservedObject var model: PowerPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Keep Mac Awake (Alpha)", isOn: Binding(
                get: { model.enabled }, set: { model.setEnabled($0) }))
            Text("Prevents idle system/display sleep, screen saver, idle lock/logout, "
                 + "and closed-lid sleep without an external display. AC power only; "
                 + "unplugging suspends the mode and reconnecting restores it.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Closed-lid support installs a privileged helper and temporarily uses "
                 + "a system-wide sleep override. Manual sleep can be blocked while active. "
                 + "Ferrite clears only the override it owns.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            LabeledContent("Status", value: model.stateText)
            Text(model.stateDetail).font(.caption).foregroundStyle(.secondary)
            if model.showsLoginWarning {
                Text("Launch at Login needs approval or registration. Current-session "
                     + "operation can continue, but reboot restoration is not guaranteed.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if case .error = model.state {
                Text("If cleanup fails, keep Ferrite open for automatic retries. Manual recovery: "
                     + "sudo pmset -a disablesleep 0")
                    .font(.caption).foregroundStyle(.red)
            }
            Button("Remove Privileged Helper…", action: model.uninstallHelper)
                .disabled(model.enabled)
            Spacer()
        }
        .padding(4)
        .onAppear { model.reload() }
    }
}

@MainActor
final class PowerPreferencesModel: ObservableObject {
    @Published var enabled = false
    @Published var state: KeepAwakeState = .off
    @Published var stateText = KeepAwakeState.off.displayText
    @Published var stateDetail = KeepAwakeState.off.detail
    @Published var showsLoginWarning = false
    private let controller: KeepAwakeController

    init(controller: KeepAwakeController) {
        self.controller = controller
        controller.onChange = { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func reload() {
        enabled = controller.desiredEnabled
        state = controller.state
        stateText = controller.state.displayText
        stateDetail = controller.state.detail
        showsLoginWarning = controller.showsLoginWarning
    }

    func setEnabled(_ enabled: Bool) { controller.setEnabled(enabled) }
    func uninstallHelper() { controller.uninstallHelper() }
}
