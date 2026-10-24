import SwiftUI

// Запрос неоднозначный: 2–4 чипа с вариантами, тап отправляет уточнение.
// Без подложки карточки — чипы продолжают реплику, как подсказки в чате
struct ClarifyCardView: View {
    let question: String?
    let options: [ClarifyOption]

    @Environment(\.chatActions) private var actions

    /// Выбранный вариант остаётся закрашенным: видно, на что ответил человек
    @State private var chosen: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question {
                Text(question)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ChatChipFlow(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let selected = chosen == index
                    Button {
                        chosen = index
                        actions.choose(option)
                    } label: {
                        // Серые капсулы, выбранная — заливкой цвета текста
                        Text(option.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? Theme.background : Theme.ink)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(selected ? Theme.ink : Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chatClarify-\(index)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-clarify")
    }
}

/// Чипы в строку с переносом. Чип шире строки получает её ширину,
/// и его текст переносится внутри капсулы
struct ChatChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }
}
