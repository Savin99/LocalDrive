import CoreGraphics
import Foundation
import Observation
import OSLog

/// Суперскрытые папки: открыты ли они сейчас, каким знаком их открывают
/// и пароль на случай, если знак не получается. Общий объект окружения:
/// знак рисуют на «Файлах», пароль вводят в настройках, а прячет папки
/// уход приложения в фон (LocalDriveApp).
///
/// Знак и пароль — секреты: лежат в SecretStore (Keychain только этого
/// iPhone), пароль — солью и PBKDF2. Ни пароль, ни точки знака не пишутся в лог
@MainActor
@Observable
final class HiddenFolders {
    /// Скрытые папки видны на «Файлах». Только в памяти: после перезапуска
    /// приложения они снова спрятаны
    private(set) var isRevealed = false
    /// Растёт с каждым открытием — даже если папки уже были открыты. По нему
    /// главный экран листает к «Файлам», а «Файлы» выходят на корень
    private(set) var revealCount = 0
    /// Владелец нарисовал свой знак вместо встроенной Z
    private(set) var hasCustomSymbol: Bool
    private(set) var hasPassword: Bool

    static let minimumPasswordLength = 4

    @ObservationIgnored private var symbol: SecretSymbol
    @ObservationIgnored private let symbolStore: SecretStore
    @ObservationIgnored private let passwordStore: SecretStore
    @ObservationIgnored private let rounds: UInt32
    @ObservationIgnored private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "hidden-folders")

    init(
        symbolStore: SecretStore = .hiddenSymbol,
        passwordStore: SecretStore = .hiddenPassword,
        rounds: UInt32 = PasswordHash.defaultRounds
    ) {
        self.symbolStore = symbolStore
        self.passwordStore = passwordStore
        self.rounds = rounds
        let saved = symbolStore.load().flatMap { try? JSONDecoder().decode(SecretSymbol.self, from: $0) }
        symbol = saved ?? .defaultZ
        hasCustomSymbol = saved != nil
        hasPassword = passwordStore.load().flatMap { try? JSONDecoder().decode(PasswordHash.self, from: $0) } != nil
    }

    // MARK: - Видимость

    func reveal() {
        isRevealed = true
        revealCount += 1
    }

    func hide() {
        isRevealed = false
    }

    /// Штрих по «Файлам» — секретный знак? Тогда папки открываются
    @discardableResult
    func revealIfRecognized(_ stroke: [CGPoint], in screen: CGSize) -> Bool {
        guard !isRevealed, symbol.matches(stroke: stroke, in: screen) else { return false }
        reveal()
        return true
    }

    /// Открыть по паролю из настроек
    func reveal(password: String) async -> Bool {
        guard await verify(password) else { return false }
        reveal()
        return true
    }

    // MARK: - Знак и пароль

    /// Сохранить свой знак. Пароль обязателен: если его ещё нет, `password`
    /// становится новым паролем; если есть — это текущий, и он проверяется.
    /// Иначе любой, кто взял телефон, мог бы нарисовать свой знак и открыть папки
    func saveSymbol(_ newSymbol: SecretSymbol, password: String) async -> Bool {
        if hasPassword {
            guard await verify(password) else { return false }
        } else {
            guard await setPassword(password) else { return false }
        }
        guard let data = try? JSONEncoder().encode(newSymbol), symbolStore.save(data) else {
            log.error("не удалось сохранить знак")
            return false
        }
        symbol = newSymbol
        hasCustomSymbol = true
        return true
    }

    /// Вернуть встроенную Z — тоже только с текущим паролем
    func resetSymbol(password: String) async -> Bool {
        guard hasCustomSymbol else { return true }
        guard await verify(password) else { return false }
        symbolStore.delete()
        symbol = .defaultZ
        hasCustomSymbol = false
        return true
    }

    func changePassword(current: String, new: String) async -> Bool {
        guard hasPassword, await verify(current) else { return false }
        return await setPassword(new)
    }

    func verify(_ password: String) async -> Bool {
        guard let data = passwordStore.load(),
              let stored = try? JSONDecoder().decode(PasswordHash.self, from: data) else { return false }
        // PBKDF2 занимает доли секунды — не на главном потоке
        return await Task.detached(priority: .userInitiated) {
            stored.verify(password)
        }.value
    }

    private func setPassword(_ password: String) async -> Bool {
        guard password.count >= Self.minimumPasswordLength else { return false }
        let rounds = rounds
        let record = await Task.detached(priority: .userInitiated) {
            PasswordHash.make(password: password, rounds: rounds)
        }.value
        guard let record, let data = try? JSONEncoder().encode(record), passwordStore.save(data) else {
            log.error("не удалось сохранить пароль скрытых папок")
            return false
        }
        hasPassword = true
        return true
    }
}
