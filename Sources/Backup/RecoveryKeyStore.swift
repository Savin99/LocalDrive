import Foundation
import Security

enum RecoveryKeyError: LocalizedError {
    case invalidCode
    case devicePasscodeRequired
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            "Код восстановления имеет неверный формат."
        case .devicePasscodeRequired:
            "Сначала установите код-пароль iPhone, затем повторите настройку."
        case .keychain(let status):
            "Не удалось защитить код восстановления (Keychain: \(status))."
        }
    }
}

enum RecoveryKeyStore {
    private static let service = "com.ilyaqa.localdrive.recovery-key"

    static var hasKey: Bool { Keychain.get(service: service) != nil }

    static func create() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw RecoveryKeyError.keychain(randomStatus)
        }

        let data = Data(bytes)
        var status = Keychain.set(
            data,
            service: service,
            accessible: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        )

#if targetEnvironment(simulator)
        if status != errSecSuccess {
            status = Keychain.set(
                data,
                service: service,
                accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            )
        }
#endif

        guard status == errSecSuccess else {
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw RecoveryKeyError.devicePasscodeRequired
            }
            throw RecoveryKeyError.keychain(status)
        }
        return format(data)
    }

    static func code() -> String? {
        guard let data = Keychain.get(service: service) else { return nil }
        return format(data)
    }

    static func keyData() -> Data? {
        Keychain.get(service: service)
    }

    static func keyData(from code: String) throws -> Data {
        let compact = code
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var base64 = compact
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "~", with: "+")
        while base64.count.isMultiple(of: 4) == false { base64.append("=") }
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw RecoveryKeyError.invalidCode
        }
        return data
    }

    static func saveRestoredKey(_ data: Data) throws {
        guard data.count == 32 else { throw RecoveryKeyError.invalidCode }
        var status = Keychain.set(
            data,
            service: service,
            accessible: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        )
#if targetEnvironment(simulator)
        if status != errSecSuccess {
            status = Keychain.set(
                data,
                service: service,
                accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            )
        }
#endif
        guard status == errSecSuccess else {
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw RecoveryKeyError.devicePasscodeRequired
            }
            throw RecoveryKeyError.keychain(status)
        }
    }

    static func delete() {
        Keychain.delete(service: service)
    }

    private static func format(_ data: Data) -> String {
        let compact = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "~")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return stride(from: 0, to: compact.count, by: 4).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(4, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: "-")
    }
}
