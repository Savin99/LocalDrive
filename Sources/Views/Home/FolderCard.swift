import SwiftUI

// Папка на главном — стеклянная, как в референсах владельца 19.11.2026: задняя
// стенка с корешком цветом папки, из кармана выглядывают последние файлы,
// карман — матовое стекло, на нём наклейка-значок. Стекло кармана — обычный
// материал, а не Liquid Glass: системное стекло — для слоя управления, не
// содержимого (Apple HIG, Materials; docs/design.md)
struct FolderCard: View {
    let folder: VaultFolder
    let stats: FolderStats
    /// До четырёх последних файлов — сверху выглядывают первые три
    let preview: [VaultFile]
    /// Над папкой держат файл — она подсвечивается и ждёт
    var isDropTarget = false

    @Environment(\.colorScheme) private var scheme

    private var accent: Color { Theme.color(folder.color) }

    var body: some View {
        VStack(spacing: 10) {
            art
                .frame(height: 142)
            HStack(spacing: 6) {
                Text(folder.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                CountPill(count: stats.count + stats.subfolders)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
        .scaleEffect(isDropTarget ? 1.05 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDropTarget)
        .accessibilityLabel("\(folder.name), \(subtitle)")
    }

    private var art: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let pocket = height * 0.6
            ZStack(alignment: .bottom) {
                // Свечение цветом папки — сильнее, когда над ней держат файл
                Ellipse()
                    .fill(accent.opacity(isDropTarget ? 0.6 : (scheme == .dark ? 0.32 : 0.24)))
                    .frame(width: width * 0.86, height: pocket * 0.8)
                    .blur(radius: 24)
                    .offset(y: 6)
                // Задняя стенка с корешком
                FolderShape(radius: 20)
                    .fill(LinearGradient(colors: [back(0.25), back(0.45)], startPoint: .top, endPoint: .bottom))
                    .overlay(FolderShape(radius: 20).stroke(.white.opacity(0.14), lineWidth: 0.8))
                    .frame(width: width, height: height * 0.86)
                papers(width: width, height: height, pocket: pocket)
                // Карман — матовое стекло со светлой кромкой
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LinearGradient(colors: [accent.opacity(0.24), accent.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    )
                    // Вечером карман глубже: снизу темнее, стекло не «молочное»
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LinearGradient(colors: [.clear, .black.opacity(scheme == .dark ? 0.32 : 0.04)], startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                                          lineWidth: isDropTarget ? 2 : 1)
                    )
                    .frame(width: width, height: pocket)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 10, y: 6)
                StickerIcon(symbol: folder.icon, color: accent, size: 34)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    /// Бумаги в кармане: последние файлы веером; у пустой папки — один чистый лист
    private func papers(width: CGFloat, height: CGFloat, pocket: CGFloat) -> some View {
        let size = CGSize(width: width * 0.46, height: height * 0.66)
        let shown = Array(preview.prefix(3))
        let angles: [Double] = shown.count == 1 ? [-3] : (shown.count == 2 ? [-7, 5] : [-9, 1, 9])
        let shifts: [CGFloat] = shown.count == 1 ? [0] : (shown.count == 2 ? [-0.16, 0.16] : [-0.24, 0, 0.24])
        return ZStack {
            if shown.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(scheme == .dark ? 0.85 : 0.95))
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(-4))
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                FileThumbnail(file: file, accent: accent, size: size, cornerRadius: 8, showsBorder: false)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .rotationEffect(.degrees(angles[index]))
                    .offset(x: width * shifts[index], y: index == 1 ? -4 : 0)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .offset(y: height * 0.1)
        .allowsHitTesting(false)
    }

    /// Задняя стенка: цвет папки, приглушённый к тёмному
    private func back(_ shade: Double) -> Color {
        accent.mix(with: .black, by: scheme == .dark ? shade + 0.15 : shade)
    }

    private var subtitle: String {
        // Вложенные папки — первыми: файлов в такой папке может не быть вовсе
        let folders = stats.subfolders > 0 ? pluralize(stats.subfolders, "папка", "папки", "папок") : nil
        guard stats.count > 0 else { return folders ?? "Пусто" }
        let files = folder.kind == .feed ? pluralize(stats.count, "блок", "блока", "блоков") : pluralize(stats.count, "файл", "файла", "файлов")
        guard let folders else { return files }
        return "\(folders), \(files)"
    }
}
