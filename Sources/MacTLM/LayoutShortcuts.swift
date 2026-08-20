import AppKit
import KeyboardShortcuts
import MacTLMCore

/// Maps bundle names to global hotkeys. Shortcuts attach to the bundle NAME,
/// so one hotkey restores a whole workspace across every display (PRD §9).
/// KeyboardShortcuts persists each assignment in UserDefaults under its name.
enum LayoutShortcuts {
    /// Names must be stable across launches; the bundle name is the identity.
    static func name(forBundle bundleName: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("bundle-\(bundleName)")
    }

    /// (Re)registers key-up handlers for every bundle in the library.
    /// Safe to call repeatedly: handlers are cleared first.
    /// KeyboardShortcuts' API is `@MainActor`; the coordinator that calls this
    /// is not, so every mutation hops to the main queue.
    static func register(bundleNames: [String],
                         onTrigger: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            KeyboardShortcuts.removeAllHandlers()
            for bundleName in bundleNames {
                KeyboardShortcuts.onKeyUp(for: name(forBundle: bundleName)) {
                    onTrigger(bundleName)
                }
            }
        }
    }

    /// Clears a bundle's assignment (used when a bundle is deleted).
    static func clear(bundleName: String) {
        DispatchQueue.main.async {
            KeyboardShortcuts.reset(name(forBundle: bundleName))
        }
    }

    /// Moves an assignment when a bundle is renamed.
    static func migrate(from oldName: String, to newName: String) {
        DispatchQueue.main.async {
            let shortcut = KeyboardShortcuts.getShortcut(for: name(forBundle: oldName))
            KeyboardShortcuts.setShortcut(shortcut, for: name(forBundle: newName))
            KeyboardShortcuts.reset(name(forBundle: oldName))
        }
    }

    /// Reads an assignment. Callers are SwiftUI views, already on the main actor.
    @MainActor
    static func shortcut(forBundle bundleName: String) -> KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: name(forBundle: bundleName))
    }
}
