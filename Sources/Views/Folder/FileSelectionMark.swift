import SwiftUI

// Кружок выбора файла. Поверх превью — с белой обводкой и тенью: его должно
// быть видно и на светлом скане, и на тёмном фото. В строке списка — тонкий,
// под цвет текста
struct FileSelectionMark: View {
    enum Placement {
        case overImage
        case inRow
    }

    let isSelected: Bool
    let accent: Color
    var placement: Placement = .overImage

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 24

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(accent)
                Image(systemName: "checkmark")
                    .font(.system(size: side * 0.46, weight: .bold))
                    .foregroundStyle(.white)
            } else if placement == .overImage {
                Circle().fill(.black.opacity(0.22))
                Circle().strokeBorder(.white, lineWidth: 1.5)
            } else {
                Circle().strokeBorder(Theme.ink.opacity(0.28), lineWidth: 1.5)
            }
        }
        .frame(width: side, height: side)
        .shadow(color: placement == .overImage ? .black.opacity(0.25) : .clear, radius: 3, y: 1)
        .animation(.snappy(duration: 0.18), value: isSelected)
        .accessibilityHidden(true)
    }
}
