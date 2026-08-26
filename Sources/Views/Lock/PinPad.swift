import SwiftUI

// Индикатор введённых цифр
struct PinDots: View {
    let filled: Int
    let total: Int

    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < filled ? Theme.accent : Color.black.opacity(0.12))
                    .frame(width: 14, height: 14)
                    .animation(.snappy(duration: 0.15), value: filled)
            }
        }
    }
}

// Цифровая клавиатура
struct PinPad: View {
    var showsBiometry: Bool = false
    var onDigit: (String) -> Void
    var onDelete: () -> Void
    var onBiometry: (() -> Void)? = nil

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 16) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(row, id: \.self) { digit in
                        keyButton(digit) { onDigit(digit) }
                    }
                }
            }
            HStack(spacing: 22) {
                if showsBiometry, let onBiometry {
                    iconButton("faceid", action: onBiometry)
                } else {
                    Color.clear.frame(width: 72, height: 72)
                }
                keyButton("0") { onDigit("0") }
                iconButton("delete.left", action: onDelete)
            }
        }
    }

    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 72, height: 72)
                .background(Theme.card, in: Circle())
                .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 72, height: 72)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// Эффект «дрожания» при неверном коде
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 10
    var shakes = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travel * sin(animatableData * .pi * CGFloat(shakes * 2)),
                y: 0
            )
        )
    }
}
