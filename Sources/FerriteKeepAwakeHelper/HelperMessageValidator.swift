import Foundation
import Security
import XPC
import FerriteCore

final class HelperMessageValidator {
    private let helperCertificate: SecCertificate

    init?() {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              let info = Self.signingInformation(staticCode),
              let certificates = info[KeepAwakeXPC.certificates] as? [SecCertificate],
              let certificate = certificates.first else { return nil }
        helperCertificate = certificate
    }

    func accepts(_ message: xpc_object_t) -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCreateWithXPCMessage(message, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              let info = Self.signingInformation(staticCode),
              info[KeepAwakeXPC.identifier] as? String == KeepAwakeXPC.applicationIdentifier,
              let certificates = info[KeepAwakeXPC.certificates] as? [SecCertificate],
              let clientCertificate = certificates.first else { return false }
        return SecCertificateCopyData(clientCertificate) as Data
            == SecCertificateCopyData(helperCertificate) as Data
    }

    private static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}
