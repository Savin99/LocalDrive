import SwiftUI

// Карточка сетки: крупное превью содержимого файла
struct FileGridCell: View {
    let file: VaultFile
    let accent: Color
    let side: CGFloat
    var showsContentDate = false

    private var isVideo: Bool {
        file.type.conforms(to: .movie) || file.type.conforms(to: .video)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileThumbnail(
                file: file,
                accent: accent,
                size: CGSize(width: side, height: side),
                cornerRadius: 0
            )
            .overlay(alignment: .topTrailing) {
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let badge = file.extensionBadge {
                    TypeBadge(text: badge)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                // Без расширения и в две строки — иначе имя рвётся посередине
                Text(file.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(RussianFormat.size(file.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cardBorder(cornerRadius: 18)
        .contentShape(Rectangle())
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
