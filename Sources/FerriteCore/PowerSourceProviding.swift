import Foundation
import IOKit.ps

public protocol PowerSourceProviding: AnyObject {
    var isOnAC: Bool { get }
}

public final class SystemPowerSource: PowerSourceProviding {
    public init() {}

    public var isOnAC: Bool {
        guard let unmanaged = IOPSCopyPowerSourcesInfo() else { return false }
        let snapshot = unmanaged.takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue()
        return source as String == kIOPSACPowerValue
    }
}
