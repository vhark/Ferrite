# Keep Mac Awake (Alpha) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an off-by-default Ferrite alpha mode that prevents idle sleep, display sleep, screen saver/lock/logout, and closed-lid sleep on AC power, with privileged cleanup and reboot restoration.

**Architecture:** `FerriteCore` owns persisted desired state, app lifecycle policy, and helper power-override policy. The Ferrite app owns IOKit assertions, a 30-second activity heartbeat, UI, and a C-XPC client. A root LaunchDaemon owns only fixed `pmset disablesleep` mutations, per-message code-signing validation, AC enforcement, and helper-owned cleanup.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, AppKit, SwiftUI, IOKit, ServiceManagement `SMAppService`, Security `SecCodeCreateWithXPCMessage`, C XPC, `pmset`.

**Approved spec:** `docs/superpowers/specs/2026-11-03-keep-mac-awake-design.md`.

**Implemented architecture amendment (2026-11-03):** The `SMAppService.daemon` helper-registration steps and Login Items helper-approval assumptions in this historical plan were replaced: the self-signed Ferrite Dev certificate has `TeamIdentifier=not set`, so `DirectLaunchDaemonInstaller` requests administrator approval for direct install/uninstall. It checks app/helper signatures, expected helper identity and shared non-ad-hoc certificate, and the exact plist schema (`Label`, installed `Program`, `FerriteHelperVersion=1`, `RunAtLoad=true`, `KeepAlive=true`, one true `MachServices` entry for the label). The root command stages the helper/plist, rechecks signature/CDHash and SHA-256 respectively, then cuts over transactionally, restoring previous files and loaded service on failed upgrade. Direct uninstall boots out the helper, clears recorded helper-owned override state, and removes both installed files. Unloaded-helper disable/status check actual `SleepDisabled`; reboot-on-AC and reboot-on-battery live cases remain deferred.

---

## File structure

| File | Responsibility |
|---|---|
| `Sources/FerriteCore/KeepAwakeSettingsStore.swift` | Persist only the user's desired enabled state. |
| `Sources/FerriteCore/SleepOverrideController.swift` | AC policy, `SleepDisabled` ownership, command verification, startup/unplug cleanup. |
| `Sources/FerriteCore/PowerSourceProviding.swift` | Power-source abstraction and real IOKit power-source reader. |
| `Sources/FerriteCore/KeepAwakeController.swift` | App lifecycle state machine shared by menu and Preferences. |
| `Sources/FerriteCore/KeepAwakeXPC.swift` | Closed operation vocabulary shared by app and helper. |
| `Sources/Ferrite/IOKitPowerAssertionController.swift` | Real system/display assertions and local-user-activity heartbeat. |
| `Sources/Ferrite/XpcKeepAwakeHelperClient.swift` | Daemon registration and asynchronous C-XPC requests. |
| `Sources/Ferrite/MainAppLoginItemController.swift` | Existing Launch at Login registration and approval reporting. |
| `Sources/Ferrite/PowerPreferencesView.swift` | Power tab and live error/approval states. |
| `Sources/FerriteKeepAwakeHelper/PmsetCommandRunner.swift` | Fixed `/usr/bin/pmset` runner with a 10-second timeout. |
| `Sources/FerriteKeepAwakeHelper/FileSleepOverrideOwnershipStore.swift` | Root-only helper ownership marker. |
| `Sources/FerriteKeepAwakeHelper/HelperMessageValidator.swift` | Per-message client signing identity validation. |
| `Sources/FerriteKeepAwakeHelper/KeepAwakeHelperDaemon.swift` | C-XPC listener, client lifecycle, AC polling, signal cleanup. |
| `Sources/FerriteKeepAwakeHelper/main.swift` | Helper composition root and run loop. |
| `Resources/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist` | LaunchDaemon label, executable, Mach service, boot/crash recovery. |
| `Tests/FerriteCoreTests/KeepAwakeSettingsStoreTests.swift` | Preference defaults and round trip. |
| `Tests/FerriteCoreTests/SleepOverrideControllerTests.swift` | Power override state transitions and failure recovery. |
| `Tests/FerriteCoreTests/KeepAwakeControllerTests.swift` | App activation, AC transitions, rollback, heartbeat failure, restart. |

### Task 1: Persist the alpha preference

**Files:**
- Create: `Sources/FerriteCore/KeepAwakeSettingsStore.swift`
- Create: `Tests/FerriteCoreTests/KeepAwakeSettingsStoreTests.swift`

- [ ] **Step 1: Write the failing preference tests**

```swift
import XCTest
@testable import FerriteCore

final class KeepAwakeSettingsStoreTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("power.json")
    }

    func testMissingFileDefaultsOff() throws {
        XCTAssertFalse(KeepAwakeSettingsStore(url: try temporaryURL()).load().keepAwakeEnabled)
    }

    func testEnabledPreferenceRoundTrips() throws {
        let store = KeepAwakeSettingsStore(url: try temporaryURL())
        try store.save(KeepAwakeSettings(keepAwakeEnabled: true))
        XCTAssertTrue(store.load().keepAwakeEnabled)
    }

    func testUnreadableFileFailsOff() throws {
        let url = try temporaryURL()
        try Data("not-json".utf8).write(to: url)
        XCTAssertFalse(KeepAwakeSettingsStore(url: url).load().keepAwakeEnabled)
    }
}
```

- [ ] **Step 2: Run the tests and confirm the missing type fails**

Run: `swift test --filter KeepAwakeSettingsStoreTests`
Expected: FAIL because `KeepAwakeSettingsStore` does not exist.

- [ ] **Step 3: Add the minimal absent-tolerant store**

```swift
import Foundation

public struct KeepAwakeSettings: Codable, Equatable {
    public var keepAwakeEnabled: Bool

    public init(keepAwakeEnabled: Bool = false) {
        self.keepAwakeEnabled = keepAwakeEnabled
    }
}

public final class KeepAwakeSettingsStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> KeepAwakeSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(KeepAwakeSettings.self, from: data)
        else { return KeepAwakeSettings() }
        return settings
    }

    public func save(_ settings: KeepAwakeSettings) throws {
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Verify the preference tests**

Run: `swift test --filter KeepAwakeSettingsStoreTests`
Expected: PASS, three tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/FerriteCore/KeepAwakeSettingsStore.swift Tests/FerriteCoreTests/KeepAwakeSettingsStoreTests.swift
git commit -m "feat(power): persist keep awake preference"
```

### Task 2: Implement the testable closed-lid override policy

**Files:**
- Create: `Sources/FerriteCore/PowerSourceProviding.swift`
- Create: `Sources/FerriteCore/SleepOverrideController.swift`
- Create: `Tests/FerriteCoreTests/SleepOverrideControllerTests.swift`

- [ ] **Step 1: Write failing tests for AC, ownership, cleanup, and rollback**

```swift
import XCTest
@testable import FerriteCore

private struct FakePowerResult: Error { let message: String }

private final class FakePmset: SleepOverrideCommandRunning {
    var sleepDisabled = false
    var failure: FakePowerResult?
    private(set) var mutations: [Bool] = []

    func run(_ arguments: [String]) throws -> PowerCommandResult {
        if let failure { throw failure }
        if arguments == ["-g"] {
            return PowerCommandResult(
                exitCode: 0,
                output: "System-wide power settings:\n SleepDisabled\t\t\(sleepDisabled ? 1 : 0)\n")
        }
        guard arguments == ["-a", "disablesleep", "0"]
                || arguments == ["-a", "disablesleep", "1"] else {
            return PowerCommandResult(exitCode: 64, output: "unexpected arguments")
        }
        sleepDisabled = arguments.last == "1"
        mutations.append(sleepDisabled)
        return PowerCommandResult(exitCode: 0, output: "")
    }
}

private final class FakePowerSource: PowerSourceProviding {
    var isOnAC: Bool
    init(isOnAC: Bool) { self.isOnAC = isOnAC }
}

private final class FakeOwnership: SleepOverrideOwnershipStoring {
    var owned = false
    func load() throws -> Bool { owned }
    func save(_ owned: Bool) throws { self.owned = owned }
}

final class SleepOverrideControllerTests: XCTestCase {
    private func makeFixture(ac: Bool = true) -> (
        FakePmset, FakePowerSource, FakeOwnership, SleepOverrideController
    ) {
        let pmset = FakePmset()
        let power = FakePowerSource(isOnAC: ac)
        let ownership = FakeOwnership()
        return (pmset, power, ownership,
                SleepOverrideController(runner: pmset, powerSource: power, ownership: ownership))
    }

    func testBatteryActivationDoesNotMutatePower() throws {
        let (pmset, _, ownership, controller) = makeFixture(ac: false)
        XCTAssertThrowsError(try controller.enable()) { error in
            XCTAssertEqual(error as? SleepOverrideError, .notOnAC)
        }
        XCTAssertTrue(pmset.mutations.isEmpty)
        XCTAssertFalse(ownership.owned)
    }

    func testActivationOwnsOnlyItsOwnOverride() throws {
        let (pmset, _, ownership, controller) = makeFixture()
        try controller.enable()
        XCTAssertTrue(pmset.sleepDisabled)
        XCTAssertTrue(ownership.owned)
        try controller.enable()
        XCTAssertEqual(pmset.mutations, [true])
    }

    func testExternalOverrideIsNotAdoptedOrCleared() throws {
        let (pmset, _, ownership, controller) = makeFixture()
        pmset.sleepDisabled = true
        XCTAssertThrowsError(try controller.enable()) { error in
            XCTAssertEqual(error as? SleepOverrideError, .externalOverride)
        }
        try controller.disable()
        try controller.recoverAtStartup()
        XCTAssertTrue(pmset.sleepDisabled)
        XCTAssertFalse(ownership.owned)
        XCTAssertTrue(pmset.mutations.isEmpty)
    }

    func testStartupAndACLossCleanOwnedState() throws {
        let (pmset, power, ownership, controller) = makeFixture()
        try controller.enable()
        power.isOnAC = false
        try controller.powerSourceChanged()
        XCTAssertFalse(pmset.sleepDisabled)
        XCTAssertFalse(ownership.owned)

        power.isOnAC = true
        try controller.enable()
        try controller.recoverAtStartup()
        XCTAssertFalse(pmset.sleepDisabled)
        XCTAssertFalse(ownership.owned)
    }

    func testFailedDisableRetainsOwnershipForRetry() throws {
        let (pmset, _, ownership, controller) = makeFixture()
        try controller.enable()
        pmset.failure = FakePowerResult(message: "injected")
        XCTAssertThrowsError(try controller.disable())
        XCTAssertTrue(ownership.owned)
        XCTAssertTrue(pmset.sleepDisabled)
        pmset.failure = nil
        try controller.disable()
        XCTAssertFalse(ownership.owned)
        XCTAssertFalse(pmset.sleepDisabled)
    }
}
```

- [ ] **Step 2: Run the tests and confirm the missing policy fails**

Run: `swift test --filter SleepOverrideControllerTests`
Expected: FAIL because the power-override types do not exist.

- [ ] **Step 3: Add the power-source abstraction**

```swift
import Foundation
import IOKit

public protocol PowerSourceProviding: AnyObject {
    var isOnAC: Bool { get }
}

public final class SystemPowerSource: PowerSourceProviding {
    public init() {}

    public var isOnAC: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo() else { return false }
        let source = IOPSGetProvidingPowerSourceType(snapshot)
        return source as String == "AC Power"
    }
}
```

`SystemPowerSource` fails closed: an unreadable power source is treated as battery.

- [ ] **Step 4: Add the verified ownership policy**

```swift
import Foundation

public struct PowerCommandResult: Equatable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol SleepOverrideCommandRunning: AnyObject {
    func run(_ arguments: [String]) throws -> PowerCommandResult
}

public protocol SleepOverrideOwnershipStoring: AnyObject {
    func load() throws -> Bool
    func save(_ owned: Bool) throws
}

public enum SleepOverrideError: Error, Equatable, LocalizedError {
    case notOnAC
    case externalOverride
    case commandFailed(Int32, String)
    case stateMismatch(expected: Bool)

    public var errorDescription: String? {
        switch self {
        case .notOnAC:
            return "Keep Mac Awake requires AC power."
        case .externalOverride:
            return "Another tool already controls SleepDisabled; Ferrite will not adopt or clear it."
        case let .commandFailed(code, output):
            return "pmset failed with exit code \(code): \(output)"
        case let .stateMismatch(expected):
            return "SleepDisabled did not reach the expected value \(expected ? 1 : 0)."
        }
    }
}

public final class SleepOverrideController {
    private let runner: SleepOverrideCommandRunning
    private let powerSource: PowerSourceProviding
    private let ownership: SleepOverrideOwnershipStoring

    public init(runner: SleepOverrideCommandRunning,
                powerSource: PowerSourceProviding,
                ownership: SleepOverrideOwnershipStoring) {
        self.runner = runner
        self.powerSource = powerSource
        self.ownership = ownership
    }

    public var needsCleanup: Bool {
        (try? ownership.load()) ?? true
    }

    public func status() throws -> Bool {
        try querySleepDisabled()
    }

    public func recoverAtStartup() throws {
        try disable()
    }

    public func enable() throws {
        guard powerSource.isOnAC else { throw SleepOverrideError.notOnAC }
        if try querySleepDisabled() {
            if try ownership.load() { return }
            throw SleepOverrideError.externalOverride
        }
        do {
            try runChecked(["-a", "disablesleep", "1"])
            guard try querySleepDisabled() else {
                throw SleepOverrideError.stateMismatch(expected: true)
            }
            try ownership.save(true)
        } catch {
            try? runChecked(["-a", "disablesleep", "0"])
            throw error
        }
    }

    public func disable() throws {
        guard try ownership.load() else { return }
        try runChecked(["-a", "disablesleep", "0"])
        guard try !querySleepDisabled() else {
            throw SleepOverrideError.stateMismatch(expected: false)
        }
        try ownership.save(false)
    }

    public func powerSourceChanged() throws {
        if !powerSource.isOnAC { try disable() }
    }

    private func querySleepDisabled() throws -> Bool {
        let result = try runChecked(["-g"])
        for line in result.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return false
    }

    @discardableResult
    private func runChecked(_ arguments: [String]) throws -> PowerCommandResult {
        let result = try runner.run(arguments)
        guard result.exitCode == 0 else {
            throw SleepOverrideError.commandFailed(result.exitCode, result.output)
        }
        return result
    }
}
```

The test runner and production runner are both confined to this policy's three argument lists. No XPC caller can supply arguments.

- [ ] **Step 5: Run the policy tests**

Run: `swift test --filter SleepOverrideControllerTests`
Expected: PASS, five tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/FerriteCore/PowerSourceProviding.swift Sources/FerriteCore/SleepOverrideController.swift Tests/FerriteCoreTests/SleepOverrideControllerTests.swift
git commit -m "feat(power): add owned sleep override policy"
```

### Task 3: Implement the app lifecycle controller

**Files:**
- Create: `Sources/FerriteCore/KeepAwakeController.swift`
- Create: `Tests/FerriteCoreTests/KeepAwakeControllerTests.swift`

- [ ] **Step 1: Write failing lifecycle tests**

```swift
import XCTest
@testable import FerriteCore

private struct InjectedKeepAwakeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class FakeHelperClient: KeepAwakeHelperClient {
    var enabled = false
    var failure: Error?
    private(set) var disableCount = 0

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        if let failure { completion(.failure(failure)) }
        else { enabled = true; completion(.success(())) }
    }

    func disable(completion: @escaping (Result<Void, Error>) -> Void) {
        disableCount += 1
        enabled = false
        if let failure { completion(.failure(failure)) }
        else { completion(.success(())) }
    }

    func status(completion: @escaping (Result<Bool, Error>) -> Void) {
        if let failure { completion(.failure(failure)) }
        else { completion(.success(enabled)) }
    }
}

private final class FakeAssertions: PowerAssertionControlling {
    var active = false
    var activationCount = 0
    var failure: Error?
    var onFailure: ((String) -> Void)?

    func activate() throws {
        if let failure { throw failure }
        if !active { activationCount += 1 }
        active = true
    }

    func deactivate() { active = false }
}

private final class FakeLoginItem: KeepAwakeLoginItemControlling {
    var needsApproval = false
    func ensureRegistered() throws -> Bool { needsApproval }
}

private final class MutablePowerSource: PowerSourceProviding {
    var isOnAC: Bool
    init(isOnAC: Bool) { self.isOnAC = isOnAC }
}

@MainActor
final class KeepAwakeControllerTests: XCTestCase {
    private var directory: URL!
    private var helper: FakeHelperClient!
    private var assertions: FakeAssertions!
    private var power: MutablePowerSource!
    private var login: FakeLoginItem!
    private var controller: KeepAwakeController!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        helper = FakeHelperClient()
        assertions = FakeAssertions()
        power = MutablePowerSource(isOnAC: true)
        login = FakeLoginItem()
        controller = KeepAwakeController(
            store: KeepAwakeSettingsStore(url: directory.appendingPathComponent("power.json")),
            powerSource: power, helper: helper, assertions: assertions, loginItem: login)
    }

    override func tearDown() async throws {
        controller.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func testEnableActivatesHelperAssertionsAndLoginWarning() {
        login.needsApproval = true
        controller.start()
        controller.setEnabled(true)
        XCTAssertTrue(helper.enabled)
        XCTAssertTrue(assertions.active)
        XCTAssertEqual(controller.state, .active)
        XCTAssertTrue(controller.showsLoginWarning)
    }

    func testACLossSuspendsAndReconnectRestores() {
        controller.start()
        controller.setEnabled(true)
        power.isOnAC = false
        controller.reconcile()
        XCTAssertFalse(assertions.active)
        XCTAssertFalse(helper.enabled)
        XCTAssertEqual(controller.state, .waitingForAC)
        XCTAssertTrue(controller.desiredEnabled)
        power.isOnAC = true
        controller.reconcile()
        XCTAssertEqual(controller.state, .active)
        XCTAssertTrue(assertions.active)
    }

    func testAssertionFailureRollsBackHelper() {
        assertions.failure = InjectedKeepAwakeError(message: "assertion failed")
        controller.start()
        controller.setEnabled(true)
        XCTAssertFalse(helper.enabled)
        XCTAssertFalse(assertions.active)
        XCTAssertEqual(controller.state, .error("assertion failed"))
    }

    func testHeartbeatFailureIsNotReportedActive() {
        controller.start()
        controller.setEnabled(true)
        assertions.onFailure?("activity failed")
        XCTAssertEqual(controller.state, .error("activity failed"))
        XCTAssertFalse(assertions.active)
        XCTAssertFalse(helper.enabled)
    }

    func testHelperRestartReconcilesWithoutDuplicateAssertions() {
        controller.start()
        controller.setEnabled(true)
        helper.enabled = false
        controller.reconcile()
        XCTAssertTrue(helper.enabled)
        XCTAssertTrue(assertions.active)
        XCTAssertEqual(assertions.activationCount, 1)
    }

    func testDisableClearsPreferenceAndStopPreservesIt() {
        controller.start()
        controller.setEnabled(true)
        controller.stop()
        controller.start()
        XCTAssertEqual(controller.state, .active)
        controller.setEnabled(false)
        XCTAssertFalse(controller.desiredEnabled)
        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(assertions.active)
        XCTAssertFalse(helper.enabled)
    }
}
```

- [ ] **Step 2: Run the tests and confirm the missing controller fails**

Run: `swift test --filter KeepAwakeControllerTests`
Expected: FAIL because `KeepAwakeController` and its protocols do not exist.

- [ ] **Step 3: Add the state machine**

```swift
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
        guard !running else { return }
        running = true
        desiredEnabled = store.load().keepAwakeEnabled
        if desiredEnabled { registerLoginItem() }
        timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        reconcile()
        emit()
    }

    public func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        assertions.deactivate()
        helper.disable { _ in }
    }

    public func setEnabled(_ enabled: Bool) {
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
            helper.disable { [weak self] result in
                self?.handleCleanupResult(result, normalState: .off)
            }
            emit()
        }
    }

    public func reconcile() {
        guard running, !busy else { return }
        let loginWarning = desiredEnabled && loginItem.needsApproval
        if showsLoginWarning != loginWarning {
            showsLoginWarning = loginWarning
            emit()
        }
        guard desiredEnabled else {
            if case .error = state {
                assertions.deactivate()
                helper.disable { [weak self] result in
                    self?.handleCleanupResult(result, normalState: .off)
                }
            }
            return
        }
        guard powerSource.isOnAC else {
            suspendForBattery()
            return
        }
        switch state {
        case .active:
            helper.status { [weak self] result in
                guard let self, self.running, self.desiredEnabled else { return }
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
        busy = true
        helper.enable { [weak self] result in
            guard let self else { return }
            self.busy = false
            guard self.running, self.desiredEnabled else {
                self.helper.disable { _ in }
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
            case let .failure(error):
                self.assertions.deactivate()
                self.state = .error(error.localizedDescription)
            case .success:
                do {
                    try self.assertions.activate()
                    self.state = .active
                } catch {
                    self.assertions.deactivate()
                    self.helper.disable { _ in }
                    self.state = .error(error.localizedDescription)
                }
            }
            self.emit()
        }
    }

    private func suspendForBattery() {
        assertions.deactivate()
        state = .waitingForAC
        helper.disable { [weak self] result in
            self?.handleCleanupResult(result, normalState: .waitingForAC)
        }
        emit()
    }

    private func handleCleanupResult(_ result: Result<Void, Error>, normalState: KeepAwakeState) {
        switch result {
        case .success: state = normalState
        case let .failure(error): state = .error(error.localizedDescription)
        }
        emit()
    }

    private func fail(_ message: String) {
        assertions.deactivate()
        helper.disable { _ in }
        state = .error(message)
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
```

- [ ] **Step 4: Verify lifecycle behavior**

Run: `swift test --filter KeepAwakeControllerTests`
Expected: PASS, six tests. Completion handlers in production must return on the main queue; tests complete synchronously on the main actor.

- [ ] **Step 5: Commit**

```bash
git add Sources/FerriteCore/KeepAwakeController.swift Tests/FerriteCoreTests/KeepAwakeControllerTests.swift
git commit -m "feat(power): add keep awake lifecycle controller"
```

### Task 4: Add real IOKit assertions and the activity heartbeat

**Files:**
- Create: `Sources/Ferrite/IOKitPowerAssertionController.swift`

- [ ] **Step 1: Add the real assertion provider**

```swift
import Foundation
import IOKit
import FerriteCore

@MainActor
final class IOKitPowerAssertionController: PowerAssertionControlling {
    var onFailure: ((String) -> Void)?
    private var systemAssertion = IOPMAssertionID(0)
    private var displayAssertion = IOPMAssertionID(0)
    private var activityAssertion = IOPMAssertionID(0)
    private var heartbeat: Timer?
    private let reason = "Ferrite Keep Mac Awake" as CFString

    func activate() throws {
        guard systemAssertion == 0 else { return }
        var newSystem = IOPMAssertionID(0)
        var newDisplay = IOPMAssertionID(0)
        var newActivity = IOPMAssertionID(0)
        do {
            try check(IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep,
                kIOPMAssertionLevelOn, reason, &newSystem), operation: "system sleep assertion")
            try check(IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep,
                kIOPMAssertionLevelOn, reason, &newDisplay), operation: "display sleep assertion")
            try check(IOPMAssertionDeclareUserActivity(
                reason, kIOPMUserActiveLocal, &newActivity), operation: "user activity")
        } catch {
            release(newSystem)
            release(newDisplay)
            release(newActivity)
            throw error
        }
        systemAssertion = newSystem
        displayAssertion = newDisplay
        activityAssertion = newActivity
        heartbeat = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.declareActivity() }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
    }

    func deactivate() {
        heartbeat?.invalidate()
        heartbeat = nil
        release(systemAssertion)
        release(displayAssertion)
        release(activityAssertion)
        systemAssertion = 0
        displayAssertion = 0
        activityAssertion = 0
    }

    private func declareActivity() {
        var next = activityAssertion
        let result = IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &next)
        guard result == kIOReturnSuccess else {
            onFailure?("User activity declaration failed with IOReturn \(result).")
            return
        }
        if next != activityAssertion { release(activityAssertion) }
        activityAssertion = next
    }

    private func release(_ assertion: IOPMAssertionID) {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
    }

    private func check(_ result: IOReturn, operation: String) throws {
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "FerriteKeepAwake", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed with IOReturn \(result)."
            ])
        }
    }
}
```

Activation is idempotent. Partial creation releases every new ID. Heartbeat failure reaches `KeepAwakeController.fail` instead of leaving stale **Active** UI.

- [ ] **Step 2: Compile the provider and all core tests**

Run: `swift build --target Ferrite && swift test`
Expected: build succeeds; all existing and new tests pass. This does not activate real assertions.

- [ ] **Step 3: Commit**

```bash
git add Sources/Ferrite/IOKitPowerAssertionController.swift
git commit -m "feat(power): hold IOKit sleep assertions"
```

### Task 5: Add the privileged helper and per-message signing validation

**Files:**
- Modify: `Package.swift`
- Create: `Sources/FerriteCore/KeepAwakeXPC.swift`
- Create: `Sources/FerriteKeepAwakeHelper/PmsetCommandRunner.swift`
- Create: `Sources/FerriteKeepAwakeHelper/FileSleepOverrideOwnershipStore.swift`
- Create: `Sources/FerriteKeepAwakeHelper/HelperMessageValidator.swift`
- Create: `Sources/FerriteKeepAwakeHelper/KeepAwakeHelperDaemon.swift`
- Create: `Sources/FerriteKeepAwakeHelper/main.swift`
- Create: `Resources/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist`

- [ ] **Step 1: Add the helper target and closed XPC vocabulary**

Add this executable target beside the existing Ferrite target in `Package.swift`:

```swift
.executableTarget(
    name: "FerriteKeepAwakeHelper",
    dependencies: ["FerriteCore"]),
```

Create `Sources/FerriteCore/KeepAwakeXPC.swift`:

```swift
import Foundation
import Security

public enum KeepAwakeXPC {
    public static let serviceName = "dev.ferrite.Ferrite.KeepAwakeHelper"
    public static let daemonPlistName = "dev.ferrite.Ferrite.KeepAwakeHelper.plist"
    public static let applicationIdentifier = "dev.ferrite.Ferrite"

    public static let operation = "operation"
    public static let enable = "enable"
    public static let disable = "disable"
    public static let status = "status"
    public static let enabled = "enabled"
    public static let error = "error"
}
```

- [ ] **Step 2: Add the fixed command runner**

```swift
import Foundation
import FerriteCore

final class PmsetCommandRunner: SleepOverrideCommandRunning {
    func run(_ arguments: [String]) throws -> PowerCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 10) == .success else {
            if process.isRunning { process.terminate() }
            throw NSError(domain: "FerriteKeepAwakeHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "pmset timed out after 10 seconds."
            ])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return PowerCommandResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }
}
```

- [ ] **Step 3: Add the root-only ownership marker**

```swift
import Foundation
import FerriteCore

final class FileSleepOverrideOwnershipStore: SleepOverrideOwnershipStoring {
    private let url = URL(fileURLWithPath:
        "/private/var/db/dev.ferrite.Ferrite.keep-awake-owned")

    func load() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try Data(contentsOf: url) == Data([1])
    }

    func save(_ owned: Bool) throws {
        if owned {
            try Data([1]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
```

- [ ] **Step 4: Add per-message code-signing validation**

```swift
import Foundation
import Security
import XPC
import FerriteCore

final class HelperMessageValidator {
    private let helperCertificate: SecCertificate

    init?() {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              let info = Self.signingInformation(staticCode),
              let certificates = info[KeepAwakeXPC.certificates] as? [SecCertificate],
              let certificate = certificates.first else { return nil }
        helperCertificate = certificate
    }

    func accepts(_ message: xpc_object_t) -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCreateWithXPCMessage(message, [], &code) == errSecSuccess,
              let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              let info = Self.signingInformation(staticCode),
              info[KeepAwakeXPC.identifier] as? String == KeepAwakeXPC.applicationIdentifier,
              let certificates = info[KeepAwakeXPC.certificates] as? [SecCertificate],
              let clientCertificate = certificates.first else { return false }
        return SecCertificateCopyData(clientCertificate) as Data
            == SecCertificateCopyData(helperCertificate) as Data
    }

    private static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}
```

Add these constants to `KeepAwakeXPC` in the same edit:

```swift
public static let identifier = kSecCodeInfoIdentifier as String
public static let certificates = kSecCodeInfoCertificates as String
```

This rejects ad-hoc clients and ad-hoc helpers. Development and release builds must use the same non-ad-hoc certificate for app and helper; the existing `Ferrite Dev` identity satisfies that requirement.

- [ ] **Step 5: Add the XPC listener, client cleanup, AC polling, and SIGTERM cleanup**

```swift
import Foundation
import XPC
import FerriteCore

final class KeepAwakeHelperDaemon {
    private let queue = DispatchQueue(label: "dev.ferrite.Ferrite.KeepAwakeHelper")
    private let controller: SleepOverrideController
    private let powerSource: PowerSourceProviding
    private let validator: HelperMessageValidator?
    private var listener: xpc_connection_t?
    private var clients: Set<ObjectIdentifier> = []
    private var lastError: String?
    private var timer: Timer?
    private var sigterm: DispatchSourceSignal?

    init(controller: SleepOverrideController,
         powerSource: PowerSourceProviding,
         validator: HelperMessageValidator?) {
        self.controller = controller
        self.powerSource = powerSource
        self.validator = validator
    }

    func start() {
        queue.sync {
            do { try controller.recoverAtStartup(); lastError = nil }
            catch { lastError = error.localizedDescription }
        }
        let listener = xpc_connection_create_mach_service(
            KeepAwakeXPC.serviceName, queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION,
                  let connection = event as? xpc_connection_t else { return }
            self?.accept(connection)
        }
        xpc_connection_resume(listener)
        self.listener = listener
        timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.queue.async { self?.reconcileSafety() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        installSIGTERMHandler()
    }

    private func accept(_ connection: xpc_connection_t) {
        let id = ObjectIdentifier(connection)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard let self else { return }
            let type = xpc_get_type(event)
            if type == XPC_TYPE_DICTIONARY {
                self.handle(event, connection: connection, id: id)
            } else if type == XPC_TYPE_ERROR {
                self.clients.remove(id)
                if self.clients.isEmpty { self.cleanup() }
            }
        }
        xpc_connection_resume(connection)
    }

    private func handle(_ message: xpc_object_t,
                        connection: xpc_connection_t,
                        id: ObjectIdentifier) {
        guard validator?.accepts(message) == true else {
            reply(to: connection, enabled: nil, error:
                "Client signing identity rejected; app and helper must share a non-ad-hoc certificate.")
            xpc_connection_cancel(connection)
            return
        }
        clients.insert(id)
        guard let raw = xpc_dictionary_get_string(message, KeepAwakeXPC.operation) else {
            reply(to: connection, enabled: nil, error: "Missing operation.")
            return
        }
        let operation = String(cString: raw)
        do {
            switch operation {
            case KeepAwakeXPC.enable:
                try controller.enable()
                lastError = nil
                reply(to: connection, enabled: true, error: lastError)
            case KeepAwakeXPC.disable:
                try controller.disable()
                lastError = nil
                reply(to: connection, enabled: false, error: nil)
            case KeepAwakeXPC.status:
                let enabled = try controller.status()
                reply(to: connection, enabled: enabled, error: lastError)
            default:
                reply(to: connection, enabled: nil, error: "Unknown operation.")
            }
        } catch {
            lastError = error.localizedDescription
            reply(to: connection, enabled: nil, error: lastError)
        }
    }

    private func reply(to connection: xpc_connection_t,
                       enabled: Bool?, error: String?) {
        let reply = xpc_dictionary_create(nil, nil, 0)
        if let enabled { xpc_dictionary_set_bool(reply, KeepAwakeXPC.enabled, enabled) }
        if let error {
            error.withCString { xpc_dictionary_set_string(reply, KeepAwakeXPC.error, $0) }
        }
        xpc_connection_send_message(connection, reply)
    }

    private func reconcileSafety() {
        if !powerSource.isOnAC || (lastError != nil && controller.needsCleanup) {
            cleanup()
        }
    }

    private func cleanup() {
        do { try controller.disable(); lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    private func installSIGTERMHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.queue.sync { self.cleanup() }
            exit(0)
        }
        source.resume()
        sigterm = source
    }
}
```

The helper validates every message using `SecCodeCreateWithXPCMessage`; it does not use the private `NSXPCConnection.auditToken` property or a reusable PID. Only a connection that passed validation joins `clients`. When the last validated client disconnects, the helper releases only helper-owned state.

- [ ] **Step 6: Add the helper composition root**

```swift
import Foundation
import FerriteCore

let powerSource = SystemPowerSource()
let controller = SleepOverrideController(
    runner: PmsetCommandRunner(),
    powerSource: powerSource,
    ownership: FileSleepOverrideOwnershipStore())
let daemon = KeepAwakeHelperDaemon(
    controller: controller,
    powerSource: powerSource,
    validator: HelperMessageValidator())
daemon.start()
RunLoop.main.run()
```

- [ ] **Step 7: Add the LaunchDaemon plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.ferrite.Ferrite.KeepAwakeHelper</string>
  <key>BundleProgram</key><string>Contents/MacOS/FerriteKeepAwakeHelper</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>MachServices</key>
  <dict><key>dev.ferrite.Ferrite.KeepAwakeHelper</key><true/></dict>
</dict>
</plist>
```

- [ ] **Step 8: Compile without registering the daemon**

Run: `plutil -lint Resources/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist && swift build --target FerriteKeepAwakeHelper && swift test`
Expected: plist valid, helper builds, tests pass. Do not register or execute the root helper in this task.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/FerriteCore/KeepAwakeXPC.swift Sources/FerriteKeepAwakeHelper Resources/LaunchDaemons
git commit -m "feat(power): add signed closed lid helper"
```

### Task 6: Add the app XPC client and Launch at Login adapter

**Files:**
- Create: `Sources/Ferrite/XpcKeepAwakeHelperClient.swift`
- Create: `Sources/Ferrite/MainAppLoginItemController.swift`

- [ ] **Step 1: Add the daemon client**

```swift
import Foundation
import ServiceManagement
import XPC
import FerriteCore

final class XpcKeepAwakeHelperClient: KeepAwakeHelperClient {
    private let queue = DispatchQueue(label: "dev.ferrite.Ferrite.KeepAwakeClient")
    private var connection: xpc_connection_t?
    private let service = SMAppService.daemon(plistName: KeepAwakeXPC.daemonPlistName)

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try registerIfNeeded()
            request(KeepAwakeXPC.enable) { result in
                switch result {
                case let .failure(error): completion(.failure(error))
                case .success: completion(.success(()))
                }
            }
        } catch { completion(.failure(error)) }
    }

    func disable(completion: @escaping (Result<Void, Error>) -> Void) {
        guard service.status != .notRegistered else { completion(.success(())); return }
        request(KeepAwakeXPC.disable) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case .success: completion(.success(()))
            }
        }
    }

    func status(completion: @escaping (Result<Bool, Error>) -> Void) {
        guard service.status != .notRegistered else { completion(.success(false)); return }
        request(KeepAwakeXPC.status) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(message):
                if let error = self.errorString(message) {
                    completion(.failure(KeepAwakeClientError.unavailable(error)))
                } else {
                    completion(.success(xpc_dictionary_get_bool(message, KeepAwakeXPC.enabled)))
                }
            }
        }
    }

    private func registerIfNeeded() throws {
        if service.status == .notRegistered { try service.register() }
        switch service.status {
        case .enabled: return
        case .requiresApproval:
            throw KeepAwakeClientError.approvalNeeded(
                "Approve Ferrite's privileged helper in System Settings → General → Login Items.")
        case .notRegistered:
            throw KeepAwakeClientError.approvalNeeded("The privileged helper is not registered.")
        case .notFound:
            throw KeepAwakeClientError.unavailable("The privileged helper is missing from Ferrite.app.")
        @unknown default:
            throw KeepAwakeClientError.unavailable("The privileged helper state is unknown.")
        }
    }

    private func request(_ operation: String,
                         retryOnDisconnect: Bool = true,
                         completion: @escaping (Result<xpc_object_t, Error>) -> Void) {
        queue.async {
            let connection = self.makeConnection()
            let message = xpc_dictionary_create(nil, nil, 0)
            operation.withCString { xpc_dictionary_set_string(message, KeepAwakeXPC.operation, $0) }
            xpc_connection_send_message_with_reply(connection, message, self.queue) { reply in
                if xpc_get_type(reply) == XPC_TYPE_ERROR {
                    let description = String(cString: xpc_dictionary_get_string(
                        reply, XPC_ERROR_KEY_DESCRIPTION))
                    if retryOnDisconnect {
                        self.connection = nil
                        self.queue.asyncAfter(deadline: .now() + 0.5) {
                            self.request(operation, retryOnDisconnect: false, completion: completion)
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(.failure(KeepAwakeClientError.unavailable(description)))
                        }
                    }
                    return
                }
                if let error = self.errorString(reply) {
                    DispatchQueue.main.async {
                        completion(.failure(KeepAwakeClientError.unavailable(error)))
                    }
                } else {
                    DispatchQueue.main.async { completion(.success(reply)) }
                }
            }
        }
    }

    private func makeConnection() -> xpc_connection_t {
        if let connection { return connection }
        let connection = xpc_connection_create_mach_service(KeepAwakeXPC.serviceName, queue, 0)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self?.connection = nil
            }
        }
        xpc_connection_resume(connection)
        self.connection = connection
        return connection
    }

    private func errorString(_ message: xpc_object_t) -> String? {
        guard let value = xpc_dictionary_get_string(message, KeepAwakeXPC.error) else { return nil }
        return String(cString: value)
    }
}
```

- [ ] **Step 2: Add the main-app login adapter**

```swift
import ServiceManagement
import FerriteCore

final class MainAppLoginItemController: KeepAwakeLoginItemControlling {
    var needsApproval: Bool { SMAppService.mainApp.status != .enabled }

    func ensureRegistered() throws -> Bool {
        let service = SMAppService.mainApp
        if service.status == .notRegistered { try service.register() }
        return service.status != .enabled
    }
}
```

- [ ] **Step 3: Compile the client without connecting**

Run: `swift build --target Ferrite && swift test`
Expected: build and tests pass. No daemon registration occurs during compilation.

- [ ] **Step 4: Commit**

```bash
git add Sources/Ferrite/XpcKeepAwakeHelperClient.swift Sources/Ferrite/MainAppLoginItemController.swift
git commit -m "feat(power): connect app to privileged helper"
```

### Task 7: Package and sign the nested helper

**Files:**
- Modify: `scripts/make-app.sh`
- Modify: `scripts/release.sh`

- [ ] **Step 1: Add helper binary and plist packaging**

Immediately after copying the main Ferrite executable and before creating `Info.plist`, add:

```bash
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp "$PRODUCTS/FerriteKeepAwakeHelper" "$APP/Contents/MacOS/FerriteKeepAwakeHelper"
cp Resources/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist \
  "$APP/Contents/Library/LaunchDaemons/"
```

Both `swift build` branches already build all package products, so no additional build command is needed.

- [ ] **Step 2: Sign the helper before the app**

Replace the final identity-selection block with this equivalent flow:

```bash
HELPER="$APP/Contents/MacOS/FerriteKeepAwakeHelper"
if [ -n "$IDENTITY" ]; then
  SIGN_IDENTITY="$IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Ferrite Dev"; then
  SIGN_IDENTITY="Ferrite Dev"
else
  SIGN_IDENTITY="-"
fi
sign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$HELPER"
sign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP (version $VERSION)"
```

Ad-hoc signing still produces a runnable window-management build, but Keep Awake will reject it with the explicit certificate error. Live Keep Awake verification must use `Ferrite Dev` or a Developer ID certificate.

- [ ] **Step 3: Verify nested signatures in the release script**

Immediately after the existing `codesign --verify --strict --deep "$APP"`, add:

```bash
codesign --verify --strict "$APP/Contents/MacOS/FerriteKeepAwakeHelper"
plutil -lint "$APP/Contents/Library/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist"
```

- [ ] **Step 4: Build and inspect the packaged app**

Run:

```bash
./scripts/make-app.sh
codesign --verify --strict build/Ferrite.app/Contents/MacOS/FerriteKeepAwakeHelper
codesign --verify --strict --deep build/Ferrite.app
plutil -lint build/Ferrite.app/Contents/Library/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist
codesign -dvv build/Ferrite.app 2>&1
codesign -dvv build/Ferrite.app/Contents/MacOS/FerriteKeepAwakeHelper 2>&1
swift test
```

Expected: helper and app signatures verify; plist is valid; both signatures name the same non-ad-hoc certificate when `Ferrite Dev` is available; tests pass. Do not register the daemon yet.

- [ ] **Step 5: Commit**

```bash
git add scripts/make-app.sh scripts/release.sh
git commit -m "build(power): package privileged helper"
```

### Task 8: Wire Preferences, status menu, and app lifecycle

**Files:**
- Create: `Sources/Ferrite/PowerPreferencesView.swift`
- Modify: `Sources/Ferrite/AppDelegate.swift`
- Modify: `Sources/Ferrite/PersistenceCoordinator.swift`
- Modify: `Sources/Ferrite/PreferencesWindowController.swift`
- Modify: `Sources/Ferrite/StatusMenuController.swift`

- [ ] **Step 1: Add the Power Preferences surface**

```swift
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
}
```

- [ ] **Step 2: Expose the existing support directory**

In `PersistenceCoordinator`, add a stored property beside its other coordinator properties:

```swift
let supportDirectory: URL
```

In `init()`, immediately after computing `supportDir`, add:

```swift
supportDirectory = supportDir
```

- [ ] **Step 3: Inject Power into Preferences**

In `PreferencesWindowController`, add:

```swift
private var powerModel: PowerPreferencesModel?
private let keepAwake: KeepAwakeController

init(coordinator: PersistenceCoordinator, keepAwake: KeepAwakeController) {
    self.coordinator = coordinator
    self.keepAwake = keepAwake
}
```

In `show()`, reload the cached power model beside the other reloads:

```swift
powerModel?.reload()
```

During first window construction, create and retain the model:

```swift
let powerModel = PowerPreferencesModel(controller: keepAwake)
self.powerModel = powerModel
```

Replace the `PreferencesRootView` construction with this complete argument list; add the observed property to `PreferencesRootView`:

```swift
let hosting = NSHostingController(
    rootView: PreferencesRootView(layoutsModel: layoutsModel,
                                  appsModel: appsModel,
                                  reflowsModel: reflowsModel,
                                  magnetsModel: magnetsModel,
                                  powerModel: powerModel))
```

Add the observed property to `PreferencesRootView`:

```swift
@ObservedObject var powerModel: PowerPreferencesModel
```

Add this tab after Magnets:

```swift
PowerPreferencesView(model: powerModel)
    .tabItem { Text("Power") }
```

- [ ] **Step 4: Inject Power into the status menu**

In `StatusMenuController`, replace the existing lazy Preferences property and initializer with this code, and add the `keepAwake` stored property:

```swift
private let keepAwake: KeepAwakeController
private lazy var preferences = PreferencesWindowController(
    coordinator: coordinator, keepAwake: keepAwake)

init(coordinator: PersistenceCoordinator, keepAwake: KeepAwakeController) {
    self.coordinator = coordinator
    self.keepAwake = keepAwake
    super.init()
    statusItem.button?.image = NSImage(
        systemSymbolName: "rectangle.3.group",
        accessibilityDescription: "Ferrite")
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
}
```

Immediately after the Pause Persistence item, add:

```swift
let keepAwakeItem = actionItem(
    "Keep Mac Awake (Alpha) — \(keepAwake.state.displayText)",
    #selector(toggleKeepAwake))
keepAwakeItem.state = keepAwake.desiredEnabled ? .on : .off
menu.addItem(keepAwakeItem)
```

Add this action beside `togglePause`:

```swift
@objc private func toggleKeepAwake(_ sender: NSMenuItem) {
    keepAwake.setEnabled(!keepAwake.desiredEnabled)
    sender.state = keepAwake.desiredEnabled ? .on : .off
}
```

- [ ] **Step 5: Compose the feature in `AppDelegate`**

Add imports and properties:

```swift
import FerriteCore
```

```swift
private var keepAwake: KeepAwakeController?
```

At the start of the successful `startServices()` path, after `coordinator.start()` and before creating `StatusMenuController`, insert:

```swift
let power = KeepAwakeController(
    store: KeepAwakeSettingsStore(
        url: coordinator.supportDirectory.appendingPathComponent("power.json")),
    powerSource: SystemPowerSource(),
    helper: XpcKeepAwakeHelperClient(),
    assertions: IOKitPowerAssertionController(),
    loginItem: MainAppLoginItemController())
power.start()
self.keepAwake = power
self.statusMenu = StatusMenuController(coordinator: coordinator, keepAwake: power)
```

Remove the previous `StatusMenuController(coordinator: coordinator)` assignment. Add application termination cleanup:

```swift
func applicationWillTerminate(_ notification: Notification) {
    keepAwake?.stop()
}
```

- [ ] **Step 6: Build and smoke the inactive UI**

Run: `swift build --target Ferrite && swift test && open build/Ferrite.app`
Expected: build/tests pass; Ferrite opens with Keep Awake defaulting to **Off**; Preferences contains **Power**; status menu shows **Keep Mac Awake (Alpha) — Off**. Do not enable it until the live protocol task.

- [ ] **Step 7: Commit**

```bash
git add Sources/Ferrite/PowerPreferencesView.swift Sources/Ferrite/AppDelegate.swift Sources/Ferrite/PersistenceCoordinator.swift Sources/Ferrite/PreferencesWindowController.swift Sources/Ferrite/StatusMenuController.swift
git commit -m "feat(power): expose keep awake alpha controls"
```

### Task 9: Document the alpha feature and run automated verification

**Files:**
- Modify: `README.md`
- Modify: `docs/GUIDE.md`
- Modify: `docs/HANDOFF.md`
- Modify: `docs/BACKLOG.md`

- [ ] **Step 1: Add the README feature bullet**

Add this bullet beside the existing Application Clustering Mode alpha bullet:

```markdown
- **Keep Mac Awake (Alpha)** — opt in under Preferences → Power to prevent idle system/display sleep, screen saver, idle lock/logout, and closed-lid sleep without an external display. AC power only: unplugging suspends the mode and reconnecting restores it. Closed-lid support installs a privileged helper and uses a system-wide sleep override owned and cleaned by Ferrite. Enabled state restores after relaunch and reboot/login when Launch at Login is approved.
```

- [ ] **Step 2: Add the operational GUIDE section**

Add this complete section to `docs/GUIDE.md` near the other alpha feature documentation:

```markdown
## Keep Mac Awake (Alpha)

Enable **Preferences → Power → Keep Mac Awake (Alpha)** or use the Ferrite status-menu item. The mode prevents idle system/display sleep, screen saver, idle lock/logout, and lid-close sleep. Closed-lid operation requires AC power but no external display. Removing AC releases all assertions and shows **Waiting for AC**; reconnecting automatically restores an enabled preference. The preference restores after relaunch and after reboot/login when Launch at Login is allowed.

The first activation registers a privileged LaunchDaemon. macOS may require administrator approval under **System Settings → General → Login Items**. The helper accepts only fixed enable/disable/status requests from Ferrite signed with the same certificate. It never accepts arbitrary commands. Ferrite refuses to adopt an already-active external `SleepDisabled` override and clears only helper-owned state. While the global override is active, manual sleep can also be blocked. Disable Keep Awake to restore normal sleep.

The mode is AC-only and has no thermal/bag sensor. Keep the laptop ventilated. MDM-enforced policies and explicit user lock/logout/shutdown are not bypassed. Automatic-logout prevention remains alpha until the live inactivity protocol passes. If cleanup fails, Ferrite shows **Error** and retries; the manual recovery command is `sudo pmset -a disablesleep 0`.
```

- [ ] **Step 3: Record implementation status without inventing verification**

In `docs/HANDOFF.md`, add a paragraph stating that the current branch adds the Power alpha, its preference path is `~/Library/Application Support/Ferrite/power.json`, the helper label is `dev.ferrite.Ferrite.KeepAwakeHelper`, and live power/logout verification remains required until actually performed. In `docs/BACKLOG.md`, add a **Keep Mac Awake (Alpha, 2026-11-03)** entry listing implemented components and the exact live protocol steps still pending. After each live step later, replace its pending statement with observed hardware/macOS results; do not prefill success.

- [ ] **Step 4: Run automated verification**

Run:

```bash
swift test
swift build -c release --arch arm64 --arch x86_64
./scripts/make-app.sh
codesign --verify --strict build/Ferrite.app/Contents/MacOS/FerriteKeepAwakeHelper
codesign --verify --strict --deep build/Ferrite.app
plutil -lint build/Ferrite.app/Contents/Library/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist
git diff --check
```

Expected: all tests pass, both architectures build, app/helper signatures verify, plist is valid, no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/GUIDE.md docs/HANDOFF.md docs/BACKLOG.md
git commit -m "docs(power): document keep awake alpha"
```

### Task 10: Run the live alpha acceptance protocol

**Files:**
- Modify: `docs/BACKLOG.md`
- Modify: `docs/HANDOFF.md`

Perform this task only with the user's explicit go-ahead for administrator registration and real sleep/lid/reboot tests. Record the actual macOS version, Mac model, power source, and build commit in the final documentation. Keep a separate Terminal available for `sudo pmset -a disablesleep 0` recovery.

- [ ] **Step 1: Install and inspect assertions**

Enable Keep Awake from Preferences and complete macOS approval UI. Run:

```bash
pmset -g assertions
pmset -g
ps aux | grep '[F]erriteKeepAwakeHelper'
codesign -dvv build/Ferrite.app 2>&1
codesign -dvv build/Ferrite.app/Contents/MacOS/FerriteKeepAwakeHelper 2>&1
```

Expected: Ferrite owns `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep`; helper-owned `SleepDisabled 1` appears; helper runs as root; app and helper use the same non-ad-hoc leaf certificate; Preferences says **Active** only after all checks succeed.

- [ ] **Step 2: Verify idle screen saver, lock, and logout**

Set the shortest practical screen-saver, require-password/idle-lock, and automatic-logout intervals. Leave the machine completely untouched beyond every threshold plus a five-minute margin. Do not move the pointer to check early; inspect from another logged-in session/device if available. At the end verify the original apps and login session are still open, no screen saver or lock started, and Preferences remains **Active**. Restore the user's original security settings afterward. If automatic logout occurs, stop: the requested contract has failed and must not be documented as working.

- [ ] **Step 3: Verify lid-open behavior**

Exceed the configured system/display idle timers without input. Expected: display remains on, system remains awake, heartbeat continues without an **Error** state.

- [ ] **Step 4: Verify closed-lid AC operation without an external display**

Disconnect all external displays, connect AC, and close the lid for longer than the normal sleep interval. Use a running process or remote availability check that does not inject local user activity. Expected: the process/session remains running and `SleepDisabled 1` remains helper-owned.

- [ ] **Step 5: Verify unplug and reconnect safety**

While the lid is closed, remove AC. Expected within the helper's one-second poll plus command time: `SleepDisabled 0`, Ferrite assertions released, **Waiting for AC**, normal sleep allowed. Reconnect AC. Expected: helper and assertions reactivate and state returns to **Active**.

- [ ] **Step 6: Verify termination and helper recovery**

For each case, inspect `pmset -g` and Preferences rather than assuming:

1. Quit Ferrite: helper-owned override clears; saved preference remains enabled.
2. Relaunch: AC state reactivates automatically.
3. Force-kill Ferrite: validated client disconnect clears the override.
4. Relaunch, then force-kill the root helper: launchd restarts it; startup cleans helper-owned state; Ferrite reconnects/reactivates on AC without duplicate assertions.
5. Log out: override clears. Log in: approved Launch at Login restores the preference.
6. Reboot on AC: startup cleanup precedes login restoration. Reboot on battery: state remains **Waiting for AC** and `SleepDisabled 0`.

- [ ] **Step 7: Verify disable and failure handling**

Disable Keep Awake and verify `SleepDisabled 0`, no Ferrite assertions, and restored manual/idle sleep. Test an unmanaged external override only with explicit user approval: set it, confirm Ferrite refuses activation and leaves it untouched, then restore it with `sudo pmset -a disablesleep 0`. Attempt an ad-hoc or differently signed client and confirm rejection. Use the fake-provider tests for command/cleanup failure; do not deliberately damage the live `pmset` installation.

- [ ] **Step 8: Record only observed results and run final checks**

Update `docs/BACKLOG.md` and `docs/HANDOFF.md` with actual outcomes for every step, including any failure and residual. Run:

```bash
swift test
pmset -g
git diff --check
git status --short
```

Expected: tests pass; Keep Awake is left in the state explicitly requested by the user; any enabled `SleepDisabled` is either currently shown as helper-owned **Active** or is recovered to `0`; documentation matches observations.

- [ ] **Step 9: Commit verification evidence**

```bash
git add docs/BACKLOG.md docs/HANDOFF.md
git commit -m "docs(power): record keep awake live verification"
```
