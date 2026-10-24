import SwiftUI

struct RootView: View {
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

    // Экрана блокировки нет: приложение открывается сразу на главном экране
    // (решение владельца от 24.10.2026). Приватное прячут скрытые папки
    private var content: some View {
        ZStack {
            MainView()

            // Шторка приватности перекрывает содержимое, пока приложение не активно:
            // именно этот кадр iOS кладёт в переключатель приложений
            if scenePhase != .active {
                PrivacyShield()
            }
        }
        // Без анимации: плавное появление означало бы кадр, где содержимое
        // просвечивает сквозь шторку
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
