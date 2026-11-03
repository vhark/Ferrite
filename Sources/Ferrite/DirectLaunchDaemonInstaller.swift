import CryptoKit
import Foundation
import Security
import FerriteCore

enum DirectLaunchDaemonInstallerError: LocalizedError, Equatable {
    case approvalCancelled
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .approvalCancelled:
            return "Administrator approval was cancelled."
        case let .installationFailed(message):
            return message
        }
    }
}

final class DirectLaunchDaemonInstaller {
    private let label = "dev.ferrite.Ferrite.KeepAwakeHelper"
    private let installationVersion = 1
    private let installedPlist = URL(fileURLWithPath:
        "/Library/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist")
    private let installedHelper = URL(fileURLWithPath:
        "/Library/PrivilegedHelperTools/dev.ferrite.Ferrite.KeepAwakeHelper")
    private let ownershipMarker = "/private/var/db/dev.ferrite.Ferrite.keep-awake-owned"
    private var sourceHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FerriteKeepAwakeHelper")
    }
    private var sourcePlist: URL {
        Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/dev.ferrite.Ferrite.KeepAwakeHelper.plist")
    }

    func ensureInstalled() throws {
        if isCurrentInstallation(), isLoaded() { return }
        let cdHash = try validatedHelperHash()
        let plistHash = try validatedPlistHash()
        try runAdministrator(command: installCommand(cdHash: cdHash, plistHash: plistHash))
        guard isLoaded() else {
            throw DirectLaunchDaemonInstallerError.installationFailed(
                "The helper installed but launchd did not start it.")
        }
    }

    func uninstall() throws {
        guard hasInstallation() || isLoaded()
            || FileManager.default.fileExists(atPath: ownershipMarker) else { return }
        try runAdministrator(command: uninstallCommand())
    }

    func isLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func sleepDisabled() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SleepOverrideError.commandFailed(process.terminationStatus, output)
        }
        return try SleepOverrideController.parseSleepDisabled(from: output)
    }

    private func isCurrentInstallation() -> Bool {
        guard FileManager.default.fileExists(atPath: installedPlist.path),
              FileManager.default.fileExists(atPath: installedHelper.path),
              let data = try? Data(contentsOf: installedPlist),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              plist["FerriteHelperVersion"] as? Int == installationVersion,
              plist["Program"] as? String == installedHelper.path else { return false }
        return true
    }

    private func hasInstallation() -> Bool {
        FileManager.default.fileExists(atPath: installedPlist.path)
            || FileManager.default.fileExists(atPath: installedHelper.path)
    }

    private func validatedHelperHash() throws -> String {
        var appCode: SecCode?
        var appStatic: SecStaticCode?
        var helperCode: SecStaticCode?
        guard SecCodeCopySelf([], &appCode) == errSecSuccess, let appCode,
              SecCodeCheckValidity(appCode, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(appCode, [], &appStatic) == errSecSuccess,
              let appStatic,
              SecStaticCodeCreateWithPath(sourceHelper as CFURL, [], &helperCode) == errSecSuccess,
              let helperCode,
              SecStaticCodeCheckValidity(helperCode, [], nil) == errSecSuccess,
              let appInfo = signingInformation(appStatic),
              let helperInfo = signingInformation(helperCode),
              helperInfo[kSecCodeInfoIdentifier as String] as? String == label,
              let appCertificate = (appInfo[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
              let helperCertificate = (helperInfo[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
              SecCertificateCopyData(appCertificate) as Data == SecCertificateCopyData(helperCertificate) as Data,
              let unique = helperInfo[kSecCodeInfoUnique as String] as? Data else {
            throw DirectLaunchDaemonInstallerError.installationFailed(
                "The bundled helper must have the expected identity and the app's non-ad-hoc signing certificate.")
        }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    private func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }

    private func validatedPlistHash() throws -> String {
        guard let data = try? Data(contentsOf: sourcePlist),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              Set(plist.keys) == Set([
                "Label", "Program", "RunAtLoad", "KeepAlive",
                "MachServices", "FerriteHelperVersion"
              ]),
              plist["Label"] as? String == label,
              plist["Program"] as? String == installedHelper.path,
              plist["FerriteHelperVersion"] as? Int == installationVersion,
              plist["RunAtLoad"] as? Bool == true,
              plist["KeepAlive"] as? Bool == true,
              let services = plist["MachServices"] as? [String: Any],
              services.count == 1,
              services[label] as? Bool == true else {
            throw DirectLaunchDaemonInstallerError.installationFailed(
                "The bundled LaunchDaemon plist does not match required helper settings.")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func installCommand(cdHash: String, plistHash: String) -> String {
        let helper = shellQuote(installedHelper.path)
        let plist = shellQuote(installedPlist.path)
        return """
        set -euo pipefail
        umask 077
        label=\(shellQuote(label))
        target_helper=\(helper)
        target_plist=\(plist)
        source_helper=\(shellQuote(sourceHelper.path))
        source_plist=\(shellQuote(sourcePlist.path))
        expected_cdhash=\(shellQuote(cdHash))
        expected_plist_hash=\(shellQuote(plistHash))
        stage=$(/usr/bin/mktemp -d /private/var/db/dev.ferrite.Ferrite.keep-awake.XXXXXXXX)
        cutover=0
        had_helper=0
        had_plist=0
        was_loaded=0
        finish() {
          result=$?
          trap - EXIT
          if [ "$result" -ne 0 ] && [ "$cutover" -eq 1 ]; then
            echo "Helper cutover failed; restoring previous installation" >&2
            rollback_failed=0
            if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
              /bin/launchctl bootout "system/$label" || rollback_failed=1
            fi
            if [ "$had_helper" -eq 1 ]; then
              /usr/bin/install -o root -g wheel -m 0755 "$stage/old-helper" "$target_helper" || rollback_failed=1
            else
              /bin/rm -f "$target_helper" || rollback_failed=1
            fi
            if [ "$had_plist" -eq 1 ]; then
              /usr/bin/install -o root -g wheel -m 0644 "$stage/old-plist" "$target_plist" || rollback_failed=1
            else
              /bin/rm -f "$target_plist" || rollback_failed=1
            fi
            if [ "$was_loaded" -eq 1 ]; then
              /bin/launchctl bootstrap system "$target_plist" || rollback_failed=1
            fi
            if [ "$rollback_failed" -ne 0 ]; then
              echo "ROLLBACK FAILED: previous helper could not be fully restored" >&2
            else
              echo "Previous helper restored" >&2
            fi
          fi
          /bin/rm -rf "$stage"
          exit "$result"
        }
        trap finish EXIT
        /usr/bin/install -o root -g wheel -m 0755 "$source_helper" "$stage/helper"
        /usr/bin/install -o root -g wheel -m 0644 "$source_plist" "$stage/plist"
        /usr/bin/codesign --verify --strict "$stage/helper"
        staged_cdhash=$(/usr/bin/codesign -dvvv "$stage/helper" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
        [ "$staged_cdhash" = "$expected_cdhash" ] || { echo "Staged helper signature differs from validated helper" >&2; exit 1; }
        /usr/bin/plutil -lint "$stage/plist"
        staged_plist_hash=$(/usr/bin/shasum -a 256 "$stage/plist" | /usr/bin/awk '{print $1}')
        [ "$staged_plist_hash" = "$expected_plist_hash" ] || { echo "Staged daemon plist differs from validated plist" >&2; exit 1; }
        if [ -f "$target_helper" ]; then
          /bin/cp -p "$target_helper" "$stage/old-helper"
          had_helper=1
        fi
        if [ -f "$target_plist" ]; then
          /bin/cp -p "$target_plist" "$stage/old-plist"
          had_plist=1
        fi
        if /bin/launchctl print "system/$label" >/dev/null 2>&1; then was_loaded=1; fi
        cutover=1
        if [ "$was_loaded" -eq 1 ]; then /bin/launchctl bootout "system/$label"; fi
        for attempt in $(/usr/bin/seq 1 50); do
          /usr/bin/pgrep -f "$target_helper" >/dev/null 2>&1 || break
          /bin/sleep 0.1
        done
        if /usr/bin/pgrep -f "$target_helper" >/dev/null 2>&1; then
          echo "Existing helper did not stop" >&2
          exit 1
        fi
        /usr/bin/install -o root -g wheel -m 0755 "$stage/helper" "$target_helper"
        /usr/bin/install -o root -g wheel -m 0644 "$stage/plist" "$target_plist"
        /bin/launchctl bootstrap system "$target_plist"
        /bin/launchctl print "system/$label" >/dev/null
        """
    }

    private func uninstallCommand() -> String {
        """
        set -euo pipefail
        label=\(shellQuote(label))
        target_helper=\(shellQuote(installedHelper.path))
        target_plist=\(shellQuote(installedPlist.path))
        ownership=/private/var/db/dev.ferrite.Ferrite.keep-awake-owned
        if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
          /bin/launchctl bootout "system/$label"
        fi
        for attempt in $(/usr/bin/seq 1 50); do
          /usr/bin/pgrep -f "$target_helper" >/dev/null 2>&1 || break
          /bin/sleep 0.1
        done
        if /usr/bin/pgrep -f "$target_helper" >/dev/null 2>&1; then
          echo "Existing helper did not stop" >&2
          exit 1
        fi
        if [ -f "$ownership" ]; then
          /usr/bin/pmset -a disablesleep 0
          /bin/rm -f "$ownership"
        fi
        /bin/rm -f "$target_plist" "$target_helper"
        """
    }

    private func runAdministrator(command: String) throws {
        let encoded = Data(command.utf8).base64EncodedString()
        let shellCommand = "printf '%s' '\(encoded)' | /usr/bin/base64 -D | /bin/bash"
        let source = "do shell script \(appleScriptString(shellCommand)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 128 || output.localizedCaseInsensitiveContains("User canceled") {
                throw DirectLaunchDaemonInstallerError.approvalCancelled
            }
            throw DirectLaunchDaemonInstallerError.installationFailed(
                output.isEmpty ? "Administrator command failed." : output)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
