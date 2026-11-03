import Foundation
import FerriteCore

final class PmsetCommandRunner: SleepOverrideCommandRunning {
    func run(_ arguments: [String]) throws -> PowerCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 10) == .success else {
            if process.isRunning { process.terminate() }
            throw NSError(domain: "FerriteKeepAwakeHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "pmset timed out after 10 seconds."
            ])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return PowerCommandResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }
}
