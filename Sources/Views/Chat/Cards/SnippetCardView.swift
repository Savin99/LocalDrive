import SwiftUI

// Файл и фрагмент текста, где нашлись слова запроса. Кнопка открывает
// документ сразу на странице совпадения
struct SnippetCardView: View {
    let document: ChatDocument
    let page: Int?
    let snippet: AttributedString?

    @Environment(\.chatActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                FileThumbnail(
                    file: document.file,
                    accent: Theme.ink,
                    size: CGSize(width: 52, height: 52),
                    cornerRadius: 12
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.file.displayName)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 5) {
                        ChatFolderChip(folder: document.folder)
                        if let page {
                            Text("· стр. \(page)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    if let snippet {
                        Text(ChatSnippetHighlight.highlighted(snippet))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { open() }

            Button(action: open) {
                Label(page.map { "Открыть на стр. \($0)" } ?? "Открыть", systemImage: "doc.text.magnifyingglass")
                    .chatButtonPadding()
                    .secondaryCapsule()
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("chatOpen")
        }
        .chatCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-snippet")
    }

    private func open() {
        actions.open(document.file, [document.file], page)
    }
}

/// Подсветка без цвета, как в ChatGPT: совпавшие слова — цветом текста на
/// сером фрагменте. Совпадения размечены `stronglyEmphasized`, жирность даёт сам Text
enum ChatSnippetHighlight {
    static func highlighted(_ snippet: AttributedString) -> AttributedString {
        var result = snippet
        let ranges = result.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map(\.range)
        for range in ranges {
            result[range].foregroundColor = Theme.ink
        }
        return result
    }
}

extension View {
    /// Отступы кнопок карточек чата — одинаковые у главных и второстепенных
    func chatButtonPadding() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 9)
    }
}
