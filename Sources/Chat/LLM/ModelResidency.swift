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
}
