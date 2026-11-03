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
