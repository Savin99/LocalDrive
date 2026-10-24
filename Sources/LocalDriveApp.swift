import SwiftUI

@main
struct LocalDriveApp: App {
    @State private var store: VaultStore
    @State private var facts: FactStore
    /// Подтверждение владельца перед показом номера в чате
    @State private var lock = LockManager()
    @State private var hiddenFolders = HiddenFolders()
    @State private var backup: BackupManager
    @State private var search: SearchService
    @State private var models = ChatModelStore()
    @State private var chat: ChatSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = VaultStore()
        let search = SearchService(store: store)
        _store = State(initialValue: store)
        _facts = State(initialValue: FactStore(rootURL: store.rootURL))
        _backup = State(initialValue: BackupManager(vaultURL: store.rootURL))
        _search = State(initialValue: search)
        // Переписка живёт, пока работает приложение: уход в фон её не стирает.
        // Владелец 12.10.2026: чат пропадал после каждого выхода — даже чтобы
        // вставить скопированный номер
        _chat = State(initialValue: ChatSession(search: search))
        // Код входа больше не спрашивается — его хеш не нужен. Четыре цифры
        // перебираются мгновенно, а код мог совпадать с другими
        SecretStore.legacyPin.delete()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(facts)
                .environment(lock)
                .environment(hiddenFolders)
                .environment(backup)
                .environment(search)
                .environment(models)
                .environment(chat)
                .tint(Theme.accent)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        // Уход в фон снова прячет скрытые папки, а номера
                        // в переписке — под маску до нового Face ID
                        hiddenFolders.hide()
                        chat.revealsSensitive = false
                        // База индекса защищена как файлы: на заблокированном
                        // iPhone она недоступна, поэтому распознавание встаёт
                        search.suspend()
                        // В фоне iOS отклоняет работу GPU: генерация
                        // останавливается, модель выгружается из памяти
                        models.suspend()
                    case .active:
                        search.resume()
                    default:
                        break
                    }
                }
        }
    }
}
