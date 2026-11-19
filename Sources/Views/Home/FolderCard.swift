import SwiftUI

// Папка на главном и среди вложенных. Рисунок — в одном из видов по
// референсам владельца (FolderStyles.swift), выбор в «Настройки → Оформление».
// Стекло папок — нарисованное, а не Liquid Glass: системное стекло — для слоя
// управления, не содержимого (Apple HIG, Materials; docs/design.md)
struct FolderCard: View {
    let folder: VaultFolder
    let stats: FolderStats
    /// До четырёх последних файлов — из-за стенки выглядывают первые три
    let preview: [VaultFile]
    /// Над папкой держат файл — она подсвечивается и ждёт
    var isDropTarget = false
    /// Вид для образца в настройках; nil — выбранный владельцем
    var style: FolderCardStyle?

    @AppStorage(FolderCardStyle.storageKey) private var storedStyle = FolderCardStyle.standard.rawValue

    private var accent: Color { Theme.color(folder.color) }
    private var current: FolderCardStyle { style ?? FolderCardStyle(rawValue: storedStyle) ?? .standard }

    var body: some View {
        let current = current
        VStack(spacing: 10) {
            art(current)
                .aspectRatio(current.aspectRatio, contentMode: .fit)
            // У карточки название внутри рисунка
            if current != .card {
                HStack(spacing: 6) {
                    // Название — отдельной строкой текста: по нему папку находят
                    // VoiceOver и UI-тесты. Общая подпись на всю карточку их прятала
                    Text(folder.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    CountPill(count: stats.count + stats.subfolders)
                        .accessibilityLabel(subtitle)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .scaleEffect(isDropTarget ? 1.05 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDropTarget)
    }

    @ViewBuilder
    private func art(_ style: FolderCardStyle) -> some View {
        let count = stats.count + stats.subfolders
        switch style {
        case .portfolio:
            PortfolioFolderArt(folder: folder, accent: accent, count: count, isDropTarget: isDropTarget)
        case .scans:
            ScansFolderArt(folder: folder, accent: accent, preview: preview, isDropTarget: isDropTarget)
        case .black:
            BlackFolderArt(folder: folder, accent: accent, count: count, isDropTarget: isDropTarget)
        case .card:
            CardFolderArt(folder: folder, accent: accent, preview: preview, subtitle: subtitle, isEmpty: count == 0, isDropTarget: isDropTarget)
        }
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
