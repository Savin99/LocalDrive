import SwiftUI

// Горизонтальная лента недавно добавленных файлов
struct RecentStrip: View {
    let items: [(file: VaultFile, folder: VaultFolder)]
    let onSelect: (VaultFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Недавнее")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items, id: \.file.id) { item in
                        Button {
                            onSelect(item.file)
                        } label: {
                            card(for: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
        }
    }

    private func card(for item: (file: VaultFile, folder: VaultFolder)) -> some View {
        let accent = Theme.color(item.folder.color)
        // Шире, чем превью просит: отступы внутри карточки съедают место у имени
        let side: CGFloat = 132
        return VStack(alignment: .leading, spacing: 0) {
            FileThumbnail(
                file: item.file,
                accent: accent,
                size: CGSize(width: side, height: side),
                cornerRadius: 0,
                showsBorder: false
            )
            .overlay(alignment: .bottomLeading) {
                if let badge = item.file.extensionBadge {
                    TypeBadge(text: badge)
                        .padding(7)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                // Без расширения и в две строки — иначе имя рвётся посередине
                Text(item.file.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Circle()
                        .fill(accent)
                        .frame(width: 5, height: 5)
                    Text(item.folder.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // maxWidth, а не фиксированная ширина: иначе padding расширил бы
            // подпись шире превью и карточка перестала бы быть квадратной
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: side)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}
