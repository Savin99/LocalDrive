import SwiftUI

// Живой фон экрана входа: два цветных пятна медленно расходятся и сходятся
struct LockBackdrop: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.background

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.accent.opacity(0.30), .clear],
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
                        colors: [Theme.color("purple").opacity(0.22), .clear],
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
                .fill(
                    LinearGradient(
                        colors: [Theme.accent, Theme.color("purple")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 84, height: 84)
                .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)

            Image(systemName: "lock.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}
