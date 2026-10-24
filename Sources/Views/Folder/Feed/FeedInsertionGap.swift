import SwiftUI

// Зона между блоками. Она же вертикальный ритм страницы, поэтому линия
// вставки появляется ровно там, куда блок и встанет — индекс задан явно,
// без арифметики «до/после» на стороне модели.
struct FeedInsertionGap: View {
    let index: Int
    let accent: Color
    let height: CGFloat
    let onDrop: (FeedDragPayload, Int) -> Bool

    @Binding var hovered: Int?

    var body: some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .overlay {
                if hovered == index {
                    Capsule()
                        .fill(accent)
                        .frame(height: 3)
                        .padding(.horizontal, FeedPage.mediaInset)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .center)))
                }
            }
            .dropDestination(for: FeedDragPayload.self) { payload, _ in
                guard let first = payload.first else { return false }
                return onDrop(first, index)
            } isTargeted: { targeted in
                withAnimation(.snappy(duration: 0.15)) {
                    if targeted {
                        hovered = index
                    } else if hovered == index {
                        hovered = nil
                    }
                }
            }
    }
}
