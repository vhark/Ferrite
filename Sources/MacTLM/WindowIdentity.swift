import CryptoKit
import Foundation

/// Turns a window title into an opaque, per-install identity.
///
/// Titles are never persisted: browser titles are browsing history, and the
/// data files are designed to be syncable (PRD §7). The hash preserves
/// exact-window matching without storing readable text.
///
/// The salt lives in UserDefaults, i.e. `~/Library/Preferences/`, which is
/// deliberately OUTSIDE the Application Support directory users sync — so a
/// synced layout file does not carry the value needed to test guesses.
enum WindowIdentity {
    private static let saltKey = "dev.mactlm.identitySalt"

    /// 32 random bytes, created once per install.
    private static var salt: Data {
        if let existing = UserDefaults.standard.data(forKey: saltKey),
           existing.count == 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let fresh = Data(bytes)
        UserDefaults.standard.set(fresh, forKey: saltKey)
        return fresh
    }

    /// Opaque identity for a title, or nil for an empty title (nothing to
    /// match on, and hashing "" would make every untitled window equal).
    static func hash(_ title: String) -> String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(title.utf8))
        return hasher.finalize()
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
