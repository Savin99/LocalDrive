import SwiftUI

// Нижняя панель режима выделения — повторяет набор действий из референса,
// за вычетом того, чего в LocalDrive нет: напоминаний, реакций и ассистента
struct FeedSelectionToolbar: View {
    let accent: Color
    let canMerge: Bool
    let canSplit: Bool
    let shareURLs: [URL]

    let canMoveUp: Bool
    let canMoveDown: Bool

    let onMerge: () -> Void
    let onSplit: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            action("В один ряд", icon: "rectangle.split.3x1", enabled: canMerge, action: onMerge)
            action("Разделить", icon: "rectangle.split.1x2", enabled: canSplit, action: onSplit)

            if shareURLs.isEmpty {
                action("Поделиться", icon: "square.and.arrow.up", enabled: false) {}
            } else {
                ShareLink(items: shareURLs) {
                    label("Поделиться", icon: "square.and.arrow.up", tint: accent)
                }
                .buttonStyle(.plain)
            }

            // Медиаряд остаётся без контекстного меню, чтобы фото можно было
            // тянуть, — доступный способ переставить блок живёт здесь
            Menu {
                Button {
                    onMoveUp()
                } label: {
                    Label("Переместить выше", systemImage: "arrow.up")
                }
                .disabled(!canMoveUp)

                Button {
                    onMoveDown()
                } label: {
                    Label("Переместить ниже", systemImage: "arrow.down")
                }
                .disabled(!canMoveDown)
            } label: {
                label("Ещё", icon: "ellipsis", tint: accent)
            }

            Button(role: .destructive, action: onDelete) {
                label("Удалить", icon: "trash", tint: .red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.8))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .padding(.horizontal, 16)
    }

    private func action(
        _ title: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label(title, icon: icon, tint: accent)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func label(_ title: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
