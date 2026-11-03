import Foundation
import XPC
import FerriteCore

final class XpcKeepAwakeHelperClient: KeepAwakeHelperClient {
    private let queue = DispatchQueue(label: "dev.ferrite.Ferrite.KeepAwakeClient")
    private var connection: xpc_connection_t?
    private let installer = DirectLaunchDaemonInstaller()

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try self.installer.ensureInstalled()
                self.request(KeepAwakeXPC.status) { result in
                    switch result {
                    case let .failure(error):
                        completion(.failure(error))
                    case .success:
                        self.request(KeepAwakeXPC.enable) { result in
                            switch result {
                            case let .failure(error): completion(.failure(error))
                            case .success: completion(.success(()))
                            }
                        }
                    }
                }
            } catch { self.complete(error, completion: completion) }
        }
    }

    func disable(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.installer.isLoaded() else {
                self.confirmUnloadedSleepState(clean: (), completion: completion)
                return
            }
            self.request(KeepAwakeXPC.disable) { result in
                switch result {
                case let .failure(error): completion(.failure(error))
                case .success: completion(.success(()))
                }
            }
        }
    }

    func status(completion: @escaping (Result<Bool, Error>) -> Void) {
        queue.async {
            guard self.installer.isLoaded() else {
                self.confirmUnloadedSleepState(clean: false, completion: completion)
                return
            }
            self.request(KeepAwakeXPC.status) { result in
                switch result {
                case let .failure(error): completion(.failure(error))
                case let .success(message):
                    completion(.success(xpc_dictionary_get_bool(message, KeepAwakeXPC.enabled)))
                }
            }
        }
    }

    func uninstall(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try self.installer.uninstall()
                self.connection = nil
                DispatchQueue.main.async { completion(.success(())) }
            } catch { self.complete(error, completion: completion) }
        }
    }

    private func confirmUnloadedSleepState<Value>(
        clean: Value, completion: @escaping (Result<Value, Error>) -> Void
    ) {
        do {
            guard try !installer.sleepDisabled() else {
                complete(KeepAwakeClientError.unavailable(
                    "SleepDisabled remains active while the privileged helper is unloaded. "
                        + "Restore the helper or run sudo pmset -a disablesleep 0."),
                    completion: completion)
                return
            }
            DispatchQueue.main.async { completion(.success(clean)) }
        } catch {
            complete(KeepAwakeClientError.unavailable(
                "Cannot verify SleepDisabled while the privileged helper is unloaded: "
                    + error.localizedDescription),
                completion: completion)
        }
    }

    private func complete<Value>(
        _ error: Error, completion: @escaping (Result<Value, Error>) -> Void
    ) {
        let mapped: KeepAwakeClientError
        if error as? DirectLaunchDaemonInstallerError == .approvalCancelled {
            mapped = .approvalNeeded(
                "Approve the direct helper installation with your administrator credentials.")
        } else {
            mapped = .unavailable(error.localizedDescription)
        }
        DispatchQueue.main.async { completion(.failure(mapped)) }
    }

    private func request(_ operation: String,
                         retryOnDisconnect: Bool = true,
                         completion: @escaping (Result<xpc_object_t, Error>) -> Void) {
        queue.async {
            let connection = self.makeConnection()
            let message = xpc_dictionary_create(nil, nil, 0)
            operation.withCString { xpc_dictionary_set_string(message, KeepAwakeXPC.operation, $0) }
            xpc_connection_send_message_with_reply(connection, message, self.queue) { reply in
                if xpc_get_type(reply) == XPC_TYPE_ERROR {
                    let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                        .map { String(cString: $0) } ?? "XPC transport error"
                    if self.connection.map(ObjectIdentifier.init) == ObjectIdentifier(connection) {
                        self.connection = nil
                    }
                    if retryOnDisconnect {
                        self.queue.asyncAfter(deadline: .now() + 0.5) {
                            self.request(operation, retryOnDisconnect: false, completion: completion)
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(.failure(KeepAwakeClientError.unavailable(description)))
                        }
                    }
                    return
                }
                if let error = self.errorString(reply) {
                    DispatchQueue.main.async {
                        completion(.failure(KeepAwakeClientError.unavailable(error)))
                    }
                } else {
                    DispatchQueue.main.async { completion(.success(reply)) }
                }
            }
        }
    }

    private func makeConnection() -> xpc_connection_t {
        if let connection { return connection }
        let connection = xpc_connection_create_mach_service(
            KeepAwakeXPC.serviceName, queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        let id = ObjectIdentifier(connection)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR,
               self?.connection.map(ObjectIdentifier.init) == id {
                self?.connection = nil
            }
        }
        xpc_connection_resume(connection)
        self.connection = connection
        return connection
    }

    private func errorString(_ message: xpc_object_t) -> String? {
        guard let value = xpc_dictionary_get_string(message, KeepAwakeXPC.error) else { return nil }
        return String(cString: value)
    }
}
