import XCTest
@testable import MacTLMCore

final class DebouncerTests: XCTestCase {
    func testOnlyLastCallFires() {
        let expectation = expectation(description: "fired once")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true
        let debouncer = Debouncer(delay: 0.05)
        var value = 0
        for i in 1...5 {
            debouncer.call { value = i; expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(value, 5)
    }

    func testMaxDelayCapFiresDespiteContinuousCalls() {
        let expectation = expectation(description: "fired despite churn")
        let debouncer = Debouncer(delay: 0.1, maxDelay: 0.25)
        // Re-call every 50 ms forever; without the cap this never fires.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            debouncer.call { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 2.0)
        timer.invalidate()
    }

    func testCancelPreventsFiring() {
        let debouncer = Debouncer(delay: 0.05)
        var fired = false
        debouncer.call { fired = true }
        debouncer.cancel()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertFalse(fired)
    }
}
