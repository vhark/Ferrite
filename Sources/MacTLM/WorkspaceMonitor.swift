import AppKit

/// App lifecycle (NSWorkspace) + per-app window events (AppObserver).
final class WorkspaceMonitor {
    private var observers: [pid_t: AppObserver] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    var onAppLaunched: ((String) -> Void)?
    var onAppTerminated: ((String) -> Void)?
    var onActivity: ((String) -> Void)?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                self?.attach(to: app)
                if let bundleID = app.bundleIdentifier {
                    self?.onAppLaunched?(bundleID)
                }
        })
        notificationTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                self?.observers.removeValue(forKey: app.processIdentifier)
                if let bundleID = app.bundleIdentifier {
                    self?.onAppTerminated?(bundleID)
                }
        })
        // Attach to everything already running.
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            attach(to: app)
        }
    }

    private func attach(to app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              observers[app.processIdentifier] == nil,
              let observer = AppObserver(app: app, onActivity: { [weak self] bundleID in
                  self?.onActivity?(bundleID)
              })
        else { return }
        observers[app.processIdentifier] = observer
        observer.kickstart()
    }
}
