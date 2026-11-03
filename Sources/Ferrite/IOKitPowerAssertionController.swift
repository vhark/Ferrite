import Foundation
import IOKit.pwr_mgt
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
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &newSystem), operation: "system sleep assertion")
            try check(IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &newDisplay), operation: "display sleep assertion")
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
        guard activityAssertion != 0 else { return }
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
