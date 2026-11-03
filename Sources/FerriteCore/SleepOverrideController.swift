import Foundation

public struct PowerCommandResult: Equatable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol SleepOverrideCommandRunning: AnyObject {
    func run(_ arguments: [String]) throws -> PowerCommandResult
}

public protocol SleepOverrideOwnershipStoring: AnyObject {
    func load() throws -> Bool
    func save(_ owned: Bool) throws
}

public enum SleepOverrideError: Error, Equatable, LocalizedError {
    case notOnAC
    case externalOverride
    case commandFailed(Int32, String)
    case stateMismatch(expected: Bool)

    public var errorDescription: String? {
        switch self {
        case .notOnAC:
            return "Keep Mac Awake requires AC power."
        case .externalOverride:
            return "Another tool already controls SleepDisabled; Ferrite will not adopt or clear it."
        case let .commandFailed(code, output):
            return "pmset failed with exit code \(code): \(output)"
        case let .stateMismatch(expected):
            return "SleepDisabled did not reach the expected value \(expected ? 1 : 0)."
        }
    }
}

public final class SleepOverrideController {
    private let runner: SleepOverrideCommandRunning
    private let powerSource: PowerSourceProviding
    private let ownership: SleepOverrideOwnershipStoring

    public init(runner: SleepOverrideCommandRunning,
                powerSource: PowerSourceProviding,
                ownership: SleepOverrideOwnershipStoring) {
        self.runner = runner
        self.powerSource = powerSource
        self.ownership = ownership
    }

    public var needsCleanup: Bool {
        (try? ownership.load()) ?? true
    }

    public func status() throws -> Bool {
        try querySleepDisabled()
    }

    public func recoverAtStartup() throws {
        try disable()
    }

    public func enable() throws {
        guard powerSource.isOnAC else { throw SleepOverrideError.notOnAC }
        if try querySleepDisabled() {
            if try ownership.load() { return }
            throw SleepOverrideError.externalOverride
        }
        do {
            try runChecked(["-a", "disablesleep", "1"])
            guard try querySleepDisabled() else {
                throw SleepOverrideError.stateMismatch(expected: true)
            }
            try ownership.save(true)
        } catch {
            _ = try? runChecked(["-a", "disablesleep", "0"])
            throw error
        }
    }

    public func disable() throws {
        guard try ownership.load() else { return }
        try runChecked(["-a", "disablesleep", "0"])
        guard try !querySleepDisabled() else {
            throw SleepOverrideError.stateMismatch(expected: false)
        }
        try ownership.save(false)
    }

    public func powerSourceChanged() throws {
        if !powerSource.isOnAC { try disable() }
    }

    private func querySleepDisabled() throws -> Bool {
        let result = try runChecked(["-g"])
        for line in result.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return false
    }

    @discardableResult
    private func runChecked(_ arguments: [String]) throws -> PowerCommandResult {
        let result = try runner.run(arguments)
        guard result.exitCode == 0 else {
            throw SleepOverrideError.commandFailed(result.exitCode, result.output)
        }
        return result
    }
}
