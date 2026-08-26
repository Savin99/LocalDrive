import Foundation
import LocalAuthentication
import CryptoKit
import SwiftUI

@Observable
final class LockManager {
    var isLocked = true
    private(set) var hasPIN: Bool

    /// Защита от повторного запроса, пока системный диалог уже открыт
    @ObservationIgnored private var authInFlight = false

    // Хранится соль + SHA256(соль + PIN), сам PIN нигде не сохраняется
    private struct StoredPin: Codable {
        let salt: Data
        let hash: Data
    }

    init() {
        hasPIN = PinStore.load() != nil
    }

    var biometryAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func setPIN(_ pin: String) {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let salt = Data(saltBytes)
        let stored = StoredPin(salt: salt, hash: Self.hash(pin: pin, salt: salt))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        hasPIN = PinStore.save(data)
    }

    func verify(_ pin: String) -> Bool {
        guard let data = PinStore.load(),
              let stored = try? JSONDecoder().decode(StoredPin.self, from: data) else { return false }
        return Self.hash(pin: pin, salt: stored.salt) == stored.hash
    }

    /// Автоматический вход по лицу — вызывается при активации приложения,
    /// чтобы не надо было тянуться к кнопке Face ID
    @MainActor
    func autoUnlock() async {
        guard isLocked, hasPIN, !authInFlight, biometryAvailable else { return }
        authInFlight = true
        defer { authInFlight = false }
        _ = await unlockWithBiometrics()
    }

    @MainActor
    func unlockWithBiometrics() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "" // системный fallback скрыт — у нас свой PIN
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Доступ к вашим файлам"
            )
            if ok { unlock() }
            return ok
        } catch {
            return false
        }
    }

    func lock() { isLocked = true }
    func unlock() { isLocked = false }

    private static func hash(pin: String, salt: Data) -> Data {
        var input = salt
        input.append(Data(pin.utf8))
        return Data(SHA256.hash(data: input))
    }
}
