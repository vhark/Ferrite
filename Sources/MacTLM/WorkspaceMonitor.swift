import AppKit

/// App lifecycle (NSWorkspace) + per-app window events (AppObserver).
final class WorkspaceMonitor {
    private var observers: [pid_t: AppObserver] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    var onAppLaunched: ((String) -> Void)?
    var onAppTerminated: ((String) -> Void)?
    var onActivity: ((String) -> Void)?
    /// Rich per-window events, for consumers that need to know *which*
    /// window changed and how. `onActivity` still fires for every one of them.
    var onWindowEvent: ((AppObserver.WindowEvent) -> Void)?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                // onAppLaunched must precede attach: attach() kickstarts a
                // synchronous activity event, and consumers may need to arm
                // routing state first.
                if let bundleID = app.bundleIdentifier {
                    self?.onAppLaunched?(bundleID)
                }
                self?.attach(to: app)
        })
        notificationTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                self?.forgetWindows(ofPID: app.processIdentifier)
                if let removed = self?.observers.removeValue(forKey: app.processIdentifier) {
                    self?.onAppTerminated?(removed.bundleID)
                }
        })
        // Attach to everything already running.
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            attach(to: app)
        }
    }

    deinit {
        notificationTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func attach(to app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              observers[app.processIdentifier] == nil else { return }
        guard let observer = makeObserver(for: app) else {
            NSLog("MacTLM: AX observer attach failed for %@, retrying once",
                  app.bundleIdentifier ?? "?")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.attachRetry(to: app)
            }
            return
        }
        observers[app.processIdentifier] = observer
        observer.kickstart()
    }

    /// One-shot retry: no further retries are scheduled on failure.
    private func attachRetry(to app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              !app.isTerminated,
              observers[app.processIdentifier] == nil else { return }
        guard let observer = makeObserver(for: app) else {
            NSLog("MacTLM: AX observer attach failed permanently for %@",
                  app.bundleIdentifier ?? "?")
            return
        }
        observers[app.processIdentifier] = observer
        observer.kickstart()
    }

    private func makeObserver(for app: NSRunningApplication) -> AppObserver? {
        AppObserver(app: app, onActivity: { [weak self] bundleID in
            self?.onActivity?(bundleID)
        }, onWindowEvent: { [weak self] event in
            self?.record(event)
        })
    }

    /// Last frame observed for each window, so features that need a "before"
    /// frame (resize propagation, drag sessions) have one without re-reading AX.
    private var lastEvents: [Int: AppObserver.WindowEvent] = [:]

    func lastKnownFrame(ofWindow windowID: Int) -> CGRect? {
        lastEvents[windowID]?.frame
    }

    private func record(_ event: AppObserver.WindowEvent) {
        lastEvents[event.windowID] = event
        onWindowEvent?(event)
    }

    /// AX window ids never come back after their process dies, so the cache is
    /// pruned per-app rather than growing for the life of the session.
    private func forgetWindows(ofPID pid: pid_t) {
        lastEvents = lastEvents.filter { $0.value.pid != pid }
    }
}
