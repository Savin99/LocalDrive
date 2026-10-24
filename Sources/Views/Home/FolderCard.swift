import SwiftUI

struct FolderCard: View {
    let folder: VaultFolder
    let stats: FolderStats
    /// До четырёх последних файлов — из них собирается коллаж
    let preview: [VaultFile]

    private var accent: Color { Theme.color(folder.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if preview.isEmpty {
                    emptyCover
                } else {
                    FolderCollage(files: preview, accent: accent)
                }
            }
            .frame(height: 116)
            .frame(maxWidth: .infinity)
            .clipped()

            HStack(spacing: 8) {
                Image(systemName: folder.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 26, height: 26)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cardBorder(cornerRadius: 20)
    }

    private var emptyCover: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.20), accent.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: folder.icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(accent.opacity(0.55))
        }
    }

    private var subtitle: String {
        // Вложенные папки — первыми: файлов в такой папке может не быть вовсе
        let folders = stats.subfolders > 0 ? pluralize(stats.subfolders, "папка", "папки", "папок") : nil
        guard stats.count > 0 else { return folders ?? "Пусто" }
        let size = ByteCountFormatter.string(fromByteCount: stats.size, countStyle: .file)
        if folder.kind == .feed {
            let blocks = pluralize(stats.count, "блок", "блока", "блоков")
            return stats.size > 0 ? "\(blocks) · \(size)" : blocks
        }
        let files = pluralize(stats.count, "файл", "файла", "файлов")
        // Две части с размером не влезают в карточку — размер уступает место
        guard let folders else { return "\(files) · \(size)" }
        return "\(folders) · \(files)"
    }
}

// Коллаж превью: один файл — во всю обложку, дальше мозаика
private struct FolderCollage: View {
    let files: [VaultFile]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let gap: CGFloat = 2

            switch files.count {
            case 1:
                cell(files[0], CGSize(width: w, height: h))
            case 2:
                HStack(spacing: gap) {
                    let side = (w - gap) / 2
                    cell(files[0], CGSize(width: side, height: h))
                    cell(files[1], CGSize(width: side, height: h))
                }
            case 3:
                HStack(spacing: gap) {
                    let big = (w - gap) * 0.62
                    cell(files[0], CGSize(width: big, height: h))
                    VStack(spacing: gap) {
                        let side = (h - gap) / 2
                        cell(files[1], CGSize(width: w - gap - big, height: side))
                        cell(files[2], CGSize(width: w - gap - big, height: side))
                    }
                }
            default:
                VStack(spacing: gap) {
                    let rowH = (h - gap) / 2
                    let colW = (w - gap) / 2
                    HStack(spacing: gap) {
                        cell(files[0], CGSize(width: colW, height: rowH))
                        cell(files[1], CGSize(width: colW, height: rowH))
                    }
                    HStack(spacing: gap) {
                        cell(files[2], CGSize(width: colW, height: rowH))
                        cell(files[3], CGSize(width: colW, height: rowH))
                    }
                }
            }
        }
    }

    private func cell(_ file: VaultFile, _ size: CGSize) -> some View {
        FileThumbnail(file: file, accent: accent, size: size, cornerRadius: 0, showsBorder: false)
    }
}
