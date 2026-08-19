import ApplicationServices

enum AXPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt directing the user to System Settings.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
