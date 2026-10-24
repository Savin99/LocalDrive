import SwiftUI

@main
struct LocalDriveApp: App {
    @State private var store: VaultStore
    @State private var lock = LockManager()
    @State private var backup: BackupManager
    @State private var search: SearchService
    @State private var models = ChatModelStore()
    @State private var chat: ChatSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = VaultStore()
        let search = SearchService(store: store)
        _store = State(initialValue: store)
        _backup = State(initialValue: BackupManager(vaultURL: store.rootURL))
        _search = State(initialValue: search)
        // Переписка живёт, пока работает приложение: блокировка при уходе в фон
        // убирает экран, но не стирает её. Владелец 12.10.2026: чат пропадал
        // после каждого выхода — даже чтобы вставить скопированный номер
        _chat = State(initialValue: ChatSession(search: search))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(lock)
                .environment(backup)
                .environment(search)
                .environment(models)
                .environment(chat)
                .tint(Theme.accent)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        // Автоблокировка при уходе приложения в фон. Номера в
                        // переписке снова под маской — до нового Face ID
                        lock.lock()
                        chat.revealsSensitive = false
                        // База индекса защищена как файлы: на заблокированном
                        // iPhone она недоступна, поэтому распознавание встаёт
                        search.suspend()
                        // В фоне iOS отклоняет работу GPU: генерация
                        // останавливается, модель выгружается из памяти
                        models.suspend()
                    case .active:
                        search.resume()
                        // Сканируем лицо сразу при возврате — без нажатия кнопки
                        Task { await lock.autoUnlock() }
                    default:
                        break
                    }
                }
        }
    }
}
