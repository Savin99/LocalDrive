import SwiftUI

// Живой фон экрана входа: два серых пятна медленно расходятся и сходятся.
// Цвета нет намеренно — оформление монохромное, как у ChatGPT
struct LockBackdrop: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.background

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.ink.opacity(0.10), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 260
                    )
                )
                .frame(width: 520, height: 520)
                .offset(x: drift ? -70 : -110, y: drift ? -180 : -120)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.ink.opacity(0.06), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 240
                    )
                )
                .frame(width: 460, height: 460)
                .offset(x: drift ? 130 : 90, y: drift ? 60 : 130)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 7).repeatForever(autoreverses: true), value: drift)
        .onAppear { drift = true }
    }
}

// Значок приложения на экране входа
struct LockMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.ink)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)

            Image(systemName: "lock.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Theme.background)
        }
    }
}
