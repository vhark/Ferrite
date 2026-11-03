import Foundation

public enum KeepAwakeState: Equatable {
    case off
    case waitingForAC
    case approvalNeeded(String)
    case active
    case error(String)

    public var displayText: String {
        switch self {
        case .off: return "Off"
        case .waitingForAC: return "Waiting for AC"
        case .approvalNeeded: return "Approval needed"
        case .active: return "Active"
        case .error: return "Error"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "Normal macOS sleep behavior."
        case .waitingForAC: return "Connect the power adapter to reactivate."
        case let .approvalNeeded(message), let .error(message): return message
        case .active: return "System, display, and closed-lid sleep are blocked on AC power."
        }
    }
}

/// All completion handlers run synchronously or asynchronously on the main queue.
public protocol KeepAwakeHelperClient: AnyObject {
    func enable(completion: @escaping (Result<Void, Error>) -> Void)
    func disable(completion: @escaping (Result<Void, Error>) -> Void)
    func status(completion: @escaping (Result<Bool, Error>) -> Void)
}

@MainActor
public protocol PowerAssertionControlling: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func activate() throws
    func deactivate()
}

public protocol KeepAwakeLoginItemControlling: AnyObject {
    var needsApproval: Bool { get }
    /// Returns true when macOS still requires user approval.
    func ensureRegistered() throws -> Bool
}

public enum KeepAwakeClientError: LocalizedError {
    case approvalNeeded(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .approvalNeeded(message), let .unavailable(message): return message
        }
    }
}

@MainActor
public final class KeepAwakeController {
    public private(set) var desiredEnabled = false
    public private(set) var state: KeepAwakeState = .off
    public private(set) var showsLoginWarning = false
    public var onChange: (() -> Void)?

    private let store: KeepAwakeSettingsStore
    private let powerSource: PowerSourceProviding
    private let helper: KeepAwakeHelperClient
    private let assertions: PowerAssertionControlling
    private let loginItem: KeepAwakeLoginItemControlling
    private var timer: Timer?
    private var running = false
    private var busy = false
    private var generation = 0
    private var cleanupState: KeepAwakeState?
    private var pendingCleanupState: KeepAwakeState?

    public init(store: KeepAwakeSettingsStore,
                powerSource: PowerSourceProviding,
                helper: KeepAwakeHelperClient,
                assertions: PowerAssertionControlling,
                loginItem: KeepAwakeLoginItemControlling) {
        self.store = store
        self.powerSource = powerSource
        self.helper = helper
        self.assertions = assertions
        self.loginItem = loginItem
        assertions.onFailure = { [weak self] message in
            self?.fail(message)
        }
    }

    public func start() {
        generation += 1
        guard !running else { return }
        running = true
        desiredEnabled = store.load().keepAwakeEnabled
        if desiredEnabled { registerLoginItem() }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        reconcile()
        emit()
    }

    public func stop() {
        generation += 1
        running = false
        timer?.invalidate()
        timer = nil
        assertions.deactivate()
        requestCleanup(.off)
    }

    public func setEnabled(_ enabled: Bool) {
        generation += 1
        desiredEnabled = enabled
        do {
            try store.save(KeepAwakeSettings(keepAwakeEnabled: enabled))
        } catch {
            state = .error("Could not save power preference: \(error.localizedDescription)")
            emit()
            return
        }
        if enabled {
            registerLoginItem()
            reconcile()
        } else {
            assertions.deactivate()
            state = .off
            requestCleanup(.off)
            emit()
        }
    }

    public func reconcile() {
        guard running else { return }
        let loginWarning = desiredEnabled && loginItem.needsApproval
        if showsLoginWarning != loginWarning {
            showsLoginWarning = loginWarning
            emit()
        }
        guard desiredEnabled else {
            if case .error = state { requestCleanup(.off) }
            return
        }
        guard powerSource.isOnAC else {
            if state != .waitingForAC {
                suspendForBattery()
            } else {
                requestCleanup(.waitingForAC)
            }
            return
        }
        pendingCleanupState = nil
        guard !busy else { return }
        switch state {
        case .active:
            let requestGeneration = generation
            helper.status { [weak self] result in
                guard let self, self.running, self.desiredEnabled,
                      self.generation == requestGeneration else { return }
                switch result {
                case .success(false): self.beginActivation()
                case .success(true): break
                case let .failure(error): self.fail(error.localizedDescription)
                }
            }
        case .off, .waitingForAC, .approvalNeeded:
            beginActivation()
        case .error:
            break
        }
    }

    private func beginActivation() {
        guard !busy else { return }
        generation += 1
        let activationGeneration = generation
        busy = true
        helper.enable { [weak self] result in
            guard let self else { return }
            self.busy = false
            guard self.generation == activationGeneration else {
                if !self.running || !self.desiredEnabled {
                    self.requestCleanup(.off)
                } else if !self.powerSource.isOnAC {
                    self.requestCleanup(.waitingForAC)
                }
                return
            }
            guard self.running, self.desiredEnabled else {
                self.requestCleanup(.off)
                return
            }
            guard self.powerSource.isOnAC else {
                self.suspendForBattery()
                return
            }
            switch result {
            case let .failure(error as KeepAwakeClientError):
                self.assertions.deactivate()
                if case let .approvalNeeded(message) = error {
                    self.state = .approvalNeeded(message)
                } else {
                    self.state = .error(error.localizedDescription)
                }
                self.requestCleanup(self.state)
            case let .failure(error):
                self.assertions.deactivate()
                self.state = .error(error.localizedDescription)
                self.requestCleanup(self.state)
            case .success:
                do {
                    try self.assertions.activate()
                    self.state = .active
                } catch {
                    self.assertions.deactivate()
                    self.state = .error(error.localizedDescription)
                    self.requestCleanup(self.state)
                }
            }
            self.emit()
        }
    }

    private func suspendForBattery() {
        generation += 1
        assertions.deactivate()
        state = .waitingForAC
        requestCleanup(.waitingForAC)
        emit()
    }

    private func requestCleanup(_ normalState: KeepAwakeState) {
        if let activeCleanup = cleanupState {
            if activeCleanup != normalState { pendingCleanupState = normalState }
            return
        }
        cleanupState = normalState
        let cleanupGeneration = generation
        helper.disable { [weak self] result in
            guard let self else { return }
            self.cleanupState = nil
            let pending = self.pendingCleanupState
            self.pendingCleanupState = nil
            self.handleCleanupResult(
                result, normalState: normalState, generation: cleanupGeneration)
            if let pending { self.requestCleanup(pending) }
        }
    }

    private func handleCleanupResult(_ result: Result<Void, Error>,
                                     normalState: KeepAwakeState,
                                     generation cleanupGeneration: Int) {
        guard generation == cleanupGeneration else { return }
        switch result {
        case .success: state = normalState
        case let .failure(error): state = .error(error.localizedDescription)
        }
        emit()
    }

    private func fail(_ message: String) {
        generation += 1
        assertions.deactivate()
        state = .error(message)
        requestCleanup(state)
        emit()
    }

    private func registerLoginItem() {
        do {
            showsLoginWarning = try loginItem.ensureRegistered()
        } catch {
            showsLoginWarning = true
        }
    }

    private func emit() { onChange?() }
}
