import Foundation
import XPC
import FerriteCore

final class KeepAwakeHelperDaemon {
    private let queue = DispatchQueue(label: "dev.ferrite.Ferrite.KeepAwakeHelper")
    private let controller: SleepOverrideController
    private let powerSource: PowerSourceProviding
    private let validator: HelperMessageValidator?
    private var listener: xpc_connection_t?
    private var clients: Set<ObjectIdentifier> = []
    private var lastError: String?
    private var recoveryPending = false
    private var timer: Timer?
    private var sigterm: DispatchSourceSignal?

    init(controller: SleepOverrideController,
         powerSource: PowerSourceProviding,
         validator: HelperMessageValidator?) {
        self.controller = controller
        self.powerSource = powerSource
        self.validator = validator
    }

    func start() {
        queue.sync {
            do {
                try controller.recoverAtStartup()
                recoveryPending = false
                lastError = nil
            } catch {
                recoveryPending = true
                lastError = error.localizedDescription
            }
        }
        let listener = xpc_connection_create_mach_service(
            KeepAwakeXPC.serviceName, queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            self?.accept(event)
        }
        xpc_connection_resume(listener)
        self.listener = listener
        timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.queue.async { self?.reconcileSafety() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        installSIGTERMHandler()
    }

    private func accept(_ connection: xpc_connection_t) {
        let id = ObjectIdentifier(connection)
        xpc_connection_set_target_queue(connection, queue)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard let self else { return }
            let type = xpc_get_type(event)
            if type == XPC_TYPE_DICTIONARY {
                self.handle(event, connection: connection, id: id)
            } else if type == XPC_TYPE_ERROR {
                self.clients.remove(id)
                if self.clients.isEmpty { self.cleanup() }
            }
        }
        xpc_connection_resume(connection)
    }

    private func handle(_ message: xpc_object_t,
                        connection: xpc_connection_t,
                        id: ObjectIdentifier) {
        guard validator?.accepts(message) == true else {
            reply(to: message, connection: connection, enabled: nil, error:
                "Client signing identity rejected; app and helper must share a non-ad-hoc certificate.")
            xpc_connection_cancel(connection)
            return
        }
        clients.insert(id)
        guard let raw = xpc_dictionary_get_string(message, KeepAwakeXPC.operation) else {
            reply(to: message, connection: connection, enabled: nil, error: "Missing operation.")
            return
        }
        let operation = String(cString: raw)
        do {
            switch operation {
            case KeepAwakeXPC.enable:
                guard !recoveryPending else {
                    let reason = lastError.map { "Startup cleanup is still pending: \($0)" }
                        ?? "Startup cleanup is still pending."
                    reply(to: message, connection: connection, enabled: nil, error: reason)
                    return
                }
                try controller.enable()
                lastError = nil
                reply(to: message, connection: connection, enabled: true, error: lastError)
            case KeepAwakeXPC.disable:
                try controller.disable()
                recoveryPending = false
                lastError = nil
                reply(to: message, connection: connection, enabled: false, error: nil)
            case KeepAwakeXPC.status:
                let enabled = try controller.status()
                reply(to: message, connection: connection, enabled: enabled, error: lastError)
            default:
                reply(to: message, connection: connection, enabled: nil, error: "Unknown operation.")
            }
        } catch {
            recoveryPending = controller.needsCleanup
            lastError = error.localizedDescription
            reply(to: message, connection: connection, enabled: nil, error: lastError)
        }
    }

    private func reply(to request: xpc_object_t,
                       connection: xpc_connection_t,
                       enabled: Bool?, error: String?) {
        guard let reply = xpc_dictionary_create_reply(request) else { return }
        if let enabled { xpc_dictionary_set_bool(reply, KeepAwakeXPC.enabled, enabled) }
        if let error {
            error.withCString { xpc_dictionary_set_string(reply, KeepAwakeXPC.error, $0) }
        }
        xpc_connection_send_message(connection, reply)
    }

    private func reconcileSafety() {
        if !powerSource.isOnAC || recoveryPending {
            cleanup()
        }
    }

    private func cleanup() {
        do {
            try controller.disable()
            recoveryPending = false
            lastError = nil
        } catch {
            recoveryPending = controller.needsCleanup
            lastError = error.localizedDescription
        }
    }

    private func installSIGTERMHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.queue.sync { self.cleanup() }
            exit(0)
        }
        source.resume()
        sigterm = source
    }
}
