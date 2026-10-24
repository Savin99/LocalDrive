import SwiftUI

struct RootView: View {
    @Environment(LockManager.self) private var lock
    @Environment(SearchService.self) private var search
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if DEBUG
        // Отладочная галерея Generative UI (docs/genui.md): запуск с -GenUIGallery
        if GenUIGallery.isRequested {
            GenUIGalleryView()
        } else {
            content
        }
        #else
        content
        #endif
    }

    private var content: some View {
        ZStack {
            if !lock.hasPIN {
                SetupPinView()
            } else if lock.isLocked {
                LockView()
            } else {
                MainView()
            }

            // Шторка приватности перекрывает содержимое, пока приложение не активно:
            // именно этот кадр iOS кладёт в переключатель приложений
            if scenePhase != .active && lock.hasPIN {
                PrivacyShield()
            }
        }
        // Переходы между экранами намеренно без анимации: любая плавность
        // означает кадр, где сквозь замок видно содержимое
        .animation(nil, value: lock.isLocked)
        .animation(nil, value: scenePhase)
    }
}

private struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.ink)
        }
    }
}
