import SwiftUI

// Короткое подтверждение действия у верхнего края: «Перемещено в «Паспорта»».
// Инверсная капсула, как главные кнопки: чёрная днём, светлая вечером
struct ToastBanner: View {
    let text: String
    var icon = "checkmark.circle.fill"

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(.subheadline, weight: .semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Theme.ink.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityIdentifier("toast")
    }
}
