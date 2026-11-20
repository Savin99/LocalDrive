import SwiftUI

// Карточка сетки — сам лист документа в его пропорциях (FileSheet): превью
// со скруглением и загнутым уголком, под ним имя и размер, без подложки
// (референсы владельца 19.11.2026)
struct FileGridCell: View {
    let file: VaultFile
    let accent: Color
    let side: CGFloat
    var showsContentDate = false
    /// Режим выбора: nil — не выбирают; true — лист отмечен. Отметка — на самом
    /// листе, как в референсе: подкраска и галочка, без рамки вокруг подписи
    var selection: Bool? = nil

    var body: some View {
        FileSheet(file: file, accent: accent, fit: .width(side), selection: selection) {
            VStack(alignment: .leading, spacing: 2) {
                // Без расширения и в две строки — иначе имя рвётся посередине
                Text(file.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(RussianFormat.size(file.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }
}

/// Загнутый уголок листа: светлый треугольник подгиба с тенью
struct PageCurl: View {
    let size: CGFloat

    var body: some View {
        FoldTriangle()
            .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.8)], startPoint: .topTrailing, endPoint: .bottomLeading))
            .shadow(color: .black.opacity(0.3), radius: 2, x: -1, y: 1)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Подгиб: прямой угол внизу слева, гипотенуза — по линии среза
private struct FoldTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 3), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Скруглённый прямоугольник со срезанным правым верхним углом — лист,
/// у которого загнули уголок. `cut == 0` — обычное скругление
struct CutCornerRectangle: Shape {
    let radius: CGFloat
    let cut: CGFloat

    func path(in rect: CGRect) -> Path {
        guard cut > 0 else { return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect) }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// Бейдж с типом файла поверх превью
struct TypeBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
    }
}
