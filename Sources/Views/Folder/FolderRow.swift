import SwiftUI

// Строка папки: значок её цвета, имя и что внутри. Общая для вложенных папок
// в режиме списка и для листа выбора папки
struct FolderRow: View {
    let folder: VaultFolder
    let stats: FolderStats
    /// Отступ уровня дерева в листе выбора
    var depth = 0
    /// Значок суперскрытой папки — когда скрытые открыты жестом
    var marksHidden = false
    /// Пометить, что документ здесь не найдёт чат
    var marksUnsearchable = false
    var showsChevron = true

    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 36

    private var accent: Color { Theme.color(folder.color) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.icon)
                .font(.system(size: badge * 0.42, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: badge, height: badge)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: badge * 0.28, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(folder.name)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if marksHidden {
                        Image(systemName: "eye.slash.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Суперскрытая папка")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 22)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if folder.kind == .feed {
            parts.append(stats.count == 0 ? "Лента · пусто" : "Лента · \(pluralize(stats.count, "блок", "блока", "блоков"))")
        } else {
            if stats.subfolders > 0 {
                parts.append(pluralize(stats.subfolders, "папка", "папки", "папок"))
            }
            if stats.count > 0 || stats.subfolders == 0 {
                parts.append(stats.count == 0 ? "Пусто" : pluralize(stats.count, "файл", "файла", "файлов"))
            }
        }
        // Документ, перенесённый сюда, пропадёт из ответов чата — это видно заранее
        if marksUnsearchable { parts.append("вне поиска") }
        return parts.joined(separator: " · ")
    }
}
