import Foundation
import LocalAuthentication
import SwiftUI

/// Подтверждение владельца для чата. Экрана блокировки при входе больше нет
/// (решение владельца от 24.10.2026: приватное прячут скрытые папки), но номер
/// документа в переписке по-прежнему открывается только после Face ID или
/// кода iPhone
@Observable
final class LockManager {
    /// Подтверждение владельца перед показом номера документа: Face ID, а без
    /// него — код iPhone. Если на телефоне нет ни того, ни другого, защищать
    /// номер нечем — он показывается сразу
    @MainActor
    func confirmOwner(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
