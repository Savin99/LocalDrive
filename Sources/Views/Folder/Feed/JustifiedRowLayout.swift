import SwiftUI

// Раскладка ряда медиа как в Craft: высота ряда выводится из пропорций фото,
// ширины пропорциональны им же, ряд всегда занимает всю ширину контента.
//
//     h = (W - gap * (n - 1)) / Σ aspect
//     widthᵢ = h * aspectᵢ
//
// Ряд из одного файла — исключение: он не растёт выше singleMaxHeight и
// центрируется, поэтому портретное видео лежит на странице с полями по бокам.

struct MediaAspectKey: LayoutValueKey {
    static let defaultValue: Double = MediaAspect.fallback
}

/// Роль подвью: миниатюра участвует в раскладке, шов — только зона попадания
/// для перетаскивания, он кладётся поверх стыка и не занимает места
enum JustifiedRole {
    case photo
    case seam
}

struct JustifiedRoleKey: LayoutValueKey {
    static let defaultValue: JustifiedRole = .photo
}

extension View {
    func mediaAspect(_ value: Double) -> some View {
        layoutValue(key: MediaAspectKey.self, value: value)
    }

    func justifiedRole(_ role: JustifiedRole) -> some View {
        layoutValue(key: JustifiedRoleKey.self, value: role)
    }
}

struct JustifiedRowMetrics {
    var height: CGFloat
    var widths: [CGFloat]
    var leadingInset: CGFloat
    var gap: CGFloat = FeedPage.mediaGap

    /// Координаты стыков: n + 1 позиция, от левого края первой миниатюры
    /// до правого края последней. Зазор между кадрами тоже проходится,
    /// иначе зоны попадания уезжали бы влево к концу ряда.
    var seams: [CGFloat] {
        var result: [CGFloat] = [leadingInset]
        var x = leadingInset
        for (index, width) in widths.enumerated() {
            x += width
            if index == widths.count - 1 {
                result.append(x)
            } else {
                result.append(x + gap / 2)
                x += gap
            }
        }
        return result
    }

    static func compute(width: CGFloat, aspects: [Double], gap: CGFloat = FeedPage.mediaGap) -> JustifiedRowMetrics {
        let count = aspects.count
        guard count > 0, width > 0 else {
            return JustifiedRowMetrics(height: 0, widths: [], leadingInset: 0)
        }

        let available = max(1, width - gap * CGFloat(count - 1))
        let ratios = aspects.map { CGFloat($0) }
        let sum = max(0.01, ratios.reduce(0, +))

        if count == 1 {
            let height = min(available / ratios[0], FeedPage.singleMaxHeight)
            let itemWidth = min(available, height * ratios[0])
            return JustifiedRowMetrics(
                height: height,
                widths: [itemWidth],
                leadingInset: (width - itemWidth) / 2,
                gap: gap
            )
        }

        let raw = available / sum
        let height = min(max(raw, FeedPage.rowMinHeight), FeedPage.rowMaxHeight)
        // Ширины всегда делят доступное место — при упоре в ограничение высоты
        // кадр слегка подрезается, но ряд остаётся выровненным по краям
        let widths = ratios.map { available * $0 / sum }
        return JustifiedRowMetrics(height: height, widths: widths, leadingInset: 0, gap: gap)
    }
}

struct JustifiedRowLayout: Layout {
    /// Ширина зоны попадания на стыке — сам шов невидим
    var seamHitWidth: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? 0
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: aspects(of: subviews))
        return CGSize(width: width, height: metrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let metrics = JustifiedRowMetrics.compute(width: bounds.width, aspects: aspects(of: subviews))
        guard metrics.height > 0 else { return }

        var x = bounds.minX + metrics.leadingInset
        var photoIndex = 0
        for subview in subviews where subview[JustifiedRoleKey.self] == .photo {
            let width = metrics.widths[photoIndex]
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: metrics.height)
            )
            x += width + metrics.gap
            photoIndex += 1
        }

        let seams = metrics.seams
        var seamIndex = 0
        for subview in subviews where subview[JustifiedRoleKey.self] == .seam {
            guard seamIndex < seams.count else { break }
            subview.place(
                at: CGPoint(x: bounds.minX + seams[seamIndex], y: bounds.minY),
                anchor: .top,
                proposal: ProposedViewSize(width: seamHitWidth, height: metrics.height)
            )
            seamIndex += 1
        }
    }

    private func aspects(of subviews: Subviews) -> [Double] {
        subviews
            .filter { $0[JustifiedRoleKey.self] == .photo }
            .map { $0[MediaAspectKey.self] }
    }
}
