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
