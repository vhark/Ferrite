import Foundation
import Security

public enum KeepAwakeXPC {
    public static let serviceName = "dev.ferrite.Ferrite.KeepAwakeHelper"
    public static let applicationIdentifier = "dev.ferrite.Ferrite"
    public static let operation = "operation"
    public static let enable = "enable"
    public static let disable = "disable"
    public static let status = "status"
    public static let enabled = "enabled"
    public static let error = "error"
    public static let identifier = kSecCodeInfoIdentifier as String
    public static let certificates = kSecCodeInfoCertificates as String
}
