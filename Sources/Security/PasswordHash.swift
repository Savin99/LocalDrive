import CommonCrypto
import Foundation
import Security

/// Пароль скрытых папок в хранилище: случайная соль и PBKDF2-HMAC-SHA256.
/// Сам пароль нигде не сохраняется. Число раундов записано рядом с хешем —
/// его можно поднять в новой версии, не ломая старые записи
struct PasswordHash: Codable, Equatable, Sendable {
    let salt: Data
    let hash: Data
    let rounds: UInt32

    /// Рекомендация OWASP для PBKDF2-HMAC-SHA256 (2023): 600 000 раундов
    static let defaultRounds: UInt32 = 600_000
    private static let saltLength = 16
    private static let hashLength = 32

    /// Новая запись со свежей солью. nil — если не удалось получить случайные байты
    static func make(password: String, rounds: UInt32 = defaultRounds) -> PasswordHash? {
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, buffer.baseAddress!)
        }
        guard status == errSecSuccess,
              let hash = derive(password: password, salt: salt, rounds: rounds) else { return nil }
        return PasswordHash(salt: salt, hash: hash, rounds: rounds)
    }

    func verify(_ password: String) -> Bool {
        guard let candidate = Self.derive(password: password, salt: salt, rounds: rounds) else { return false }
        return Self.constantTimeEquals(candidate, hash)
    }

    static func derive(password: String, salt: Data, rounds: UInt32) -> Data? {
        // «ё» с клавиатуры и из буфера обмена бывает одной буквой или двумя
        // символами — приводим к одному виду до хеширования
        let bytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: hashLength)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBuffer in
                bytes.withUnsafeBufferPointer { passwordBuffer in
                    passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passwordChars.baseAddress,
                            passwordChars.count,
                            saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                            salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            rounds,
                            output.bindMemory(to: UInt8.self).baseAddress,
                            hashLength
                        )
                    }
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    /// Сравнение за одинаковое время: по нему нельзя понять, сколько байтов совпало
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
