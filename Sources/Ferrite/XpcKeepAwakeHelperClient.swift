import Foundation
import ServiceManagement
import XPC
import FerriteCore

final class XpcKeepAwakeHelperClient: KeepAwakeHelperClient {
    private let queue = DispatchQueue(label: "dev.ferrite.Ferrite.KeepAwakeClient")
    private var connection: xpc_connection_t?
    private let service = SMAppService.daemon(plistName: KeepAwakeXPC.daemonPlistName)

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try registerIfNeeded()
            request(KeepAwakeXPC.enable) { result in
                switch result {
                case let .failure(error): completion(.failure(error))
                case .success: completion(.success(()))
                }
            }
        } catch { DispatchQueue.main.async { completion(.failure(error)) } }
    }

    func disable(completion: @escaping (Result<Void, Error>) -> Void) {
        guard service.status != .notRegistered else {
            DispatchQueue.main.async { completion(.success(())) }
            return
        }
        request(KeepAwakeXPC.disable) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case .success: completion(.success(()))
            }
        }
    }

    func status(completion: @escaping (Result<Bool, Error>) -> Void) {
        guard service.status != .notRegistered else {
            DispatchQueue.main.async { completion(.success(false)) }
            return
        }
        request(KeepAwakeXPC.status) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(message):
                completion(.success(xpc_dictionary_get_bool(message, KeepAwakeXPC.enabled)))
            }
        }
    }

    private func registerIfNeeded() throws {
        if service.status == .notRegistered { try service.register() }
        switch service.status {
        case .enabled: return
        case .requiresApproval:
            throw KeepAwakeClientError.approvalNeeded(
                "Approve Ferrite's privileged helper in System Settings → General → Login Items.")
        case .notRegistered:
            throw KeepAwakeClientError.approvalNeeded("The privileged helper is not registered.")
        case .notFound:
            throw KeepAwakeClientError.unavailable("The privileged helper is missing from Ferrite.app.")
        @unknown default:
            throw KeepAwakeClientError.unavailable("The privileged helper state is unknown.")
        }
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
                    if retryOnDisconnect {
                        self.connection = nil
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
        let connection = xpc_connection_create_mach_service(KeepAwakeXPC.serviceName, queue, 0)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
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
