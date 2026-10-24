import Foundation

// В памяти iPhone одна модель: модель чата (пик ≈ 2,8 ГБ) и модель для
// документов (≈ 3,9 ГБ) вместе не поместились бы в лимит приложения без
// increased-memory-limit. Перед загрузкой одна выгружает другую. Запросы идут
// строго по очереди: иначе обе могли бы решить, что память свободна
actor ModelResidency {
    static let shared = ModelResidency()

    private var holder: ObjectIdentifier?
    private var unloadHolder: (@Sendable () async -> Void)?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Модель `owner` сейчас загрузится: прежняя выгружается заранее
    func acquire(_ owner: ObjectIdentifier, unload: @escaping @Sendable () async -> Void) async {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        if let holder, holder != owner, let unloadHolder {
            await unloadHolder()
        }
        holder = owner
        unloadHolder = unload
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// Модель выгрузилась сама: уход в фон, удаление, нехватка памяти
    func release(_ owner: ObjectIdentifier) {
        guard holder == owner else { return }
        holder = nil
        unloadHolder = nil
    }

    /// Кто сейчас в памяти. Для проверок
    var current: ObjectIdentifier? { holder }

    // MARK: - Чат важнее фонового чтения

    /// До какого времени чат считается занятым. Владелец 24.10.2026: вопрос
    /// «дата рождения Ольги» думал больше 30 с — фоновое чтение документов
    /// после каждого ответа снова вытесняло модель чата, и следующий вопрос
    /// грузил её заново
    private var chatActiveUntil = Date.distantPast

    /// Человек спросил чат: минуту модель для документов не грузится
    func noteChatActivity(for seconds: TimeInterval = 60) {
        chatActiveUntil = max(chatActiveUntil, Date().addingTimeInterval(seconds))
    }

    /// Фоновое чтение ждёт, пока чат затихнет. Отмена — уход в фон
    func waitForChatPause() async throws {
        while true {
            let left = chatActiveUntil.timeIntervalSinceNow
            guard left > 0 else { return }
            try await Task.sleep(for: .seconds(left))
        }
    }
}
