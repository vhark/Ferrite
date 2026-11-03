import XCTest
@testable import FerriteCore

private struct FakePowerResult: Error { let message: String }

private final class FakePmset: SleepOverrideCommandRunning {
    var sleepDisabled = false
    var failure: FakePowerResult?
    private(set) var mutations: [Bool] = []
    private(set) var callCount = 0
    var failuresByCall: [Int: FakePowerResult] = [:]
    var queryOutput: String?

    func run(_ arguments: [String]) throws -> PowerCommandResult {
        callCount += 1
        if let failure = failuresByCall[callCount] { throw failure }
        if let failure { throw failure }
        if arguments == ["-g"] {
            return PowerCommandResult(
                exitCode: 0,
                output: queryOutput ?? "System-wide power settings:\n SleepDisabled\t\t\(sleepDisabled ? 1 : 0)\n")
        }
        guard arguments == ["-a", "disablesleep", "0"]
                || arguments == ["-a", "disablesleep", "1"] else {
            return PowerCommandResult(exitCode: 64, output: "unexpected arguments")
        }
        sleepDisabled = arguments.last == "1"
        mutations.append(sleepDisabled)
        queryOutput = nil
        return PowerCommandResult(exitCode: 0, output: "")
    }
}

private final class FakePowerSource: PowerSourceProviding {
    var isOnAC: Bool
    init(isOnAC: Bool) { self.isOnAC = isOnAC }
}

private final class FakeOwnership: SleepOverrideOwnershipStoring {
    var owned = false
    var saveFailure: FakePowerResult?
    func load() throws -> Bool { owned }
    func save(_ owned: Bool) throws {
        if let saveFailure { throw saveFailure }
        self.owned = owned
    }
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

    func testOwnershipSaveFailurePreventsPowerMutation() throws {
        let (pmset, _, ownership, controller) = makeFixture()
        ownership.saveFailure = FakePowerResult(message: "marker failed")
        XCTAssertThrowsError(try controller.enable())
        XCTAssertTrue(pmset.mutations.isEmpty)
        XCTAssertFalse(pmset.sleepDisabled)
    }

    func testFailedActivationRollbackRetainsCleanupOwnership() throws {
        let (pmset, _, ownership, controller) = makeFixture()
        // Query, enable, post-enable query failure, failed rollback.
        pmset.failuresByCall = [
            3: FakePowerResult(message: "query failed"),
            4: FakePowerResult(message: "rollback failed")
        ]
        XCTAssertThrowsError(try controller.enable())
        XCTAssertTrue(pmset.sleepDisabled)
        XCTAssertTrue(ownership.owned)
        XCTAssertTrue(controller.needsCleanup)
    }

    func testSuccessfulActivationRollbackClearsPendingOwnership() throws {
        let (pmset, _, ownership, controller) = makeFixture()
        pmset.failuresByCall = [3: FakePowerResult(message: "query failed")]
        XCTAssertThrowsError(try controller.enable())
        XCTAssertFalse(pmset.sleepDisabled)
        XCTAssertFalse(ownership.owned)
    }

    func testMissingSettingsSectionIsNotConfirmedDisabled() throws {
        let (pmset, _, _, controller) = makeFixture()
        pmset.queryOutput = ""
        XCTAssertThrowsError(try controller.enable())
        XCTAssertTrue(pmset.mutations.isEmpty)
    }

    func testMalformedSleepDisabledValueIsRejected() throws {
        let (pmset, _, _, controller) = makeFixture()
        pmset.queryOutput = "System-wide power settings:\n SleepDisabled\t\t2\n"
        XCTAssertThrowsError(try controller.enable())
        XCTAssertTrue(pmset.mutations.isEmpty)
    }

    func testValidSettingsWithoutSleepDisabledKeyMeansDisabled() throws {
        let (pmset, _, ownership, controller) = makeFixture()
        pmset.queryOutput = "System-wide power settings:\n sleep\t\t1\n"
        try controller.enable()
        XCTAssertTrue(pmset.sleepDisabled)
        XCTAssertTrue(ownership.owned)
    }
}
