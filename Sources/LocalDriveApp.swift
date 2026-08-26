import SwiftUI

@main
struct LocalDriveApp: App {
    @State private var store = VaultStore()
    @State private var lock = LockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(lock)
                .tint(Theme.accent)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        // Автоблокировка при уходе приложения в фон
                        lock.lock()
                    case .active:
                        // Сканируем лицо сразу при возврате — без нажатия кнопки
                        Task { await lock.autoUnlock() }
                    default:
                        break
                    }
                }
        }
    }
}
