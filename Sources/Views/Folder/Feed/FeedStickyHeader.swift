import SwiftUI

// Плавающая шапка поверх страницы. Название и «хлебная крошка» проявляются,
// когда заголовок документа уходит под шапку.
struct FeedStickyHeader: View {
    let folder: VaultFolder
    let accent: Color
    let titleOpacity: Double
    let isSelecting: Bool
    let shareURLs: [URL]

    let onBack: () -> Void
    let onStartSelecting: () -> Void
    let onFinishSelecting: () -> Void
    let onSelectAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            circleButton("chevron.left", action: onBack)
                .accessibilityLabel("Назад")

            Spacer(minLength: 4)

            VStack(spacing: 1) {
                Text(folder.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: folder.icon)
                    Text("Лента")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .opacity(titleOpacity)
            .allowsHitTesting(false)
            // Пока шапка прозрачна, её заголовок не должен читаться VoiceOver
            .accessibilityHidden(titleOpacity < 0.1)

            Spacer(minLength: 4)

            if isSelecting {
                Button(action: onFinishSelecting) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Готово")
            } else {
                HStack(spacing: 2) {
                    if shareURLs.isEmpty {
                        pillIcon("square.and.arrow.up")
                            .foregroundStyle(.tertiary)
                    } else {
                        ShareLink(items: shareURLs) {
                            pillIcon("square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                    }

                    Menu {
                        Button {
                            onStartSelecting()
                        } label: {
                            Label("Выбрать блоки", systemImage: "checkmark.circle")
                        }
                        Button {
                            onSelectAll()
                        } label: {
                            Label("Выбрать всё", systemImage: "checklist")
                        }
                    } label: {
                        pillIcon("ellipsis")
                    }
                }
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func pillIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 42, height: 40)
            .contentShape(Rectangle())
    }
}
