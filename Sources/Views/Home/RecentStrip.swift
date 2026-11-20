import SwiftUI

// Горизонтальная лента недавно добавленных файлов
struct RecentStrip: View {
    let items: [(file: VaultFile, folder: VaultFolder)]
    let onSelect: (VaultFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Недавнее")
                .font(.system(.subheadline, weight: .semibold))
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                // Листы разной ширины стоят на одной линии, подписи — под ней
                HStack(alignment: .top, spacing: 12) {
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

    /// Лист документа, как в папке: превью в своих пропорциях с загнутым
    /// уголком, под ним имя и папка с её цветной точкой — без подложки карточки.
    /// Высота у всех одна, ширина — по документу: банковская карта шире страницы
    private func card(for item: (file: VaultFile, folder: VaultFolder)) -> some View {
        let accent = Theme.color(item.folder.color)
        return FileSheet(file: item.file, accent: accent, fit: .height(140), radius: 12, spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                // Без расширения и в две строки — иначе имя рвётся посередине
                Text(item.file.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                        .shadow(color: accent.opacity(0.8), radius: 3)
                    Text(item.folder.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
