import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var accent: Color = Theme.ink
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @State private var pulse = false
    @State private var shown = false

    var body: some View {
        VStack(spacing: 14) {
            // Расходящиеся круги за иконкой — экран не выглядит замершим
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(accent.opacity(0.10))
                        .frame(width: 92, height: 92)
                        .scaleEffect(pulse ? 1.55 - Double(i) * 0.14 : 0.85)
                        .opacity(pulse ? 0 : 0.9)
                        .animation(
                            .easeOut(duration: 2.6)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.75),
                            value: pulse
                        )
                }

                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 92, height: 92)

                Image(systemName: icon)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(accent)
                    .symbolEffect(.bounce, options: .repeat(.periodic(delay: 2.4)))
            }
            .padding(.bottom, 6)

            Text(title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)

            if let actionTitle, let action {
                // Главное действие — чёрная капсула, как кнопки ChatGPT,
                // независимо от цвета папки вокруг
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(.subheadline, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .primaryCapsule()
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.95)
        .onAppear {
            pulse = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { shown = true }
        }
    }
}
