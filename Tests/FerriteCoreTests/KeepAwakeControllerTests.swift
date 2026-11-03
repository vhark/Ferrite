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
